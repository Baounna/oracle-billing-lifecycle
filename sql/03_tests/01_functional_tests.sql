-- =============================================================================
-- 01_functional_tests.sql
-- Purpose : Automated functional tests of the lifecycle mechanisms.
--           Prints PASS/FAIL per test and fails (exit code <> 0) if any test fails.
--           Destructive: run on a freshly loaded dataset (scripts/04_run_tests.sh).
-- Run as  : TELCO_OWNER
--
-- Policy under test (AS_OF_MONTH = 2026-11, data 2020-11 .. 2026-10):
--   hot     2025-11 .. 2026-10  (12 months)
--   warm    2023-11 .. 2025-10  (24 months, stays in BILLING_RECORDS)
--   archive 2021-11 .. 2023-10  (24 months, moves to BILLING_ARCHIVE)
--   purge   2020-11 .. 2021-10  (12 months)
-- =============================================================================

create or replace package test_util authid definer as
  g_pass number := 0;
  g_fail number := 0;
  procedure check_that(p_name varchar2, p_ok boolean, p_detail varchar2 default null);
  procedure expect_error(p_name varchar2, p_plsql varchar2, p_code number);
  function  n(p_sql varchar2) return number;
  procedure summary;
end test_util;
/
create or replace package body test_util as
  procedure check_that(p_name varchar2, p_ok boolean, p_detail varchar2 default null) is
  begin
    if p_ok then
      g_pass := g_pass + 1;
      dbms_output.put_line('PASS  ' || p_name || case when p_detail is not null then '  (' || p_detail || ')' end);
    else
      g_fail := g_fail + 1;
      dbms_output.put_line('FAIL  ' || p_name || case when p_detail is not null then '  (' || p_detail || ')' end);
    end if;
  end;

  procedure expect_error(p_name varchar2, p_plsql varchar2, p_code number) is
  begin
    execute immediate 'begin ' || p_plsql || '; end;';
    check_that(p_name, false, 'expected ORA' || p_code || ' but the call succeeded');
  exception
    when others then
      check_that(p_name, sqlcode = p_code, 'got ' || substr(sqlerrm, 1, 150));
  end;

  function n(p_sql varchar2) return number is
    l number;
  begin
    execute immediate p_sql into l;
    return l;
  end;

  procedure summary is
  begin
    dbms_output.put_line('----------------------------------------------');
    dbms_output.put_line('Tests passed: ' || g_pass || '   failed: ' || g_fail);
    if g_fail > 0 then
      raise_application_error(-20099, g_fail || ' test(s) failed');
    end if;
  end;
end test_util;
/

declare
  l_rows     number;
  l_before   number;
  l_run      number;
  l_parts    number;
  l_log0     number;
