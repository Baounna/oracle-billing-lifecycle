-- DEMO 1 - Current state: retention policy and where each month lives.
prompt === Retention policy (DLM_CONFIG) ===
col param_name for a22
col param_value for a10
col description for a80
select param_name, param_value, description from dlm_config order by param_name;

prompt === BILLING_RECORDS partitions by tier ===
col tier for a8
col tablespace_name for a12
col compression for a8
col first_part for a10
col last_part for a10
select case when read_only = 'YES' then 'WARM' else 'HOT' end tier,
       tablespace_name, compression, count(*) partitions,
       min(partition_name) first_part, max(partition_name) last_part,
       sum(num_rows) num_rows
from   user_tab_partitions
where  table_name = 'BILLING_RECORDS' and partition_name like 'P\_2%' escape '\'
group  by case when read_only = 'YES' then 'WARM' else 'HOT' end, tablespace_name, compression
order  by 1;

prompt === BILLING_ARCHIVE partitions ===
select count(*) partitions, min(partition_name) first_part, max(partition_name) last_part,
       sum(num_rows) num_rows
from   user_tab_partitions
where  table_name = 'BILLING_ARCHIVE' and partition_name like 'P\_2%' escape '\';

prompt === Size per table (MB, incl. indexes) ===
col table_name for a24
select nvl(i.table_name, s.segment_name) table_name, round(sum(s.bytes) / 1048576) mb
from   user_segments s left join user_indexes i on i.index_name = s.segment_name
where  nvl(i.table_name, s.segment_name) like 'BILLING%'
group  by nvl(i.table_name, s.segment_name)
order  by 1;
