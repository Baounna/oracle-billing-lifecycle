-- =============================================================================
-- 01_generate_history.sql
-- Purpose : Load the billing history into the BASELINE table (client's current
--           design), build its indexes, gather statistics and capture the
--           integrity control totals.
-- Run as  : TELCO_OWNER
-- Params  : &data_start &data_months &rows_per_month &as_of
-- =============================================================================

prompt Generating &data_months months of billing history (~&rows_per_month rows/month)...
begin
  generate_history(p_table    => 'BILLING_RECORDS_BASE',
                   p_start    => date '&data_start',
                   p_months   => &data_months,
                   p_avg_rows => &rows_per_month,
                   p_as_of    => date '&as_of');
end;
/

prompt Building baseline indexes (typical OLTP design: PK + customer + date)...
create unique index billing_base_pk_ix on billing_records_base (record_id) tablespace telco_idx;
alter table billing_records_base add constraint billing_base_pk primary key (record_id)
  using index billing_base_pk_ix;
create index billing_base_cust_ix on billing_records_base (customer_id, bill_date) tablespace telco_idx;
create index billing_base_date_ix on billing_records_base (bill_date) tablespace telco_idx;

prompt Gathering statistics...
exec dbms_stats.gather_table_stats(user, 'BILLING_RECORDS_BASE')

prompt Capturing integrity control totals...
exec dlm_pkg.capture_control_totals('BILLING_RECORDS_BASE')

select count(*) months, sum(row_count) total_rows, min(month_start) first_month, max(month_start) last_month
from   billing_control_totals;
