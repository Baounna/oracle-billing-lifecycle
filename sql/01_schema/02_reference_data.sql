-- =============================================================================
-- 02_reference_data.sql
-- Purpose : Reference tables (tariff plans, customers) with synthetic,
--           fully anonymised data. Deterministic: ORA_HASH instead of random,
--           so every run produces exactly the same dataset.
-- Run as  : TELCO_OWNER
-- Params  : &customers  (number of customers)
-- =============================================================================

create table tariff_plans (
  plan_id      number(4)     constraint tariff_plans_pk primary key,
  plan_name    varchar2(40)  not null,
  plan_type    varchar2(10)  not null
               constraint tariff_plans_type_ck check (plan_type in ('PREPAID', 'POSTPAID', 'BUSINESS')),
  monthly_fee  number(8,2)   not null
) tablespace telco_hot;

insert into tariff_plans
select level,
       'PLAN_' || lpad(level, 2, '0'),
       case when level <= 8 then 'PREPAID' when level <= 16 then 'POSTPAID' else 'BUSINESS' end,
       case when level <= 8 then 0 when level <= 16 then 49 + level * 10 else 299 + level * 20 end
from   dual
connect by level <= 20;

create table customers (
  customer_id  number(10)    constraint customers_pk primary key,
  segment      varchar2(10)  not null,
  region_code  varchar2(3)   not null,
  plan_id      number(4)     not null constraint customers_plan_fk references tariff_plans,
  signup_date  date          not null,
  status       varchar2(10)  not null
               constraint customers_status_ck check (status in ('ACTIVE', 'SUSPENDED', 'CLOSED'))
) tablespace telco_hot;

insert /*+ append */ into customers
select n,
       case when mod(n, 10) = 0 then 'BUSINESS' else 'CONSUMER' end,
       case ora_hash(n, 11, 1)
         when 0 then 'CAS' when 1 then 'RAB' when 2 then 'TNG' when 3 then 'FES'
         when 4 then 'MRK' when 5 then 'AGA' when 6 then 'OUJ' when 7 then 'MEK'
         when 8 then 'TET' when 9 then 'LAA' when 10 then 'BEN' else 'KEN'
       end,
       case when mod(n, 10) = 0 then 17 + mod(n, 4) else 1 + ora_hash(n, 15, 2) end,
       date '2015-01-01' + ora_hash(n, 365 * 11, 3),
       case when ora_hash(n, 99, 4) < 92 then 'ACTIVE'
            when ora_hash(n, 99, 4) < 96 then 'SUSPENDED'
            else 'CLOSED' end
from  (select level as n from dual connect by level <= &customers);
commit;

begin
  dbms_stats.gather_table_stats(user, 'TARIFF_PLANS');
  dbms_stats.gather_table_stats(user, 'CUSTOMERS');
end;
/

select (select count(*) from tariff_plans) plans, (select count(*) from customers) customers from dual;
