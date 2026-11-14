-- =============================================================================
-- 05_dlm_pkg.sql
-- Purpose : Data Lifecycle Management for the partitioned billing design.
--
--   Tier      Age (months)        Location / format                     Operation
--   HOT       0  .. HOT_MONTHS     BILLING_RECORDS, TELCO_HOT, R/W       -
--   WARM      .. ONLINE_MONTHS     BILLING_RECORDS, TELCO_ARCH,          warm_partition
--                                  compressed, READ ONLY
--   ARCHIVE   .. RETENTION_MONTHS  BILLING_ARCHIVE, compressed, R/O      archive_partition
--   PURGED    > RETENTION_MONTHS   dropped                               purge_partition
--
-- Every operation works on one month (= one partition), is logged in
-- DLM_JOB_LOG, refuses to touch data the retention policy protects, and can be
-- re-run safely after a failure (idempotent / resumable).
--
-- Integrity model: control totals are captured at load time and re-captured
-- when a month is frozen (WARM, read-only). From then on the month can no
-- longer change, so every later move/exchange is validated against them.
-- HOT months are live (the application writes to them): run_lifecycle validates
-- frozen months only; explicit validate_integrity calls check the range asked.
-- Run as  : TELCO_OWNER
-- =============================================================================

create or replace package dlm_pkg authid definer as

  c_main     constant varchar2(30) := 'BILLING_RECORDS';
  c_archive  constant varchar2(30) := 'BILLING_ARCHIVE';
  c_xchg     constant varchar2(30) := 'BILLING_XCHG';

  -- Row fingerprint (every column) used for integrity control totals.
  c_hash_expr constant varchar2(1000) :=
    'ora_hash(record_id || ''|'' || invoice_id || ''|'' || customer_id || ''|'' || ' ||
    'plan_id || ''|'' || to_char(bill_date, ''YYYYMMDDHH24MISS'') || ''|'' || ' ||
    'service_type || ''|'' || region_code || ''|'' || duration_sec || ''|'' || ' ||
    'to_char(volume_mb, ''FM99999990.00'') || ''|'' || to_char(amount, ''FM99999990.00'') || ''|'' || ' ||
    'to_char(tax_amount, ''FM99999990.00'') || ''|'' || payment_status)';

  e_refused exception;
  pragma exception_init(e_refused, -20010);

  -- configuration
  function  get_param(p_name in varchar2) return varchar2;
  function  as_of_month return date;

  -- logging (autonomous transaction: survives a rollback of the caller)
  procedure log_event(p_run_id in number, p_job in varchar2, p_action in varchar2,
                      p_target in varchar2, p_rows in number, p_elapsed in number,
                      p_status in varchar2, p_message in varchar2 default null);

  -- partition helpers
  function  partition_month(p_table in varchar2, p_partition in varchar2) return date;
  function  partition_for(p_table in varchar2, p_month in date) return varchar2;
  procedure rename_partitions(p_table in varchar2);

  -- lifecycle operations (one month each)
  -- p_as_of: reference month for the guards (default: AS_OF_MONTH in DLM_CONFIG)
  procedure warm_partition   (p_month in date, p_run_id in number default null,
                              p_as_of in date default null);
  procedure archive_partition(p_month in date, p_run_id in number default null,
                              p_simulate_failure in varchar2 default null,
                              p_as_of in date default null);
  procedure purge_partition  (p_month in date, p_run_id in number default null,
                              p_retention_months in pls_integer default null,
                              p_as_of in date default null);

  -- application write window: (re)creates BILLING_CURRENT_V WITH CHECK OPTION so
  -- the billing application can only write HOT months (no late rows in warm,
  -- archived or purged months, no far-future dates)
  procedure refresh_app_window(p_as_of in date default null);

  -- full policy run
  procedure run_lifecycle(p_as_of in date default null, p_dry_run in boolean default false);

  -- integrity
  procedure capture_control_totals(p_table in varchar2);
  procedure capture_month_totals(p_table in varchar2, p_month in date);
  function  validate_integrity(p_view in varchar2, p_from_month in date default null,
                               p_run_id in number default null,
                               p_to_month in date default null) return number;
end dlm_pkg;
/

