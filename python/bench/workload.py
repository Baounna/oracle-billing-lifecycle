"""Representative query workload of the telecom billing system.

Each query is executed against the BASELINE design and the PARTITIONED design
with identical SQL text and bind values, so results are directly comparable.
`{t}` is replaced by the table (or view) under test.
"""
from datetime import datetime

QUERIES = [
    {
        "id": "Q1",
        "name": "Monthly revenue by service (last closed month)",
        "user": "Finance month-end report",
        "sql": """select service_type, count(*) records, sum(amount) revenue
                  from {t}
                  where bill_date >= :d1 and bill_date < :d2
                  group by service_type""",
        "binds": {"d1": datetime(2026, 10, 1), "d2": datetime(2026, 11, 1)},
    },
    {
        "id": "Q2",
        "name": "Customer bill history, last 3 months",
        "user": "Customer care screen",
        "sql": """select bill_date, service_type, amount, payment_status
                  from {t}
                  where customer_id = :cust and bill_date >= :d1 and bill_date < :d2
                  order by bill_date""",
        "binds": {"cust": 123457, "d1": datetime(2026, 8, 1), "d2": datetime(2026, 11, 1)},
    },
    {
        "id": "Q3",
        "name": "Annual revenue by region and service (2025)",
        "user": "Management dashboard",
        "sql": """select region_code, service_type, sum(amount) revenue, sum(tax_amount) tax
                  from {t}
                  where bill_date >= :d1 and bill_date < :d2
                  group by region_code, service_type""",
        "binds": {"d1": datetime(2025, 1, 1), "d2": datetime(2026, 1, 1)},
    },
    {
        "id": "Q4",
        "name": "Open receivables (unpaid/disputed), last 6 months",
        "user": "Collections team",
        "sql": """select region_code, count(*) invoices, sum(amount + tax_amount) due
                  from {t}
                  where payment_status in ('UNPAID', 'DISPUTED')
                    and bill_date >= :d1 and bill_date < :d2
                  group by region_code""",
        "binds": {"d1": datetime(2026, 5, 1), "d2": datetime(2026, 11, 1)},
    },
    {
        "id": "Q5",
        "name": "Single billing record lookup by id",
        "user": "Billing application (OLTP)",
        "sql": """select * from {t} where record_id = :rid""",
        "binds": {"rid": None},  # resolved at runtime (a recent record)
    },
    {
        "id": "Q6",
        "name": "Revenue per year over the whole table (no date filter)",
        "user": "Ad-hoc analyst query",
        "sql": """select extract(year from bill_date) yr, sum(amount) revenue
                  from {t}
                  group by extract(year from bill_date)""",
        "binds": {},
    },
    {
        "id": "Q7",
        "name": "Disputed bills in an archived month (2022-03)",
        "user": "Legal / audit request",
        "sql": """select customer_id, count(*) records, sum(amount) total
                  from {t}
                  where bill_date >= :d1 and bill_date < :d2 and payment_status = 'DISPUTED'
                  group by customer_id
                  order by total desc
                  fetch first 20 rows only""",
        "binds": {"d1": datetime(2022, 3, 1), "d2": datetime(2022, 4, 1)},
        "history": True,  # after lifecycle: run through the online+archive views
    },
]

# Upper bounds keep the same months in both phases (the benchmark loads 2026-11
# and 2026-12 between them). Q2's customer is adjusted at run time when the
# dataset has fewer customers.

# Tables (or views) per design and phase.
TARGETS = {
    "before": {"baseline": "BILLING_RECORDS_BASE", "partitioned": "BILLING_RECORDS"},
    "after": {"baseline": "BILLING_RECORDS_BASE", "partitioned": "BILLING_RECORDS"},
}
HISTORY_TARGETS = {
    "before": {"baseline": "BILLING_RECORDS_BASE", "partitioned": "BILLING_RECORDS"},
    "after": {"baseline": "BILLING_ALL_BASE", "partitioned": "BILLING_ALL"},
}
