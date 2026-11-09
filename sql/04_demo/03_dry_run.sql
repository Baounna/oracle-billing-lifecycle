-- DEMO 3 - What would the monthly lifecycle job do? (dry run, changes nothing)
exec dlm_pkg.run_lifecycle(p_dry_run => true)

col action for a8
select action, count(*) months, min(target) first_month, max(target) last_month
from   dlm_job_log
where  run_id = (select max(run_id) from dlm_job_log) and status = 'PLANNED'
group  by action
order  by decode(action, 'PURGE', 1, 'WARM', 2, 3);
