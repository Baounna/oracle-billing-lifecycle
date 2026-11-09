-- =============================================================================
-- 06_baseline_pkg.sql
-- Purpose : The client's CURRENT way of managing retention on a single heap
--           table - used as the "before" reference in the benchmarks.
--             archive = INSERT INTO archive SELECT ... + DELETE ... (row by row work)
--             purge   = DELETE ... (undo + redo for every row, space not released)
--           Same policy (DLM_CONFIG) and same guards as DLM_PKG (online window
--           for archive, retention + legal floor for purge), so the comparison
--           only measures the technique, not different rules.
-- Run as  : TELCO_OWNER
-- =============================================================================

create or replace package baseline_pkg authid definer as
  -- p_as_of: reference month for the guards (default: AS_OF_MONTH in DLM_CONFIG)
  procedure archive_month(p_month in date, p_run_id in number default null,
                          p_as_of in date default null);
  procedure purge_month  (p_month in date, p_run_id in number default null,
                          p_as_of in date default null);
  procedure run_lifecycle(p_as_of in date default null);
end baseline_pkg;
/

create or replace package body baseline_pkg as

  procedure refuse(p_run_id number, p_action varchar2, p_month date, p_reason varchar2) is
  begin
    dlm_pkg.log_event(p_run_id, 'BASELINE', p_action, to_char(p_month, 'YYYY-MM'),
                      null, 0, 'REFUSED', p_reason);
    raise_application_error(-20010, p_action || ' ' || to_char(p_month, 'YYYY-MM') ||
                                    ' refused: ' || p_reason);
  end refuse;

  -- Same rule as DLM_PKG.archive_partition: only months older than ONLINE_MONTHS.
  procedure archive_month(p_month in date, p_run_id in number default null,
                          p_as_of in date default null) is
    l_from     date := trunc(p_month, 'MM');
    l_to       date := add_months(trunc(p_month, 'MM'), 1);
    l_as_of    date := nvl(trunc(p_as_of, 'MM'), dlm_pkg.as_of_month);
    l_inserted number;
    l_deleted  number;
    l_t0       number := dbms_utility.get_time;
  begin
    if l_from >= add_months(l_as_of, -to_number(dlm_pkg.get_param('ONLINE_MONTHS'))) then
      refuse(p_run_id, 'ARCHIVE', l_from, 'month is still inside the online window');
    end if;

    insert into billing_archive_base
      select * from billing_records_base where bill_date >= l_from and bill_date < l_to;
    l_inserted := sql%rowcount;

    delete from billing_records_base where bill_date >= l_from and bill_date < l_to;
    l_deleted := sql%rowcount;

    if l_inserted <> l_deleted then
      rollback;
      raise_application_error(-20030, 'Row count mismatch: inserted ' || l_inserted ||
                                      ', deleted ' || l_deleted);
    end if;
    commit;
    dlm_pkg.log_event(p_run_id, 'BASELINE', 'ARCHIVE', to_char(l_from, 'YYYY-MM'), l_deleted,
                      (dbms_utility.get_time - l_t0) / 100, 'OK', 'insert-select + delete');
  exception
    when others then
      rollback;
      if sqlcode <> -20010 then
        dlm_pkg.log_event(p_run_id, 'BASELINE', 'ARCHIVE', to_char(l_from, 'YYYY-MM'), null,
                          (dbms_utility.get_time - l_t0) / 100, 'ERROR', sqlerrm);
      end if;
      raise;
  end archive_month;

  -- Same rules as DLM_PKG.purge_partition: outside RETENTION_MONTHS, and the
  -- retention may never be configured below MIN_RETENTION_MONTHS.
  procedure purge_month(p_month in date, p_run_id in number default null,
                        p_as_of in date default null) is
    l_from      date := trunc(p_month, 'MM');
    l_to        date := add_months(trunc(p_month, 'MM'), 1);
    l_as_of     date := nvl(trunc(p_as_of, 'MM'), dlm_pkg.as_of_month);
    l_retention pls_integer := to_number(dlm_pkg.get_param('RETENTION_MONTHS'));
    l_floor     pls_integer := to_number(dlm_pkg.get_param('MIN_RETENTION_MONTHS'));
    l_deleted   number := 0;
    l_t0        number := dbms_utility.get_time;
  begin
    if l_retention < l_floor then
      refuse(p_run_id, 'PURGE', l_from, 'configured retention is below the legal floor');
    end if;
    if l_from >= add_months(l_as_of, -l_retention) then
      refuse(p_run_id, 'PURGE', l_from, 'inside legal retention');
    end if;

    delete from billing_archive_base where bill_date >= l_from and bill_date < l_to;
    l_deleted := sql%rowcount;
    delete from billing_records_base where bill_date >= l_from and bill_date < l_to;
    l_deleted := l_deleted + sql%rowcount;
    commit;
    dlm_pkg.log_event(p_run_id, 'BASELINE', 'PURGE', to_char(l_from, 'YYYY-MM'), l_deleted,
                      (dbms_utility.get_time - l_t0) / 100, 'OK', 'delete');
  exception
    when others then
      rollback;
      if sqlcode <> -20010 then
        dlm_pkg.log_event(p_run_id, 'BASELINE', 'PURGE', to_char(l_from, 'YYYY-MM'), null,
                          (dbms_utility.get_time - l_t0) / 100, 'ERROR', sqlerrm);
      end if;
      raise;
  end purge_month;

  -- Only months that still hold rows are processed (index probe on bill_date).
  procedure run_lifecycle(p_as_of in date default null) is
    l_as_of      date := nvl(trunc(p_as_of, 'MM'), dlm_pkg.as_of_month);
    l_online_cut date := add_months(l_as_of, -to_number(dlm_pkg.get_param('ONLINE_MONTHS')));
    l_purge_cut  date := add_months(l_as_of, -to_number(dlm_pkg.get_param('RETENTION_MONTHS')));
    l_run_id     number := dlm_run_seq.nextval;
  begin
    for r in (select c.month_start from billing_control_totals c
              where c.month_start < l_purge_cut
              and  (exists (select 1 from billing_records_base b
                            where b.bill_date >= c.month_start
                            and   b.bill_date < add_months(c.month_start, 1))
                 or exists (select 1 from billing_archive_base a
                            where a.bill_date >= c.month_start
                            and   a.bill_date < add_months(c.month_start, 1)))
              order by c.month_start) loop
      purge_month(r.month_start, l_run_id, l_as_of);
    end loop;
    for r in (select c.month_start from billing_control_totals c
              where c.month_start >= l_purge_cut and c.month_start < l_online_cut
              and   exists (select 1 from billing_records_base b
                            where b.bill_date >= c.month_start
                            and   b.bill_date < add_months(c.month_start, 1))
              order by c.month_start) loop
      archive_month(r.month_start, l_run_id, l_as_of);
    end loop;
    dbms_stats.gather_table_stats(user, 'BILLING_RECORDS_BASE');
    dbms_stats.gather_table_stats(user, 'BILLING_ARCHIVE_BASE');
  end run_lifecycle;

end baseline_pkg;
/
show errors package body baseline_pkg
