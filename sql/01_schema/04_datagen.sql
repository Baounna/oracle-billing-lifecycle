-- =============================================================================
-- 04_datagen.sql
-- Purpose : Generate representative telecom billing history inside the database.
--
-- Design choices
--   * Set-based SQL with direct-path insert (/*+ APPEND */): millions of rows per
--     minute, far faster than row-by-row generation from a client.
--   * ORA_HASH(n, buckets, seed) instead of DBMS_RANDOM: deterministic, so the
--     dataset - and therefore every benchmark - is reproducible.
--   * Realistic shape: 50% DATA, 30% VOICE, 15% SMS, 5% ROAMING; volume grows
--     ~85% over the period; recent months have unpaid invoices, old months are
--     settled (PAID / WRITTEN_OFF / DISPUTED).
-- Run as  : TELCO_OWNER
-- =============================================================================

create or replace procedure generate_billing_month (
  p_table     in varchar2,   -- target table (BILLING_RECORDS_BASE or BILLING_LOAD_STAGE)
  p_month     in date,       -- first day of the month to generate
  p_rows      in pls_integer,
  p_first_id  in number,     -- record_id offset (record_id = p_first_id + 1 .. + p_rows)
  p_as_of     in date        -- reference "today": drives the payment status mix
) authid definer as
  l_seed   number := to_number(to_char(p_month, 'YYYYMM'));
  l_secs   number := (add_months(p_month, 1) - p_month) * 86400 - 1;
  l_age    number := months_between(trunc(p_as_of, 'MM'), trunc(p_month, 'MM'));
  l_custs  number;
  l_sql    varchar2(32767);
begin
  select count(*) into l_custs from customers;
  if l_custs >= 1000000 then   -- invoice_id = YYYYMM * 1e6 + customer_id must stay unique
    raise_application_error(-20001, 'CUSTOMERS must be below 1,000,000 (invoice_id encoding)');
  end if;

  l_sql := q'[
    insert /*+ append */ into #TABLE#
      (record_id, invoice_id, customer_id, plan_id, bill_date, service_type, region_code,
       duration_sec, volume_mb, amount, tax_amount, payment_status)
    select g.record_id,
           #YYYYMM# * 1000000 + g.customer_id,
           g.customer_id, c.plan_id, g.bill_date, g.service_type, c.region_code,
           g.duration_sec, g.volume_mb, g.amount, round(g.amount * 0.20, 2),
           case
             when #AGE# <= 1 then
               case when g.h_status < 55 then 'UNPAID' when g.h_status < 98 then 'PAID' else 'DISPUTED' end
             when #AGE# <= 3 then
               case when g.h_status < 8  then 'UNPAID' when g.h_status < 98 then 'PAID' else 'DISPUTED' end
             else
               case when g.h_status < 97 then 'PAID' when g.h_status < 99 then 'WRITTEN_OFF' else 'DISPUTED' end
           end
    from (
      select x.*,
             case x.service_type
               when 'VOICE' then round(x.duration_sec * 0.012, 2)
               when 'SMS'   then 0.35
               when 'DATA'  then round(x.volume_mb * 0.015, 2)
               else round(5 + ora_hash(x.n, 9500, #SEED# + 4) / 100, 2)
             end as amount
      from (
        select n,
               #FIRST_ID# + n                                        as record_id,
               ora_hash(n, #CUSTS# - 1, #SEED#) + 1                  as customer_id,
               #MONTH# + ora_hash(n, #SECS#, #SEED# + 1) / 86400     as bill_date,
               case when h < 50 then 'DATA' when h < 80 then 'VOICE'
                    when h < 95 then 'SMS'  else 'ROAMING' end        as service_type,
               case when h >= 50 and h < 80
                    then 5 + ora_hash(n, 3595, #SEED# + 2) end        as duration_sec,
               case when h < 50
                    then round(ora_hash(n, 300000, #SEED# + 3) / 100, 2) end as volume_mb,
               ora_hash(n, 99, #SEED# + 5)                           as h_status
        from (select level as n, ora_hash(level, 99, #SEED# + 6) as h
              from dual connect by level <= #ROWS#)
      ) x
    ) g
    join customers c on c.customer_id = g.customer_id]';

  l_sql := replace(l_sql, '#TABLE#',    dbms_assert.simple_sql_name(p_table));
  l_sql := replace(l_sql, '#YYYYMM#',   to_char(l_seed));
  l_sql := replace(l_sql, '#AGE#',      to_char(l_age));
  l_sql := replace(l_sql, '#SEED#',     to_char(l_seed));
  l_sql := replace(l_sql, '#FIRST_ID#', to_char(p_first_id));
  l_sql := replace(l_sql, '#CUSTS#',    to_char(l_custs));
  l_sql := replace(l_sql, '#MONTH#',    'date ''' || to_char(p_month, 'YYYY-MM-DD') || '''');
  l_sql := replace(l_sql, '#SECS#',     to_char(l_secs));
  l_sql := replace(l_sql, '#ROWS#',     to_char(p_rows));

  execute immediate l_sql;
end generate_billing_month;
/

create or replace procedure generate_history (
  p_table     in varchar2,
  p_start     in date,
  p_months    in pls_integer,
  p_avg_rows  in pls_integer,
  p_as_of     in date
) authid definer as
  l_rows     pls_integer;
  l_next_id  number := 0;
  l_t0       number;
begin
  for m in 0 .. p_months - 1 loop
    -- Linear business growth: 70% of the average at the start, 130% at the end.
    l_rows := round(p_avg_rows * (0.7 + 0.6 * m / greatest(p_months - 1, 1)));
    l_t0   := dbms_utility.get_time;
    generate_billing_month(p_table, add_months(p_start, m), l_rows, l_next_id, p_as_of);
    commit;
    insert into dlm_job_log (run_id, job_name, action, target, rows_affected, elapsed_sec, status)
    values (null, 'DATAGEN', 'GENERATE_MONTH',
            p_table || ':' || to_char(add_months(p_start, m), 'YYYY-MM'),
            l_rows, (dbms_utility.get_time - l_t0) / 100, 'OK');
    commit;
    l_next_id := l_next_id + l_rows;
  end loop;
end generate_history;
/
