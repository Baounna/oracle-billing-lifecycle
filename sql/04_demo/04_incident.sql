-- DEMO 4 - Incident: the archive job crashes in the middle of archiving 2023-10.
whenever sqlerror continue
set timing on
col message for a90
col target for a12

prompt === Rows of 2023-10 before the incident ===
select count(*) rows_2023_10 from billing_records partition for (date '2023-10-01');

prompt === Archive job crashes right after step 1 (exchange out) ===
exec dlm_pkg.archive_partition(date '2023-10-01', p_simulate_failure => 'AFTER_STEP1')

prompt === Where is the data? Not lost: it waits in BILLING_XCHG ===
select count(*) rows_in_exchange_table from billing_xchg;

-- range = archive + month being archived: 2021-10 (first retained month after
-- step 0) .. 2023-10; months before 2021-10 must be purged
prompt === Integrity check (2021-10 .. 2023-10) detects the incomplete month ===
select dlm_pkg.validate_integrity('BILLING_ALL', date '2021-10-01', null, date '2023-11-01') months_in_error from dual;

prompt === Recovery: simply re-run the job ===
exec dlm_pkg.archive_partition(date '2023-10-01')

select count(*) rows_archived from billing_archive partition for (date '2023-10-01');
select count(*) rows_in_exchange_table from billing_xchg;
select dlm_pkg.validate_integrity('BILLING_ALL', date '2021-10-01', null, date '2023-11-01') months_in_error from dual;

prompt === Audit trail ===
select action, target, status, message
from   dlm_job_log
where  action in ('ARCHIVE', 'VALIDATE')
order  by log_id desc fetch first 5 rows only;
