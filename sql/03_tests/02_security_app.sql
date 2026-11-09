-- =============================================================================
-- 02_security_app.sql   (run as TELCO_APP)
-- Least-privilege checks: the billing application may insert and read billing
-- records of the HOT window only (through BILLING_CURRENT_V); it cannot write
-- into old months, delete history, change retention or run DDL.
-- Each check asserts the expected outcome; the script fails if any check fails.
-- =============================================================================
declare
  g_pass number := 0;
  g_fail number := 0;

  -- p_alt: second acceptable code (a row aimed at a read-only partition is
  -- rejected with ORA-14466 before the view's check option, ORA-01402)
  procedure expect(p_name varchar2, p_stmt varchar2, p_code number, p_alt number default null) is
    l_code number := 0;
    l_rows number;
  begin
    begin
      if upper(ltrim(p_stmt)) like 'SELECT%' then
        execute immediate p_stmt into l_rows;      -- really execute and fetch
        if l_rows = 0 then l_code := 100; end if;  -- positive check must see data
      else
        execute immediate p_stmt;
      end if;
    exception
      when others then l_code := sqlcode;
    end;
    rollback;
    if l_code = p_code or l_code = p_alt then
      g_pass := g_pass + 1;
      dbms_output.put_line('PASS  ' || p_name || case when l_code <> 0 then '  (ORA' || l_code || ')' end);
    else
      g_fail := g_fail + 1;
      dbms_output.put_line('FAIL  ' || p_name || '  expected ' || p_code || ', got ' || l_code);
    end if;
  end;
begin
  expect('S01 read current billing data through the write window',
    'select count(*) from telco_owner.billing_current_v where bill_date >= date ''2026-10-01''', 0);
  expect('S02 insert a bill in a HOT month (rolled back)',
    'insert into telco_owner.billing_current_v values (999000000001, 202610000001, 1, 1,
       date ''2026-10-05'', ''SMS'', ''CAS'', null, null, 0.35, 0.07, ''UNPAID'')', 0);
  expect('S03 late insert dated in an archived month (2022-03) rejected',
    'insert into telco_owner.billing_current_v values (999000000002, 202203000001, 1, 1,
       date ''2022-03-10'', ''SMS'', ''CAS'', null, null, 0.35, 0.07, ''PAID'')', -1402);
  expect('S04 far-future insert (2030-01) rejected',
    'insert into telco_owner.billing_current_v values (999000000003, 203001000001, 1, 1,
       date ''2030-01-10'', ''SMS'', ''CAS'', null, null, 0.35, 0.07, ''UNPAID'')', -1402);
  expect('S05 direct write into the base table rejected',
    'insert into telco_owner.billing_records values (999000000004, 202203000001, 1, 1,
       date ''2022-03-10'', ''SMS'', ''CAS'', null, null, 0.35, 0.07, ''PAID'')', -942);
  expect('S06 delete billing records rejected',
    'delete from telco_owner.billing_current_v where bill_date < date ''2026-01-01''', -1031);
  expect('S07 update billing records rejected',
    'update telco_owner.billing_current_v set amount = 0', -1031);
  expect('S08 read archive table directly rejected',
    'select count(*) from telco_owner.billing_archive', -942);
  expect('S09 change retention policy rejected',
    'update telco_owner.dlm_config set param_value = ''1'' where param_name = ''RETENTION_MONTHS''', -942);
  expect('S10 run a lifecycle job rejected',
    'begin telco_owner.dlm_pkg.purge_partition(date ''2025-01-01''); end;', -6550);
  expect('S11 DDL rejected',
    'create table hack (x number)', -1031);
  expect('S12 insert in the first non-HOT month (2025-10, window boundary) rejected',
    'insert into telco_owner.billing_current_v values (999000000006, 202510000001, 1, 1,
       date ''2025-10-31'', ''SMS'', ''CAS'', null, null, 0.35, 0.07, ''PAID'')', -1402, -14466);
  expect('S13 insert just after the window (2027-01) rejected',
    'insert into telco_owner.billing_current_v values (999000000007, 202701000001, 1, 1,
       date ''2027-01-01'', ''SMS'', ''CAS'', null, null, 0.35, 0.07, ''UNPAID'')', -1402);
  expect('S14 lock of reference data rejected (READ grant)',
    'lock table telco_owner.customers in exclusive mode nowait', -1031);

  dbms_output.put_line('Security checks (TELCO_APP) passed: ' || g_pass || '   failed: ' || g_fail);
  if g_fail > 0 then
    raise_application_error(-20099, g_fail || ' security check(s) failed');
  end if;
end;
/
