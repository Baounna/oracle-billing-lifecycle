-- DEMO 5 - Run the monthly lifecycle job, then prove nothing was lost.
whenever sqlerror continue
set timing on
col action for a10
col message for a70

prompt === Guard: an operator tries to purge with a 24-month retention ===
exec dlm_pkg.purge_partition(date '2022-01-01', p_retention_months => 24)

prompt === Monthly job (2023-10 was archived in step 4): purge + warm + stats + validation ===
exec dlm_pkg.run_lifecycle

select action, status, count(*) operations, round(sum(elapsed_sec), 2) total_sec,
       sum(case when action <> 'VALIDATE' then rows_affected end) rows_processed
from   dlm_job_log
where  run_id = (select max(run_id) from dlm_job_log)
group  by action, status
order  by 1;

select message from dlm_job_log where action = 'VALIDATE' order by log_id desc fetch first 1 row only;

prompt === Archived history is still one query away (BILLING_ALL) ===
select count(*) disputed_2022_03
from   billing_all
where  bill_date >= date '2022-03-01' and bill_date < date '2022-04-01'
and    payment_status = 'DISPUTED';
