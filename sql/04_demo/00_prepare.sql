-- DEMO 0 - Run once BEFORE the defense (~4 min on the full dataset).
-- Applies the policy as it stood last month (as of 2026-10), so that the live demo
-- shows the routine monthly job (dry run in step 3: 1 purge + 1 warm + 1 archive;
-- step 4 archives 2023-10 during the incident, so step 5 runs the purge and warm).
exec dlm_pkg.run_lifecycle(p_as_of => date '2026-10-01')
select message from dlm_job_log where action = 'VALIDATE' order by log_id desc fetch first 1 row only;
