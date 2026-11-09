-- =============================================================================
-- 07_grants.sql
-- Purpose : Object privileges for the application and analyst accounts
--           (least privilege: no DDL, no access to staging or lifecycle code).
-- Run as  : TELCO_OWNER
-- =============================================================================

-- Application write window: BILLING_CURRENT_V exposes only the HOT months and
-- rejects (ORA-01402) any row outside them. Without it, a late row dated in an
-- archived month would be stored online again. (Oracle still creates the empty
-- interval partition for a rejected row; run_lifecycle drops such partitions.)
-- The window moves forward at every lifecycle run.
exec dlm_pkg.refresh_app_window

-- READ (not SELECT) wherever only reading is needed: READ does not allow
-- LOCK TABLE or SELECT ... FOR UPDATE, so a read-only account cannot block the
-- lifecycle job by locking the tables (tested: A06, A10).

-- Billing application: writes and reads current billing records only.
-- (INSERT also lets the application lock BILLING_CURRENT_V; it is a trusted
-- service account, and lifecycle DDL waits up to 60 s for its transactions.)
grant read, insert on billing_current_v to telco_app;
grant read on customers    to telco_app;
grant read on tariff_plans to telco_app;

-- Analysts: read-only, through the unified view (online + archive).
grant read on billing_all  to telco_analyst;
grant read on customers    to telco_analyst;
grant read on tariff_plans to telco_analyst;

-- Nobody but the owner can touch base tables, run lifecycle operations or
-- change the retention policy.
select grantee, table_name, privilege
from   user_tab_privs_made
order  by grantee, table_name, privilege;
