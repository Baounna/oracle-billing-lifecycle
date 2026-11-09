-- =============================================================================
-- 01_dlm_infrastructure.sql
-- Purpose : Configuration, audit log and integrity control tables used by the
--           data lifecycle management (DLM) mechanisms.
-- Run as  : TELCO_OWNER
-- Params  : &as_of_month (YYYY-MM)
-- =============================================================================

-- Retention policy is data, not code: operators change it without redeploying.
create table dlm_config (
  param_name   varchar2(30)  constraint dlm_config_pk primary key,
  param_value  varchar2(100) not null,
  description  varchar2(200)
) tablespace telco_hot;

insert into dlm_config values ('AS_OF_MONTH', '&as_of_month',
  'Reference month (YYYY-MM) treated as "today" by lifecycle jobs (reproducible runs)');
insert into dlm_config values ('HOT_MONTHS', '12',
  'Months kept uncompressed and read/write in TELCO_HOT');
insert into dlm_config values ('ONLINE_MONTHS', '36',
  'Months kept in BILLING_RECORDS (hot + warm); older months move to BILLING_ARCHIVE');
insert into dlm_config values ('RETENTION_MONTHS', '60',
  'Legal retention of billing data; older months are purged');
insert into dlm_config values ('MIN_RETENTION_MONTHS', '60',
  'Safety floor: purge refuses any retention shorter than this value');
commit;

create sequence dlm_run_seq;

-- Every lifecycle operation (OK, SKIPPED, REFUSED, ERROR) is logged here.
create table dlm_job_log (
  log_id         number generated always as identity constraint dlm_job_log_pk primary key,
  run_id         number,
  logged_at      timestamp default systimestamp not null,
  job_name       varchar2(30)  not null,
  action         varchar2(30)  not null,
  target         varchar2(60),
  rows_affected  number,
  elapsed_sec    number(10,3),
  status         varchar2(10)  not null
                 constraint dlm_job_log_status_ck
                 check (status in ('OK', 'SKIPPED', 'REFUSED', 'ERROR', 'PLANNED', 'RESUMED')),
  message        varchar2(4000)
) tablespace telco_hot;

-- Control totals captured at load time = the reference used to prove that
-- partitioning, compression, archiving and purging never alter billing data.
create table billing_control_totals (
  month_start  date   constraint billing_control_totals_pk primary key,
  row_count    number not null,
  sum_amount   number not null,
  hash_sum     number not null,
  captured_at  timestamp default systimestamp not null
) tablespace telco_hot;