create or replace package body dlm_pkg as

  c_job_lock constant integer := 220022;   -- DBMS_LOCK id of the lifecycle job lock

  -- ---------------------------------------------------------------------------
  function get_param(p_name in varchar2) return varchar2 is
    l_value dlm_config.param_value%type;
  begin
    select param_value into l_value from dlm_config where param_name = upper(p_name);
    return l_value;
  end get_param;

  function as_of_month return date is
  begin
    return to_date(get_param('AS_OF_MONTH'), 'YYYY-MM');
  end as_of_month;

  function months_param(p_name in varchar2) return pls_integer is
  begin
    return to_number(get_param(p_name));
  end months_param;

  function elapsed_since(p_t0 in number) return number is
  begin
    return (dbms_utility.get_time - p_t0) / 100;
  end elapsed_since;

  function month_label(p_month in date) return varchar2 is
  begin
    return to_char(p_month, 'YYYY-MM');
  end month_label;

  function date_literal(p_month in date) return varchar2 is
  begin
    return 'date ''' || to_char(p_month, 'YYYY-MM-DD') || '''';
  end date_literal;

  -- ---------------------------------------------------------------------------
  procedure log_event(p_run_id in number, p_job in varchar2, p_action in varchar2,
                      p_target in varchar2, p_rows in number, p_elapsed in number,
                      p_status in varchar2, p_message in varchar2 default null) is
    pragma autonomous_transaction;
  begin
    insert into dlm_job_log (run_id, job_name, action, target, rows_affected,
                             elapsed_sec, status, message)
    values (p_run_id, p_job, p_action, p_target, p_rows, p_elapsed, p_status,
            substr(p_message, 1, 4000));
    commit;
  end log_event;

  -- ---------------------------------------------------------------------------
  -- HIGH_VALUE is a LONG holding an expression such as TO_DATE(' 2021-01-01 ...').
  -- Evaluating it gives the exclusive upper bound; the month is one month before.
  function partition_month(p_table in varchar2, p_partition in varchar2) return date is
    l_high varchar2(4000);
    l_date date;
  begin
    for r in (select high_value from user_tab_partitions
              where table_name = upper(p_table) and partition_name = upper(p_partition)) loop
      l_high := r.high_value;
    end loop;
    if l_high is null then
      return null;
    end if;
    execute immediate 'select ' || l_high || ' from dual' into l_date;
    return add_months(l_date, -1);
  end partition_month;

  function partition_for(p_table in varchar2, p_month in date) return varchar2 is
  begin
    for r in (select partition_name from user_tab_partitions
              where table_name = upper(p_table) and partition_name <> 'P_INITIAL') loop
      if partition_month(p_table, r.partition_name) = trunc(p_month, 'MM') then
        return r.partition_name;
      end if;
    end loop;
    return null;
  end partition_for;

  -- Interval partitions get system names (SYS_P123). Rename table and local
  -- index partitions to P_YYYYMM so operators and scripts can read them.
  procedure rename_partitions(p_table in varchar2) is
    type t_names is table of varchar2(128);
    l_parts t_names;
    l_new   varchar2(128);
  begin
    select partition_name bulk collect into l_parts
    from   user_tab_partitions
    where  table_name = upper(p_table) and partition_name <> 'P_INITIAL';

    for i in 1 .. l_parts.count loop
      l_new := 'P_' || to_char(partition_month(p_table, l_parts(i)), 'YYYYMM');
      if l_parts(i) <> l_new then
        execute immediate 'alter table ' || p_table || ' rename partition '
                          || l_parts(i) || ' to ' || l_new;
      end if;
    end loop;

    for r in (select ip.index_name, ip.partition_name as index_part, tp.partition_name as table_part
              from   user_part_indexes pi
              join   user_ind_partitions ip on ip.index_name = pi.index_name
              join   user_tab_partitions tp on tp.table_name = pi.table_name
                                           and tp.partition_position = ip.partition_position
              where  pi.table_name = upper(p_table)
              and    pi.locality = 'LOCAL'
              and    ip.partition_name <> tp.partition_name) loop
      execute immediate 'alter index ' || r.index_name || ' rename partition '
                        || r.index_part || ' to ' || r.table_part;
    end loop;
  end rename_partitions;

  function count_partition(p_table in varchar2, p_partition in varchar2) return number is
    l_count number;
  begin
    execute immediate 'select count(*) from ' || p_table || ' partition (' || p_partition || ')'
      into l_count;
    return l_count;
  end count_partition;

  -- Cheap emptiness test: stops at the first row found.
  function is_empty(p_table in varchar2, p_partition in varchar2) return boolean is
    l_count number;
  begin
    execute immediate 'select count(*) from ' || p_table || ' partition (' || p_partition ||
                      ') where rownum = 1' into l_count;
    return l_count = 0;
  end is_empty;

  -- True when the month needs no WARM step (already compressed in TELCO_ARCH,
  -- or no online partition).
  function is_warm(p_month in date) return boolean is
    l_part  varchar2(128) := partition_for(c_main, p_month);
    l_count number;
  begin
    if l_part is null then
      return true;
    end if;
    select count(*) into l_count
    from   user_tab_partitions tp
    where  tp.table_name = c_main and tp.partition_name = l_part
    and    tp.tablespace_name = 'TELCO_ARCH' and tp.compression = 'ENABLED'
    and    tp.read_only = 'YES'
    and    not exists (select 1
                       from   user_part_indexes pi
                       join   user_ind_partitions ip on ip.index_name = pi.index_name
                       where  pi.table_name = c_main and pi.locality = 'LOCAL'
                       and    ip.partition_position = tp.partition_position
                       and    (ip.status <> 'USABLE' or ip.tablespace_name <> 'TELCO_ARCH'));
    return l_count > 0;
  end is_warm;

  -- Rebuild the local index partitions of one table partition in TELCO_ARCH
  -- (matched by POSITION: system-named table and index partitions differ).
  procedure rebuild_local_indexes(p_part in varchar2) is
  begin
    for r in (select ip.index_name, ip.partition_name
              from   user_tab_partitions tp
              join   user_part_indexes pi on pi.table_name = tp.table_name and pi.locality = 'LOCAL'
              join   user_ind_partitions ip on ip.index_name = pi.index_name
                                           and ip.partition_position = tp.partition_position
              where  tp.table_name = c_main and tp.partition_name = p_part
              and    (ip.status <> 'USABLE' or ip.tablespace_name <> 'TELCO_ARCH')) loop
      execute immediate 'alter index ' || r.index_name || ' rebuild partition '
                        || r.partition_name || ' tablespace telco_arch';
    end loop;
  end rebuild_local_indexes;

  -- Partition DDL waits up to 60 s for in-flight DML instead of failing at once
  -- with ORA-00054 (the billing application inserts continuously).
  function is_warm_storage(p_part in varchar2) return boolean is
    l_count number;
  begin
    select count(*) into l_count from user_tab_partitions
    where  table_name = c_main and partition_name = p_part
    and    tablespace_name = 'TELCO_ARCH' and compression = 'ENABLED';
    return l_count > 0;
  end is_warm_storage;

  procedure set_lock_timeout is
  begin
    execute immediate 'alter session set ddl_lock_timeout = 60';
  end set_lock_timeout;

  procedure set_read_only(p_table in varchar2, p_partition in varchar2, p_read_only in boolean) is
  begin
    execute immediate 'alter table ' || p_table || ' modify partition ' || p_partition ||
                      case when p_read_only then ' read only' else ' read write' end;
  end set_read_only;

  procedure refuse(p_run_id in number, p_job in varchar2, p_action in varchar2,
                   p_target in varchar2, p_reason in varchar2) is
  begin
    log_event(p_run_id, p_job, p_action, p_target, null, 0, 'REFUSED', p_reason);
    raise_application_error(-20010, p_action || ' ' || p_target || ' refused: ' || p_reason);
  end refuse;

  -- ---------------------------------------------------------------------------
  -- One lifecycle operation at a time: two sessions sharing BILLING_XCHG could
  -- otherwise mix two months. A session-level user lock (DBMS_LOCK, base
  -- product) is used because DDL commits would release a table or row lock.
  -- Nested calls (run_lifecycle -> archive -> warm) already own it.

  function take_job_lock(p_action in varchar2, p_month in date) return boolean is
    l_rc integer;
  begin
    l_rc := dbms_lock.request(id => c_job_lock, lockmode => dbms_lock.x_mode,
                              timeout => 0, release_on_commit => false);
    if l_rc = 0 then
      return true;
    elsif l_rc = 4 then          -- already held by this session (nested call)
      return false;
    end if;
    log_event(null, 'DLM', p_action, month_label(p_month), null, 0, 'REFUSED',
              'another lifecycle operation is running');
    raise_application_error(-20050, p_action || ' refused: another lifecycle operation is running');
  end take_job_lock;

  procedure release_job_lock(p_own in boolean) is
    l_rc integer;
  begin
    if p_own then
      l_rc := dbms_lock.release(c_job_lock);
    end if;
  end release_job_lock;

  -- ---------------------------------------------------------------------------
  -- WARM: freeze the month (re-capture its control totals), move it to the
  -- archive tablespace with BASIC compression, rebuild its local index
  -- partition there, and make it read-only.
  procedure warm_partition_impl(p_month in date, p_run_id in number default null,
                           p_as_of in date default null) is
    l_month  date := trunc(p_month, 'MM');
    l_as_of  date := nvl(trunc(p_as_of, 'MM'), as_of_month);
    l_part   varchar2(128);
    l_ts     varchar2(30);
    l_comp   varchar2(30);
    l_rows   number;
    l_t0     number := dbms_utility.get_time;
  begin
    if l_month >= add_months(l_as_of, -months_param('HOT_MONTHS')) then
      refuse(p_run_id, 'DLM', 'WARM', month_label(l_month), 'month is still in the HOT window');
    end if;

    l_part := partition_for(c_main, l_month);
    if l_part is null then
      log_event(p_run_id, 'DLM', 'WARM', month_label(l_month), 0, 0, 'SKIPPED', 'no partition');
      return;
    end if;
    if is_warm(l_month) then
      log_event(p_run_id, 'DLM', 'WARM', l_part, 0, 0, 'SKIPPED', 'already warm');
      return;
    end if;

    set_lock_timeout;
    select tablespace_name, compression into l_ts, l_comp
    from   user_tab_partitions
    where  table_name = c_main and partition_name = l_part;

    -- 1. Freeze FIRST: READ ONLY waits for in-flight transactions on the month
    --    and blocks new ones, so nothing can change between the capture and the move.
    set_read_only(c_main, l_part, true);

    if not (l_ts = 'TELCO_ARCH' and l_comp = 'ENABLED') then
      -- 2. The frozen content becomes the integrity reference.
      capture_month_totals(c_main, l_month);
      -- 3. MOVE is allowed on a read-only partition (it does not change the rows).
      execute immediate 'alter table ' || c_main || ' move partition ' || l_part ||
                        ' tablespace telco_arch row store compress basic update global indexes';
    end if;
    -- 4. (also completes a warm interrupted after the move)
    rebuild_local_indexes(l_part);

    l_rows := count_partition(c_main, l_part);
    log_event(p_run_id, 'DLM', 'WARM', l_part, l_rows, elapsed_since(l_t0), 'OK',
              case when l_ts = 'TELCO_ARCH' and l_comp = 'ENABLED'
                   then 'completed an interrupted warm: ' end ||
              'moved to TELCO_ARCH, compressed, read only');
  exception
    when e_refused then raise;
    when others then
      log_event(p_run_id, 'DLM', 'WARM', nvl(l_part, month_label(l_month)), null,
                elapsed_since(l_t0), 'ERROR', sqlerrm);
      raise;
  end warm_partition_impl;

  -- ---------------------------------------------------------------------------
  -- ARCHIVE: move one month from BILLING_RECORDS to BILLING_ARCHIVE without
  -- copying a single row - two partition exchanges through BILLING_XCHG:
  --   1. BILLING_RECORDS partition  <->  BILLING_XCHG     (data now in XCHG)
  --   2. BILLING_ARCHIVE partition  <->  BILLING_XCHG     (data now archived)
  --   3. drop the (now empty) BILLING_RECORDS partition
  -- A month that is not warm yet is warmed first, so the archive is always
  -- compressed and stored in TELCO_ARCH.
  -- If the job dies between steps 1 and 2 the data waits safely in BILLING_XCHG;
  -- the next run detects it and resumes at step 2 (never truncates it).
  procedure archive_partition_impl(p_month in date, p_run_id in number default null,
                              p_simulate_failure in varchar2 default null,
                              p_as_of in date default null) is
    l_month    date := trunc(p_month, 'MM');
    l_as_of    date := nvl(trunc(p_as_of, 'MM'), as_of_month);
    l_part     varchar2(128);
    l_apart    varchar2(128);
    l_rows     number := 0;
    l_staged   number;
    l_archived number;
    l_min      date;
    l_max      date;
    l_resumed  boolean := false;
    l_t0       number := dbms_utility.get_time;
  begin
    set_lock_timeout;
    if l_month >= add_months(l_as_of, -months_param('ONLINE_MONTHS')) then
      refuse(p_run_id, 'DLM', 'ARCHIVE', month_label(l_month),
             'month is still inside the ' || months_param('ONLINE_MONTHS') || '-month online window');
    end if;

    -- Step 0: is there a month left in the exchange table by an interrupted run?
    execute immediate 'select count(*), min(bill_date), max(bill_date) from ' || c_xchg
      into l_staged, l_min, l_max;
    if l_staged > 0 then
      if trunc(l_min, 'MM') <> l_month or trunc(l_max, 'MM') <> l_month then
        refuse(p_run_id, 'DLM', 'ARCHIVE', month_label(l_month),
               c_xchg || ' holds ' || l_staged || ' rows of another month ('
               || month_label(l_min) || '): manual check required');
      end if;
      l_resumed := true;
      l_rows    := l_staged;
      log_event(p_run_id, 'DLM', 'ARCHIVE', month_label(l_month), l_staged, 0, 'RESUMED',
                'found staged rows from an interrupted run - resuming at step 2');
    end if;

    l_part := partition_for(c_main, l_month);

    if not l_resumed then
      if l_part is null then
        log_event(p_run_id, 'DLM', 'ARCHIVE', month_label(l_month), 0, 0, 'SKIPPED', 'no partition');
        return;
      end if;

      -- An empty partition (e.g. created by a rejected late insert) holds
      -- nothing to archive: drop it instead of exchanging.
      if is_empty(c_main, l_part) then
        set_read_only(c_main, l_part, false);
        execute immediate 'alter table ' || c_main || ' drop partition ' || l_part ||
                          ' update global indexes';
        log_event(p_run_id, 'DLM', 'ARCHIVE', l_part, 0, elapsed_since(l_t0), 'SKIPPED',
                  'empty partition dropped (nothing to archive)');
        return;
      end if;

      -- refuse BEFORE step 1, while the month is still in place
      execute immediate 'select count(*) from ' || c_archive ||
                        ' where bill_date >= :1 and bill_date < :2 and rownum = 1'
        into l_staged using l_month, add_months(l_month, 1);
      if l_staged > 0 then
        refuse(p_run_id, 'DLM', 'ARCHIVE', month_label(l_month),
               c_archive || ' already holds data for this month');
      end if;

      if not is_warm(l_month) then
        warm_partition(l_month, p_run_id, l_as_of);
        l_part := partition_for(c_main, l_month);
      end if;

      l_rows := count_partition(c_main, l_part);
      set_read_only(c_main, l_part, false);

      -- Step 1: partition -> exchange table (metadata swap + global index upkeep)
      execute immediate 'alter table ' || c_main || ' exchange partition ' || l_part ||
                        ' with table ' || c_xchg ||
                        ' including indexes without validation update global indexes';

      if p_simulate_failure = 'AFTER_STEP1' then
        log_event(p_run_id, 'DLM', 'ARCHIVE', l_part, l_rows, elapsed_since(l_t0), 'ERROR',
                  'SIMULATED FAILURE after step 1 (data is safe in ' || c_xchg || ')');
        raise_application_error(-20020, 'Simulated failure after step 1');
      end if;
    end if;

    -- Step 2: create the archive partition for this month and swap it in
    execute immediate 'lock table ' || c_archive || ' partition for (' ||
                      date_literal(l_month) || ') in share mode';
    rename_partitions(c_archive);
    l_apart := partition_for(c_archive, l_month);

    if not is_empty(c_archive, l_apart) then
      refuse(p_run_id, 'DLM', 'ARCHIVE', l_apart, 'archive partition already contains data');
    end if;

    execute immediate 'alter table ' || c_archive || ' exchange partition ' || l_apart ||
                      ' with table ' || c_xchg || ' including indexes without validation';

    l_archived := count_partition(c_archive, l_apart);
    if l_archived <> l_rows then
      log_event(p_run_id, 'DLM', 'ARCHIVE', l_apart, l_archived, elapsed_since(l_t0), 'ERROR',
                'row count mismatch: expected ' || l_rows || ', archived ' || l_archived);
      raise_application_error(-20030, 'Row count mismatch while archiving ' || month_label(l_month));
    end if;
    set_read_only(c_archive, l_apart, true);

    -- Step 3: drop the empty online partition
    l_part := partition_for(c_main, l_month);
    if l_part is not null then
      set_read_only(c_main, l_part, false);
      execute immediate 'alter table ' || c_main || ' drop partition ' || l_part ||
                        ' update global indexes';
    end if;

    log_event(p_run_id, 'DLM', 'ARCHIVE', l_apart, l_rows, elapsed_since(l_t0), 'OK',
              case when l_resumed then 'resumed after interruption; ' end ||
              'exchanged into ' || c_archive || ', read only');
  exception
    when e_refused then raise;
    when others then
      if sqlcode <> -20020 then
        log_event(p_run_id, 'DLM', 'ARCHIVE', nvl(l_part, month_label(l_month)), null,
                  elapsed_since(l_t0), 'ERROR', sqlerrm);
      end if;
      -- never leave a frozen (warm) month writable after a failure
      begin
        l_part := partition_for(c_main, l_month);
        if l_part is not null and is_warm_storage(l_part) then
          set_read_only(c_main, l_part, true);
        end if;
      exception
        when others then null;
      end;
      raise;
  end archive_partition_impl;

  -- ---------------------------------------------------------------------------
  -- PURGE: drop a month that is past legal retention. Metadata operation:
  -- no DELETE, no undo, no redo for the rows.
  procedure purge_partition_impl(p_month in date, p_run_id in number default null,
                            p_retention_months in pls_integer default null,
                            p_as_of in date default null) is
    l_month     date := trunc(p_month, 'MM');
    l_as_of     date := nvl(trunc(p_as_of, 'MM'), as_of_month);
    l_retention pls_integer := nvl(p_retention_months, months_param('RETENTION_MONTHS'));
    l_floor     pls_integer := months_param('MIN_RETENTION_MONTHS');
    l_part      varchar2(128);
    l_table     varchar2(30);
    l_rows      number := 0;
    l_t0        number := dbms_utility.get_time;
  begin
    set_lock_timeout;
    if l_retention < l_floor then
      refuse(p_run_id, 'DLM', 'PURGE', month_label(l_month),
             'requested retention ' || l_retention || ' months is below the legal floor of '
             || l_floor || ' months');
    end if;
    if l_month >= add_months(l_as_of, -l_retention) then
      refuse(p_run_id, 'DLM', 'PURGE', month_label(l_month),
             'month is still inside the ' || l_retention || '-month retention period');
    end if;

    execute immediate 'select count(*) from ' || c_xchg ||
                      ' where bill_date >= :1 and bill_date < :2 and rownum = 1'
      into l_rows using l_month, add_months(l_month, 1);
    if l_rows > 0 then
      refuse(p_run_id, 'DLM', 'PURGE', month_label(l_month),
             'rows of this month wait in ' || c_xchg || ': resume the archive first');
    end if;

    for t in (select c_archive as tab from dual union all select c_main from dual) loop
      l_part := partition_for(t.tab, l_month);
      if l_part is not null then
        l_table := t.tab;
        l_rows  := l_rows + count_partition(t.tab, l_part);
        set_read_only(t.tab, l_part, false);
        execute immediate 'alter table ' || t.tab || ' drop partition ' || l_part ||
                          case when t.tab = c_main then ' update global indexes' end;
      end if;
    end loop;

    if l_table is null then
      log_event(p_run_id, 'DLM', 'PURGE', month_label(l_month), 0, 0, 'SKIPPED', 'nothing to purge');
    else
      log_event(p_run_id, 'DLM', 'PURGE', l_table || ':' || month_label(l_month), l_rows,
                elapsed_since(l_t0), 'OK', 'partition dropped');
    end if;
  exception
    when e_refused then raise;
    when others then
      log_event(p_run_id, 'DLM', 'PURGE', month_label(l_month), null,
                elapsed_since(l_t0), 'ERROR', sqlerrm);
      raise;
  end purge_partition_impl;

  -- ---------------------------------------------------------------------------
  procedure refresh_app_window(p_as_of in date default null) is
    l_as_of date := nvl(trunc(p_as_of, 'MM'), as_of_month);
    l_from  date := add_months(l_as_of, -months_param('HOT_MONTHS'));
    l_to    date := add_months(l_as_of, 2);
  begin
    -- never re-open a month that is already frozen (e.g. after a run with a
    -- later p_as_of, or after HOT_MONTHS was increased)
    for r in (select partition_name from user_tab_partitions
              where table_name = c_main and read_only = 'YES') loop
      l_from := greatest(l_from, add_months(partition_month(c_main, r.partition_name), 1));
    end loop;
    -- CREATE OR REPLACE keeps the grants given to TELCO_APP.
    execute immediate 'create or replace view billing_current_v as select * from ' || c_main ||
                      ' where bill_date >= ' || date_literal(l_from) ||
                      ' and bill_date < ' || date_literal(l_to) ||
                      ' with check option constraint billing_current_v_ck';
    log_event(null, 'DLM', 'APP_WINDOW', 'BILLING_CURRENT_V', null, 0, 'OK',
              'application may read/write ' || month_label(l_from) || ' .. '
              || month_label(add_months(l_to, -1)));
  end refresh_app_window;

  -- ---------------------------------------------------------------------------
  procedure run_lifecycle_impl(p_as_of in date default null, p_dry_run in boolean default false) is
    type t_months is table of date;
    type t_names  is table of varchar2(128);
    l_as_of      date := nvl(trunc(p_as_of, 'MM'), as_of_month);
    l_hot_cut    date := add_months(l_as_of, -months_param('HOT_MONTHS'));
    l_online_cut date := add_months(l_as_of, -months_param('ONLINE_MONTHS'));
    l_purge_cut  date := add_months(l_as_of, -months_param('RETENTION_MONTHS'));
    l_window_end date := add_months(l_as_of, 2);
    l_run_id     number := dlm_run_seq.nextval;
    l_names      t_names;
    l_months     t_months := t_months();
    l_archived   t_months := t_months();
    l_staged     number;
    l_staged_m   date;
    l_bad        number;
    l_t0         number := dbms_utility.get_time;

    procedure plan_or_do(p_action varchar2, p_month date) is
    begin
      if p_dry_run then
        log_event(l_run_id, 'DLM', p_action, month_label(p_month), null, 0, 'PLANNED');
      elsif p_action = 'PURGE' then
        purge_partition(p_month, l_run_id, p_as_of => l_as_of);
      elsif p_action = 'WARM' then
        warm_partition(p_month, l_run_id, l_as_of);
      else
        archive_partition(p_month, l_run_id, p_as_of => l_as_of);
      end if;
    end;

    -- dry run only: an empty partition outside the window is planned for
    -- DROP_EMPTY in step 0b, so it must not also be planned for WARM/ARCHIVE
    function stray_in_dry_run(p_month date) return boolean is
      l_part varchar2(128);
    begin
      if not p_dry_run or (p_month >= l_hot_cut and p_month < l_window_end) then
        return false;
      end if;
      l_part := partition_for(c_main, p_month);
      return l_part is not null and is_empty(c_main, l_part);
    end;

    -- months of a partitioned table, in chronological order
    function list_months(p_table varchar2) return t_months is
      l_list t_months := t_months();
    begin
      select partition_name bulk collect into l_names
      from   user_tab_partitions
      where  table_name = p_table and partition_name <> 'P_INITIAL'
      order  by partition_position;
      for i in 1 .. l_names.count loop
        l_list.extend;
        l_list(l_list.count) := partition_month(p_table, l_names(i));
      end loop;
      return l_list;
    end;
  begin
    log_event(l_run_id, 'DLM', 'RUN_START', 'as_of=' || month_label(l_as_of), null, 0, 'OK',
              case when p_dry_run then 'dry run' end);

    if not p_dry_run then
      set_lock_timeout;
      -- close the application window on the months about to be frozen BEFORE
      -- freezing them, and give new (system-named) partitions readable names
      refresh_app_window(l_as_of);
      rename_partitions(c_main);
    end if;

    -- 0a. resume an archive interrupted by a previous run
    execute immediate 'select count(*), trunc(min(bill_date), ''MM'') from ' || c_xchg
      into l_staged, l_staged_m;
    if l_staged > 0 then
      plan_or_do('ARCHIVE', l_staged_m);
    end if;

    -- 0b. remove empty partitions outside the application window (left by
    --     inserts that were rejected, e.g. late or far-future dates)
    select partition_name bulk collect into l_names
    from   user_tab_partitions
    where  table_name = c_main and partition_name <> 'P_INITIAL'
    order  by partition_position;
    for i in 1 .. l_names.count loop
      declare
        l_m date := partition_month(c_main, l_names(i));
      begin
        if (l_m < l_hot_cut or l_m >= l_window_end) and is_empty(c_main, l_names(i)) then
          if p_dry_run then
            log_event(l_run_id, 'DLM', 'DROP_EMPTY', l_names(i), 0, 0, 'PLANNED');
          else
            set_read_only(c_main, l_names(i), false);
            execute immediate 'alter table ' || c_main || ' drop partition ' || l_names(i) ||
                              ' update global indexes';
            log_event(l_run_id, 'DLM', 'DROP_EMPTY', l_names(i) || ' (' || month_label(l_m) || ')',
                      0, 0, 'OK', 'empty partition outside the application window');
          end if;
        end if;
      end;
    end loop;

    -- 0c. archive partitions are always read-only (repairs a run interrupted
    --     between the second exchange and the final READ ONLY)
    for r in (select partition_name from user_tab_partitions
              where table_name = c_archive and partition_name <> 'P_INITIAL'
              and read_only = 'NO') loop
      if not is_empty(c_archive, r.partition_name) then
        if p_dry_run then
          log_event(l_run_id, 'DLM', 'ARCHIVE_RO', r.partition_name, 0, 0, 'PLANNED');
        else
          set_read_only(c_archive, r.partition_name, true);
          log_event(l_run_id, 'DLM', 'ARCHIVE_RO', r.partition_name, 0, 0, 'OK',
                    'archive partition found read/write - set read only');
        end if;
      end if;
    end loop;

    l_months   := list_months(c_main);
    l_archived := list_months(c_archive);

    -- 1. purge first: frees space before anything is moved
    for i in 1 .. l_archived.count loop
      if l_archived(i) < l_purge_cut then plan_or_do('PURGE', l_archived(i)); end if;
    end loop;
    for i in 1 .. l_months.count loop
      if l_months(i) < l_purge_cut then plan_or_do('PURGE', l_months(i)); end if;
    end loop;

    -- 2. warm: compress everything older than the hot window (not yet warm)
    for i in 1 .. l_months.count loop
      if l_months(i) >= l_purge_cut and l_months(i) < l_hot_cut and not is_warm(l_months(i))
         and not stray_in_dry_run(l_months(i)) then
        plan_or_do('WARM', l_months(i));
      end if;
    end loop;

    -- 3. archive: months older than the online window
    for i in 1 .. l_months.count loop
      if l_months(i) >= l_purge_cut and l_months(i) < l_online_cut
         and partition_for(c_main, l_months(i)) is not null
         and not stray_in_dry_run(l_months(i))
         and not (p_dry_run and l_staged > 0 and l_months(i) = l_staged_m) then
        plan_or_do('ARCHIVE', l_months(i));
      end if;
    end loop;

    if not p_dry_run then
      dbms_stats.gather_table_stats(user, c_main);
      dbms_stats.gather_table_stats(user, c_archive);
      -- frozen months only: HOT months are live and change legitimately
      l_bad := validate_integrity('BILLING_ALL', l_purge_cut, l_run_id, l_hot_cut);
      if l_bad > 0 then
        raise_application_error(-20040, 'Integrity validation failed for ' || l_bad || ' month(s)');
      end if;
    end if;

    log_event(l_run_id, 'DLM', 'RUN_END', 'as_of=' || month_label(l_as_of), null,
              elapsed_since(l_t0), 'OK');
  end run_lifecycle_impl;

  -- ---------------------------------------------------------------------------
  procedure merge_totals(p_source_sql in varchar2) is
  begin
    execute immediate
      'merge into billing_control_totals t
       using (select trunc(bill_date, ''MM'') m, count(*) c, sum(amount) s, sum(' || c_hash_expr || ') h
              from (' || p_source_sql || ')
              group by trunc(bill_date, ''MM'')) s
       on (t.month_start = s.m)
       when matched then update set t.row_count = s.c, t.sum_amount = s.s,
                                    t.hash_sum = s.h, t.captured_at = systimestamp
       when not matched then insert (month_start, row_count, sum_amount, hash_sum)
                             values (s.m, s.c, s.s, s.h)';
    commit;
  end merge_totals;

  procedure capture_control_totals(p_table in varchar2) is
  begin
    merge_totals('select * from ' || dbms_assert.simple_sql_name(p_table));
  end capture_control_totals;

  procedure capture_month_totals(p_table in varchar2, p_month in date) is
  begin
    merge_totals('select * from ' || dbms_assert.simple_sql_name(p_table) ||
                 ' where bill_date >= ' || date_literal(trunc(p_month, 'MM')) ||
                 ' and bill_date < ' || date_literal(add_months(trunc(p_month, 'MM'), 1)));
  end capture_month_totals;

  -- Compares every month of [p_from_month, p_to_month) present in p_view with
  -- the control totals (row count, amount total and row-fingerprint sum).
  -- Months before p_from_month must be gone (purged): any row found there is an
  -- error, so p_from_month is a retention cut, not just a display filter.
  -- p_to_month null = no upper bound. Returns the number of months in error.
  function validate_integrity(p_view in varchar2, p_from_month in date default null,
                              p_run_id in number default null,
                              p_to_month in date default null) return number is
    l_from  date := nvl(p_from_month, add_months(as_of_month, -months_param('RETENTION_MONTHS')));
    l_to    date := nvl(p_to_month, date '9999-12-01');
    l_bad   number;
    l_total number;
    l_t0    number := dbms_utility.get_time;
  begin
    execute immediate
      'select count(case when c.month_start is null or v.m is null
                          or c.row_count <> v.c or c.sum_amount <> v.s or c.hash_sum <> v.h
                         then 1 end),
              count(*)
       from  (select * from billing_control_totals
              where month_start >= :from_month and month_start < :to_month) c
       full outer join
             (select trunc(bill_date, ''MM'') m, count(*) c, sum(amount) s, sum(' || c_hash_expr || ') h
              from ' || dbms_assert.simple_sql_name(p_view) || '
              where bill_date < :to_month2
              group by trunc(bill_date, ''MM'')) v
       on v.m = c.month_start'
      into l_bad, l_total
      using l_from, l_to, l_to;

    log_event(p_run_id, 'DLM', 'VALIDATE', p_view, l_total, elapsed_since(l_t0),
              case when l_bad = 0 then 'OK' else 'ERROR' end,
              l_total - l_bad || '/' || l_total || ' months match control totals (from '
              || month_label(l_from) ||
              case when p_to_month is not null then ' to ' || month_label(add_months(l_to, -1)) end || ')');
    return l_bad;
  end validate_integrity;

  -- ---------------------------------------------------------------------------
  -- Public entry points: take the job lock, run, always release it.
  procedure warm_partition(p_month in date, p_run_id in number default null,
                           p_as_of in date default null) is
    l_own boolean := take_job_lock('WARM', trunc(p_month, 'MM'));
  begin
    warm_partition_impl(p_month, p_run_id, p_as_of);
    release_job_lock(l_own);
  exception
    when others then release_job_lock(l_own); raise;
  end warm_partition;

  procedure archive_partition(p_month in date, p_run_id in number default null,
                              p_simulate_failure in varchar2 default null,
                              p_as_of in date default null) is
    l_own boolean := take_job_lock('ARCHIVE', trunc(p_month, 'MM'));
  begin
    archive_partition_impl(p_month, p_run_id, p_simulate_failure, p_as_of);
    release_job_lock(l_own);
  exception
    when others then release_job_lock(l_own); raise;
  end archive_partition;

  procedure purge_partition(p_month in date, p_run_id in number default null,
                            p_retention_months in pls_integer default null,
                            p_as_of in date default null) is
    l_own boolean := take_job_lock('PURGE', trunc(p_month, 'MM'));
  begin
    purge_partition_impl(p_month, p_run_id, p_retention_months, p_as_of);
    release_job_lock(l_own);
  exception
    when others then release_job_lock(l_own); raise;
  end purge_partition;

  procedure run_lifecycle(p_as_of in date default null, p_dry_run in boolean default false) is
    l_own boolean := false;
  begin
    if not p_dry_run then     -- a dry run changes nothing: no lock needed
      l_own := take_job_lock('RUN', nvl(trunc(p_as_of, 'MM'), as_of_month));
    end if;
    run_lifecycle_impl(p_as_of, p_dry_run);
    release_job_lock(l_own);
  exception
    when others then release_job_lock(l_own); raise;
  end run_lifecycle;

end dlm_pkg;
/
show errors package body dlm_pkg
