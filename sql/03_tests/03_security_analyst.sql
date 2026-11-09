-- =============================================================================
-- 03_security_analyst.sql   (run as TELCO_ANALYST)
-- The analyst reads the full retained history through BILLING_ALL (online +
-- archive) but cannot modify anything. Fails if any check fails.
-- =============================================================================
declare
  g_pass number := 0;
  g_fail number := 0;

  procedure expect(p_name varchar2, p_stmt varchar2, p_code number) is
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
    if l_code = p_code then
      g_pass := g_pass + 1;
      dbms_output.put_line('PASS  ' || p_name || case when l_code <> 0 then '  (ORA' || l_code || ')' end);
    else
      g_fail := g_fail + 1;
      dbms_output.put_line('FAIL  ' || p_name || '  expected ' || p_code || ', got ' || l_code);
    end if;
  end;
begin
  expect('A01 read history through the unified view',
    'select count(*) from telco_owner.billing_all', 0);
  expect('A02 insert through the view rejected',
    'insert into telco_owner.billing_all (record_id) values (1)', -1031);
  expect('A03 delete through the view rejected',
    'delete from telco_owner.billing_all', -1031);
  expect('A04 direct access to the base tables rejected',
    'select count(*) from telco_owner.billing_records', -942);
  expect('A05 access to the application window rejected',
    'select count(*) from telco_owner.billing_current_v', -942);
  expect('A06 LOCK TABLE on the unified view rejected (READ grant: cannot block the lifecycle job)',
    'lock table telco_owner.billing_all in exclusive mode nowait', -1031);
  expect('A07 update through the view rejected',
    'update telco_owner.billing_all set amount = 0', -1031);
  expect('A08 direct read of the archive table rejected',
    'select count(*) from telco_owner.billing_archive', -942);
  expect('A09 read of the retention policy rejected',
    'select count(*) from telco_owner.dlm_config', -942);
  expect('A10 SELECT ... FOR UPDATE on reference data rejected (READ grant)',
    'select customer_id from telco_owner.customers where rownum = 1 for update', -1031);
  expect('A11 run a lifecycle job rejected',
    'begin telco_owner.dlm_pkg.run_lifecycle; end;', -6550);

  dbms_output.put_line('Security checks (TELCO_ANALYST) passed: ' || g_pass || '   failed: ' || g_fail);
  if g_fail > 0 then
    raise_application_error(-20099, g_fail || ' security check(s) failed');
  end if;
end;
/
