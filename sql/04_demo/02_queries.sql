-- DEMO 2 - Business scenario: finance asks for last month's revenue by service.
-- Same query on the current design (heap) and on the partitioned design.
-- Literal dates so that the plan shows WHICH partition is read (Pstart/Pstop).
set timing on
-- serveroutput off: otherwise DISPLAY_CURSOR shows the DBMS_OUTPUT call, not the query
set serveroutput off
col service_type for a10

prompt === Baseline: one big heap table ===
select service_type, count(*) records, sum(amount) revenue
from   billing_records_base
where  bill_date >= date '2026-10-01' and bill_date < date '2026-11-01'
group  by service_type;
select plan_table_output from table(dbms_xplan.display_cursor(format => 'BASIC +ROWS +PARTITION'));

prompt === Partitioned: partition pruning reads only October 2026 ===
select service_type, count(*) records, sum(amount) revenue
from   billing_records
where  bill_date >= date '2026-10-01' and bill_date < date '2026-11-01'
group  by service_type;
select plan_table_output from table(dbms_xplan.display_cursor(format => 'BASIC +ROWS +PARTITION'));

prompt === PARTITION RANGE SINGLE: one partition read. For interval partitioning ===
prompt === Pstart/Pstop is the interval number counted from P_INITIAL           ===
prompt === (month 73 since 2020-10), not the current position: it is            ===
col partition_name for a12
select partition_name, num_rows, tablespace_name
from   user_tab_partitions
where  table_name = 'BILLING_RECORDS' and partition_name = 'P_202610';
