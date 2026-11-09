-- =============================================================================
-- 03_billing_tables.sql
-- Purpose : Billing tables for the two designs being compared.
--
--   BASELINE ("before", the client's current design)
--     BILLING_RECORDS_BASE   one heap table holding all history
--     BILLING_ARCHIVE_BASE   heap archive filled by INSERT ... SELECT + DELETE
--
--   OPTIMISED ("after", our design)
--     BILLING_RECORDS        monthly interval-range partitioned (hot + warm)
--     BILLING_ARCHIVE        monthly partitioned, compressed archive
--     BILLING_XCHG           empty staging table used for partition exchange
--     BILLING_LOAD_STAGE     staging for the monthly load benchmark
--
-- All billing tables are derived from BILLING_RECORDS_BASE with CTAS ... WHERE 1=0
-- so their column definitions are guaranteed identical (required by EXCHANGE).
-- Run as  : TELCO_OWNER
-- Params  : &data_start (YYYY-MM-DD, first month of history)
-- =============================================================================

create table billing_records_base (
  record_id       number(12)    not null,
  invoice_id      number(14)    not null,
  customer_id     number(10)    not null,
  plan_id         number(4)     not null,
  bill_date       date          not null,
  service_type    varchar2(8)   not null,
  region_code     varchar2(3)   not null,
  duration_sec    number(6),
  volume_mb       number(10,2),
  amount          number(10,2)  not null,
  tax_amount      number(10,2)  not null,
  payment_status  varchar2(11)  not null
) tablespace telco_hot;

-- ---- Optimised design -------------------------------------------------------
-- One partition per month, created automatically by INTERVAL when a new month
-- arrives: no manual "add partition" job, no missing-partition errors.
create table billing_records
  tablespace telco_hot
  partition by range (bill_date) interval (numtoyminterval(1, 'MONTH'))
  ( partition p_initial values less than (date '&data_start') )
  as select * from billing_records_base where 1 = 0;

-- Archive: same layout, compressed, stored in the archive tier.
-- BASIC compression is included in Enterprise Edition (no Advanced Compression
-- licence needed); it applies to direct-path loads and partition moves.
create table billing_archive
  tablespace telco_arch
  row store compress basic
  partition by range (bill_date) interval (numtoyminterval(1, 'MONTH'))
  ( partition p_initial values less than (date '&data_start') )
  as select * from billing_records_base where 1 = 0;

create table billing_xchg
  tablespace telco_arch
  as select * from billing_records_base where 1 = 0;

create table billing_load_stage
  tablespace telco_hot
  as select * from billing_records_base where 1 = 0;

-- ---- Baseline archive -------------------------------------------------------
create table billing_archive_base
  tablespace telco_arch
  as select * from billing_records_base where 1 = 0;

-- ---- Same business rules (CHECK constraints) on every billing table ----------
declare
  type t_list is table of varchar2(30);
  l_tables t_list := t_list('BILLING_RECORDS_BASE', 'BILLING_RECORDS', 'BILLING_ARCHIVE',
                            'BILLING_XCHG', 'BILLING_ARCHIVE_BASE', 'BILLING_LOAD_STAGE');
  l_prefix varchar2(30);
begin
  for i in 1 .. l_tables.count loop
    l_prefix := case l_tables(i)
                  when 'BILLING_RECORDS_BASE' then 'BRB'
                  when 'BILLING_RECORDS'      then 'BR'
                  when 'BILLING_ARCHIVE'      then 'BA'
                  when 'BILLING_XCHG'         then 'BX'
                  when 'BILLING_ARCHIVE_BASE' then 'BAB'
                  else 'BLS' end;
    execute immediate 'alter table ' || l_tables(i) || ' add constraint ' || l_prefix ||
      '_service_ck check (service_type in (''VOICE'', ''SMS'', ''DATA'', ''ROAMING''))';
    execute immediate 'alter table ' || l_tables(i) || ' add constraint ' || l_prefix ||
      '_status_ck check (payment_status in (''PAID'', ''UNPAID'', ''DISPUTED'', ''WRITTEN_OFF''))';
    execute immediate 'alter table ' || l_tables(i) || ' add constraint ' || l_prefix ||
      '_amount_ck check (amount >= 0 and tax_amount >= 0)';
  end loop;
end;
/

-- Local index on the archive and matching index on the exchange table:
-- EXCHANGE ... INCLUDING INDEXES swaps index segments too (no rebuild).
create index billing_arch_cust_lix on billing_archive (customer_id, bill_date)
  local tablespace telco_arch;
create index billing_xchg_cust_ix on billing_xchg (customer_id, bill_date)
  tablespace telco_arch;
create index billing_arch_base_cust_ix on billing_archive_base (customer_id, bill_date)
  tablespace telco_arch;
create index billing_arch_base_date_ix on billing_archive_base (bill_date)
  tablespace telco_arch;

-- Incremental statistics: after a monthly load only the new partition is
-- scanned; global stats are derived from per-partition synopses.
begin
  dbms_stats.set_table_prefs(user, 'BILLING_RECORDS', 'INCREMENTAL', 'TRUE');
  dbms_stats.set_table_prefs(user, 'BILLING_ARCHIVE', 'INCREMENTAL', 'TRUE');
end;
/

-- ---- Unified views: online + archive -----------------------------------------
-- Applications and analysts query one name, wherever the data lives.
create or replace view billing_all as
  select * from billing_records
  union all
  select * from billing_archive;

create or replace view billing_all_base as
  select * from billing_records_base
  union all
  select * from billing_archive_base;