begin
  -- ---------------------------------------------------------------- precondition
  -- The expected counts below assume the default calendar of .env.example
  -- (DATA_START_MONTH=2020-11, DATA_MONTHS=72, AS_OF_MONTH=2026-11) and the
  -- default policy (12 / 36 / 60). Dataset scale (rows, customers) is free.
  if dlm_pkg.get_param('AS_OF_MONTH') <> '2026-11'
     or test_util.n('select count(*) from billing_control_totals') <> 72
     or test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_RECORDS''') <> 73
     or test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_ARCHIVE''') <> 1
     or test_util.n('select count(*) from dlm_job_log
                     where action in (''RUN_START'', ''WARM'', ''ARCHIVE'', ''PURGE'')') > 0
     or test_util.n('select count(*) from billing_control_totals where month_start = date ''2020-11-01''') <> 1
     or test_util.n('select sum(row_count) from billing_control_totals') > 2000000
     or dlm_pkg.get_param('HOT_MONTHS') || '/' || dlm_pkg.get_param('ONLINE_MONTHS') || '/'
        || dlm_pkg.get_param('RETENTION_MONTHS') <> '12/36/60' then
    raise_application_error(-20098, 'Tests need the default calendar and policy '
      || '(2020-11 + 72 months, as of 2026-11, 12/36/60) on a freshly loaded SMOKE dataset '
      || '(<= 2 M rows: the tests are destructive and must not run on the benchmark data)');
  end if;

  l_log0 := test_util.n('select nvl(max(log_id), 0) from dlm_job_log');

  -- ---------------------------------------------------------------- baseline
  test_util.check_that('T01 partitioned copy matches control totals',
    dlm_pkg.validate_integrity('BILLING_RECORDS', date '1900-01-01') = 0);

  test_util.check_that('T02 one partition per month (72 + P_INITIAL)',
    test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_RECORDS''') = 73);

  -- ---------------------------------------------------------------- dry run
  dlm_pkg.run_lifecycle(p_dry_run => true);
  l_run := test_util.n('select max(run_id) from dlm_job_log');
  test_util.check_that('T03 dry run plans 12 purges',
    test_util.n('select count(*) from dlm_job_log where run_id = ' || l_run ||
                ' and action = ''PURGE'' and status = ''PLANNED''') = 12);
  test_util.check_that('T04 dry run plans 48 warm moves',
    test_util.n('select count(*) from dlm_job_log where run_id = ' || l_run ||
                ' and action = ''WARM'' and status = ''PLANNED''') = 48);
  test_util.check_that('T05 dry run plans 24 archives',
    test_util.n('select count(*) from dlm_job_log where run_id = ' || l_run ||
                ' and action = ''ARCHIVE'' and status = ''PLANNED''') = 24);
  test_util.check_that('T06 dry run changes nothing (partitions, tablespaces, compression, read-only)',
    test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_RECORDS''') = 73
    and test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_RECORDS''
                     and (tablespace_name <> ''TELCO_HOT'' or compression = ''ENABLED'' or read_only = ''YES'')') = 0
    and test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_ARCHIVE''') = 1);

  -- ---------------------------------------------------------------- guards
  test_util.expect_error('T07 purge refused when retention < legal floor (24 < 60)',
    'dlm_pkg.purge_partition(date ''2020-11-01'', p_retention_months => 24)', -20010);
  test_util.expect_error('T08 purge refused for a month inside retention (2023-01)',
    'dlm_pkg.purge_partition(date ''2023-01-01'')', -20010);
  test_util.expect_error('T09 archive refused inside the 36-month online window (2024-06)',
    'dlm_pkg.archive_partition(date ''2024-06-01'')', -20010);
  test_util.expect_error('T10 warm refused for a HOT month (2026-09)',
    'dlm_pkg.warm_partition(date ''2026-09-01'')', -20010);
  -- exact boundaries (first month that must still be protected)
  test_util.expect_error('T37 purge refused at the retention boundary (2021-11)',
    'dlm_pkg.purge_partition(date ''2021-11-01'')', -20010);
  test_util.expect_error('T38 archive refused at the online-window boundary (2023-11)',
    'dlm_pkg.archive_partition(date ''2023-11-01'')', -20010);
  test_util.expect_error('T39 warm refused at the HOT-window boundary (2025-11)',
    'dlm_pkg.warm_partition(date ''2025-11-01'')', -20010);
  test_util.check_that('T11 refusals are logged',
    test_util.n('select count(*) from dlm_job_log where status = ''REFUSED'' and log_id > ' || l_log0) = 7);

  -- ---------------------------------------------------------------- incident
  -- Archive job crashes after moving the month out of BILLING_RECORDS.
  l_before := test_util.n('select count(*) from billing_records partition for (date ''2021-11-01'')');
  test_util.expect_error('T12 simulated crash after exchange step 1',
    'dlm_pkg.archive_partition(date ''2021-11-01'', p_simulate_failure => ''AFTER_STEP1'')', -20020);
  test_util.check_that('T13 no row lost during the crash: rows wait in BILLING_XCHG',
    test_util.n('select count(*) from billing_xchg') = l_before,
    l_before || ' rows staged');
  test_util.check_that('T14 integrity check detects the incomplete month',
    dlm_pkg.validate_integrity('BILLING_ALL', date '1900-01-01') > 0);

  dlm_pkg.archive_partition(date '2021-11-01');      -- re-run = recovery
  test_util.check_that('T15 re-run resumes and completes the archive',
    test_util.n('select count(*) from billing_archive partition for (date ''2021-11-01'')') = l_before
    and test_util.n('select count(*) from billing_xchg') = 0);
  test_util.check_that('T16 resume is logged as RESUMED',
    test_util.n('select count(*) from dlm_job_log where action = ''ARCHIVE'' and status = ''RESUMED''
                 and log_id > ' || l_log0) = 1);
  test_util.check_that('T17 integrity restored after recovery',
    dlm_pkg.validate_integrity('BILLING_ALL', date '1900-01-01') = 0);

  -- ---------------------------------------------------------------- warm robustness
  -- System-named partition: table and index partition names differ, so the
  -- local index must be found by position, not by name.
  execute immediate 'alter table billing_records rename partition P_202401 to SYS_P_TEST01';
  dlm_pkg.warm_partition(date '2024-01-01');
  test_util.check_that('T34 warm of a system-named partition rebuilds its local index (by position)',
    test_util.n('select count(*) from user_tab_partitions tp
                 join user_ind_partitions ip on ip.index_name = ''BILLING_CUST_LIX''
                                            and ip.partition_position = tp.partition_position
                 where tp.table_name = ''BILLING_RECORDS'' and tp.partition_name = ''SYS_P_TEST01''
                 and ip.status = ''USABLE'' and ip.tablespace_name = ''TELCO_ARCH''
                 and tp.read_only = ''YES''') = 1);

  -- Warm interrupted after the MOVE (index unusable, partition still R/W).
  execute immediate 'alter table billing_records move partition P_202402 tablespace telco_arch
                     row store compress basic update global indexes';
  dlm_pkg.warm_partition(date '2024-02-01');
  test_util.check_that('T35 re-running an interrupted warm completes it (index rebuilt, read only)',
    test_util.n('select count(*) from user_ind_partitions
                 where index_name = ''BILLING_CUST_LIX'' and partition_name = ''P_202402''
                 and status = ''USABLE'' and tablespace_name = ''TELCO_ARCH''') = 1
    and test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_RECORDS''
                     and partition_name = ''P_202402'' and read_only = ''YES''') = 1
    and test_util.n('select count(*) from dlm_job_log where action = ''WARM''
                     and message like ''completed an interrupted warm%'' and log_id > ' || l_log0) = 1);

  -- ---------------------------------------------------------------- full run
  dlm_pkg.run_lifecycle;
  test_util.check_that('T18 lifecycle run: 36 online months remain',
    test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_RECORDS'' and partition_name <> ''P_INITIAL''') = 36);
  test_util.check_that('T19 lifecycle run: 24 archived months',
    test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_ARCHIVE'' and partition_name <> ''P_INITIAL''') = 24);
  test_util.check_that('T20 warm months are compressed, read-only, in TELCO_ARCH',
    test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_RECORDS''
                 and tablespace_name = ''TELCO_ARCH'' and compression = ''ENABLED'' and read_only = ''YES''') = 24);
  test_util.check_that('T21 hot months untouched (TELCO_HOT, read/write)',
    test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_RECORDS''
                 and tablespace_name = ''TELCO_HOT'' and read_only = ''NO'' and partition_name <> ''P_INITIAL''') = 12);
  test_util.check_that('T22 no data older than retention remains',
    test_util.n('select count(*) from billing_all where bill_date < date ''2021-11-01''') = 0);
  test_util.check_that('T23 integrity of all retained months (billing_all vs control totals)',
    dlm_pkg.validate_integrity('BILLING_ALL') = 0);
  test_util.check_that('T24 all indexes usable after lifecycle',
    test_util.n('select count(*) from user_indexes where status not in (''VALID'', ''N/A'')') = 0
    and test_util.n('select count(*) from user_ind_partitions where status <> ''USABLE''') = 0);

  test_util.check_that('T42 every archive partition is compressed, read-only, in TELCO_ARCH',
    test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_ARCHIVE''
                 and partition_name <> ''P_INITIAL'' and tablespace_name = ''TELCO_ARCH''
                 and compression = ''ENABLED'' and read_only = ''YES''') = 24);

  -- ---------------------------------------------------------------- idempotence
  l_parts := test_util.n('select count(*) from user_tab_partitions');
  dlm_pkg.run_lifecycle;
  l_run := test_util.n('select max(run_id) from dlm_job_log');
  test_util.check_that('T25 second run is a no-op (idempotent: no operation performed)',
    test_util.n('select count(*) from user_tab_partitions') = l_parts
    and test_util.n('select count(*) from dlm_job_log where run_id = ' || l_run ||
                    ' and action in (''WARM'', ''ARCHIVE'', ''PURGE'', ''DROP_EMPTY'') and status = ''OK''') = 0
    and dlm_pkg.validate_integrity('BILLING_ALL') = 0);

  -- ---------------------------------------------------------------- read-only protection
  test_util.expect_error('T26 archived data cannot be modified (read-only partition)',
    'update billing_archive set amount = 0 where bill_date >= date ''2022-01-01'' and bill_date < date ''2022-02-01''',
    -14466);

  -- ---------------------------------------------------------------- app write window
  test_util.expect_error('T27 late row in an archived month rejected by the write window',
    'insert into billing_current_v values (999000000002, 202203000001, 1, 1, date ''2022-03-10'',
       ''SMS'', ''CAS'', null, null, 0.35, 0.07, ''PAID'')', -1402);
  test_util.expect_error('T28 far-future row (2030-01) rejected by the write window',
    'insert into billing_current_v values (999000000003, 203001000001, 1, 1, date ''2030-01-10'',
       ''SMS'', ''CAS'', null, null, 0.35, 0.07, ''UNPAID'')', -1402);
  -- Oracle behaviour found during testing: a rejected insert still creates the
  -- interval partition (partition creation is autonomous), but no row enters it.
  -- The next lifecycle run removes such empty partitions (T31).
  test_util.check_that('T29 rejected rows left only EMPTY stray partitions (2022-03, 2030-01)',
    dlm_pkg.partition_for('BILLING_RECORDS', date '2022-03-01') is not null
    and dlm_pkg.partition_for('BILLING_RECORDS', date '2030-01-01') is not null
    and test_util.n('select count(*) from billing_records
                     where (bill_date >= date ''2022-03-01'' and bill_date < date ''2022-04-01'')
                        or bill_date >= date ''2030-01-01''') = 0);
  execute immediate 'insert into billing_current_v values (999000000001, 202610000001, 1, 1,
       date ''2026-10-05'', ''SMS'', ''CAS'', null, null, 0.35, 0.07, ''UNPAID'')';
  test_util.check_that('T30 insert in a HOT month accepted by the write window', sql%rowcount = 1);
  rollback;

  dlm_pkg.run_lifecycle;
  test_util.check_that('T31 next lifecycle run removes the empty stray partitions, archive intact',
    dlm_pkg.partition_for('BILLING_RECORDS', date '2022-03-01') is null
    and dlm_pkg.partition_for('BILLING_RECORDS', date '2030-01-01') is null
    and test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_RECORDS''
                     and partition_name <> ''P_INITIAL''') = 36
    and dlm_pkg.validate_integrity('BILLING_ALL') = 0);

  -- ---------------------------------------------------------------- live HOT data
  -- Normal business: the application commits new bills in HOT months. The
  -- monthly job must still succeed (only frozen months are validated).
  -- 2025-11 is HOT now and becomes WARM in T36 (as of 2026-12): the row must be
  -- included in the totals re-captured when the month is frozen.
  execute immediate 'insert into billing_current_v values (999000000005, 202511000005, 5, 1,
       date ''2025-11-20'', ''DATA'', ''RAB'', null, 120, 1.80, 0.36, ''UNPAID'')';
  commit;
  begin
    dlm_pkg.run_lifecycle;
    test_util.check_that('T32 lifecycle succeeds after the application committed new HOT rows', true);
  exception
    when others then
      test_util.check_that('T32 lifecycle succeeds after the application committed new HOT rows',
                           false, sqlerrm);
  end;

  -- ---------------------------------------------------------------- p_as_of
  -- Run as of the NEXT month: every operation must use that reference month.
  -- Before it, an archive of the newly eligible month (2023-11) crashes: the
  -- monthly job itself must resume it (step 0a).
  test_util.expect_error('T41a archive of 2023-11 crashes after step 1',
    'dlm_pkg.archive_partition(date ''2023-11-01'', p_simulate_failure => ''AFTER_STEP1'',
                               p_as_of => date ''2026-12-01'')', -20020);
  begin
    dlm_pkg.run_lifecycle(p_as_of => date '2026-12-01');
    test_util.check_that('T41 run_lifecycle resumes the crashed archive (step 0a)',
      test_util.n('select count(*) from billing_xchg') = 0
      and test_util.n('select count(*) from billing_archive partition for (date ''2023-11-01'')') > 0
      and test_util.n('select count(*) from dlm_job_log where status = ''RESUMED''
                       and target = ''2023-11'' and log_id > ' || l_log0) = 1);
    test_util.check_that('T36 run_lifecycle(p_as_of => 2026-12) applies the policy one month later',
      test_util.n('select count(*) from user_tab_partitions where table_name = ''BILLING_RECORDS''
                   and tablespace_name = ''TELCO_HOT'' and partition_name <> ''P_INITIAL''') = 11
      and dlm_pkg.partition_for('BILLING_RECORDS', date '2023-11-01') is null
      and dlm_pkg.partition_for('BILLING_ARCHIVE', date '2021-11-01') is null);
  exception
    when others then
      test_util.check_that('T36 run_lifecycle(p_as_of => 2026-12) applies the policy one month later',
                           false, sqlerrm);
  end;

  -- ---------------------------------------------------------------- integrity gate
  -- Corrupt one archived (frozen) month on purpose: the monthly job must stop.
  execute immediate 'alter table billing_archive modify partition for (date ''2022-06-01'') read write';
  execute immediate 'update billing_archive partition for (date ''2022-06-01'')
                     set amount = amount + 1
                     where record_id = (select min(record_id)
                                        from billing_archive partition for (date ''2022-06-01''))';
  commit;
  execute immediate 'alter table billing_archive modify partition for (date ''2022-06-01'') read only';
  test_util.expect_error('T40 lifecycle stops (ORA-20040) when a frozen month was altered',
    'dlm_pkg.run_lifecycle(p_as_of => date ''2026-12-01'')', -20040);
  execute immediate 'alter table billing_archive modify partition for (date ''2022-06-01'') read write';
  execute immediate 'update billing_archive partition for (date ''2022-06-01'')
                     set amount = amount - 1
                     where record_id = (select min(record_id)
                                        from billing_archive partition for (date ''2022-06-01''))';
  commit;
  execute immediate 'alter table billing_archive modify partition for (date ''2022-06-01'') read only';

  -- ---------------------------------------------------------------- baseline
  baseline_pkg.run_lifecycle;
  -- (2025-11 excluded: its totals now include the application row of T32,
  --  which only exists in the partitioned design)
  test_util.check_that('T33 baseline lifecycle archives 24 months and keeps every retained row',
    dlm_pkg.validate_integrity('BILLING_ALL_BASE', p_to_month => date '2025-11-01') = 0
    and test_util.n('select count(distinct trunc(bill_date, ''MM'')) from billing_archive_base') = 24
    and test_util.n('select count(*) from billing_records_base where bill_date < date ''2023-11-01''') = 0);

  -- leave the application window as the configured month defines it (the
  -- security tests that follow expect AS_OF_MONTH = 2026-11)
  dlm_pkg.refresh_app_window;

  test_util.summary;
end;
/

drop package test_util;

select status, count(*) from dlm_job_log group by status order by status;
