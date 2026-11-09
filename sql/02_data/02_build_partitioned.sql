-- =============================================================================
-- 02_build_partitioned.sql
-- Purpose : Migrate the same history into the partitioned design
--           (one direct-path load; INTERVAL creates the monthly partitions).
-- Run as  : TELCO_OWNER
-- =============================================================================

prompt Loading BILLING_RECORDS (partitioned) from the baseline table...
insert /*+ append */ into billing_records select * from billing_records_base;
commit;

prompt Renaming system-generated partitions to P_YYYYMM...
exec dlm_pkg.rename_partitions('BILLING_RECORDS')

prompt Building indexes...
-- Global unique index: record_id lookups stay a single index probe.
create unique index billing_pk_ix on billing_records (record_id) tablespace telco_idx;
alter table billing_records add constraint billing_records_pk primary key (record_id)
  using index billing_pk_ix;
-- Local index: one small index segment per month, maintained per partition.
-- No separate BILL_DATE index: partition pruning replaces it.
create index billing_cust_lix on billing_records (customer_id, bill_date) local tablespace telco_idx;

prompt Gathering incremental statistics...
exec dbms_stats.gather_table_stats(user, 'BILLING_RECORDS')

prompt Integrity check: partitioned table vs control totals...
declare
  l_bad number;
begin
  l_bad := dlm_pkg.validate_integrity('BILLING_RECORDS', date '1900-01-01');
  dbms_output.put_line('Months in error: ' || l_bad);
  if l_bad > 0 then
    raise_application_error(-20040, 'Partitioned copy does not match control totals');
  end if;
end;
/

select count(*) partitions, sum(num_rows) total_rows
from   user_tab_partitions
where  table_name = 'BILLING_RECORDS';
