-- =============================================================================
-- 02_users.sql
-- Purpose : Create the project accounts following the least-privilege principle.
-- Run as  : SYSDBA inside ORCLPDB1 (scripts/01_setup_db.sh)
-- Params  : &owner_pw &app_pw &analyst_pw   (injected from .env, never stored)
--
--   TELCO_OWNER    schema owner: tables, partitions, lifecycle packages
--   TELCO_APP      billing application: insert/read current billing data only
--   TELCO_ANALYST  reporting: read-only access through views
--
-- Passwords appear only in CREATE USER / ALTER USER statements, which Oracle
-- does not keep in clear text in the shared pool (V$SQL). They are never put
-- inside a PL/SQL block, whose literals would remain readable in V$SQL.
-- =============================================================================

-- Idempotent without ever failing (SQL*Plus echoes a failing line - password
-- included - so nothing here may fail): missing users are created WITHOUT a
-- password (NO AUTHENTICATION, no secret in the PL/SQL block), then a plain
-- ALTER USER sets the password from .env and unlocks the account.
begin
  for u in (select column_value username
            from   table(sys.odcivarchar2list('TELCO_OWNER', 'TELCO_APP', 'TELCO_ANALYST'))
            where  column_value not in (select username from dba_users)) loop
    execute immediate 'create user ' || u.username || ' no authentication';
    dbms_output.put_line('Created user ' || u.username);
  end loop;
end;
/

alter user telco_owner   identified by "&owner_pw"   account unlock;
alter user telco_app     identified by "&app_pw"     account unlock;
alter user telco_analyst identified by "&analyst_pw" account unlock;

-- ---- Schema owner -----------------------------------------------------------
alter user telco_owner
  default tablespace telco_hot
  temporary tablespace temp
  quota unlimited on telco_hot
  quota unlimited on telco_idx
  quota unlimited on telco_arch;

grant create session, create table, create view, create procedure, create sequence to telco_owner;

-- Read-only access to the session-level performance views used by the
-- benchmark harness (v$mystat deltas, execution plans via DBMS_XPLAN).
-- These views are part of the base product (no Diagnostics Pack needed).
grant select on sys.v_$mystat                  to telco_owner;
grant select on sys.v_$statname                to telco_owner;
grant select on sys.v_$session                 to telco_owner;
grant select on sys.v_$sql                     to telco_owner;
grant select on sys.v_$sql_plan                to telco_owner;
grant select on sys.v_$sql_plan_statistics_all to telco_owner;

-- ---- Application and analyst accounts: no quota, no DDL ----------------------
alter user telco_app     default tablespace users temporary tablespace temp;
alter user telco_analyst default tablespace users temporary tablespace temp;
grant create session to telco_app;
grant create session to telco_analyst;
-- Object-level grants are issued by TELCO_OWNER (sql/01_schema/07_grants.sql).

select username, account_status, default_tablespace
from   dba_users
where  username like 'TELCO%'
order  by username;
