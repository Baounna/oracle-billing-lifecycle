-- =============================================================================
-- 99_teardown.sql
-- Purpose : Remove every object created by the project (users + tablespaces).
--           Used to reset the lab and reproduce the whole run from scratch.
-- Run as  : SYSDBA inside ORCLPDB1 (scripts/reset.sh)
-- =============================================================================

begin
  -- DROP USER fails (ORA-01940) while a session is connected: lock the three
  -- project accounts (no reconnection), then end their sessions only.
  for u in (select username from dba_users
            where username in ('TELCO_OWNER', 'TELCO_APP', 'TELCO_ANALYST')) loop
    execute immediate 'alter user ' || u.username || ' account lock';
  end loop;
  for x in (select sid, serial# from v$session
            where username in ('TELCO_OWNER', 'TELCO_APP', 'TELCO_ANALYST')) loop
    execute immediate 'alter system kill session ''' || x.sid || ',' || x."SERIAL#" || ''' immediate';
    dbms_session.sleep(1);
  end loop;

  for u in (select username from dba_users
            where username in ('TELCO_OWNER', 'TELCO_APP', 'TELCO_ANALYST')) loop
    execute immediate 'drop user ' || u.username || ' cascade';
    dbms_output.put_line('Dropped user ' || u.username);
  end loop;

  for t in (select tablespace_name from dba_tablespaces
            where tablespace_name in ('TELCO_HOT', 'TELCO_IDX', 'TELCO_ARCH')) loop
    execute immediate 'drop tablespace ' || t.tablespace_name ||
                      ' including contents and datafiles cascade constraints';
    dbms_output.put_line('Dropped tablespace ' || t.tablespace_name);
  end loop;
end;
/
