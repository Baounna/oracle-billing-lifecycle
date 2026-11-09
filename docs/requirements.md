# Requirements, indicators and technology assessment

## 1. Client context (scenario)

| Item | Description |
|---|---|
| Client | Mobile telecom operator (fictitious), ~500 000 subscribers, billing for voice, SMS, data and roaming |
| Sponsor | DBA Manager, IT department |
| Current situation | All billing history in one Oracle table; ~330 000 billing lines per month, +85 % growth over 6 years; 24 M rows |
| Business problem | Month-end and audit reports get slower every month; purging old data is a long `DELETE` that runs at night and generates gigabytes of redo; retention rules are applied by hand |
| Regulatory constraint | Billing data kept **60 months** (legal retention), then deleted |

## 2. Requirements

### Functional

| ID | Requirement |
|---|---|
| F1 | Store billing history so that monthly and annual reports read only the period requested |
| F2 | Apply the retention policy automatically: hot (12 months), online (36 months), archive (until 60 months), purge after |
| F3 | Archived data remains queryable (audit, legal requests) through one access point |
| F4 | Retention parameters can be changed without modifying code |
| F5 | A dry-run mode shows what the job would do |
| F6 | Every lifecycle action is logged (what, when, how many rows, how long, result) |
| F7 | Integrity of billing data can be proven after every operation |

### Technical / non-functional

| ID | Requirement |
|---|---|
| T1 | Lifecycle operations must not copy or delete rows one by one when avoidable |
| T2 | A failure in the middle of an operation must not lose data, and a re-run must recover |
| T3 | Data inside the legal retention can never be purged, whatever parameter is passed |
| T4 | Old billing data cannot be modified (accidental update, late insert) |
| T5 | Least privilege: the billing application cannot delete history or run lifecycle jobs; analysts are read-only |
| T6 | No credentials in source code or in the Git repository |
| T7 | Whole solution reproducible from scripts on the course Docker environment |
| T8 | Lab must not exhaust the laptop disk (shared, ~15 GB free) |
| T9 | Use only licensed features; document licence impact |

### Constraints

Oracle 19c EE in Docker on a laptop (8 vCPU, ~8 GB RAM for Docker, ~15 GB free disk), 4 weeks,
team of two, synthetic data only.

## 3. Indicators and targets

The indicators were formalised after the first exploratory benchmark and before the final
run whose numbers are reported (the brief asks for indicators defined before testing; this
order is stated openly).

| KPI | Indicator | Measured by | Target |
|---|---|---|---|
| K1 | Date-bounded report (Q1) | median elapsed + logical reads, same SQL and binds | >= 5x faster, >= 10x fewer LIO |
| K2 | Audit query on archived month (Q7) | idem, through `BILLING_ALL` | >= 5x fewer LIO than baseline |
| K3 | OLTP queries (Q2 lookup by customer, Q5 by id) | median elapsed | no regression > 2x |
| K4 | Archive one month | elapsed, redo | >= 10x faster than INSERT+DELETE, < 5 s; also reported for the whole monthly job (warm + archive + purge) |
| K5 | Purge one month | elapsed, redo | < 1 s |
| K6 | Monthly load + statistics refresh (routine) | elapsed | not slower than baseline |
| K7 | Storage of retained data (online + archive) | `USER_SEGMENTS` | >= 25 % smaller than baseline |
| K8 | Data integrity | months matching load-time control totals | 100 % |
| K9 | Recovery after crash | rows lost, manual steps | 0 rows lost, recovery = re-run |
| K10 | Security controls | 25 asserted checks (22 unauthorised actions must be rejected, 3 allowed actions must work) | 100 % |
| K11 | Automation | manual steps per month | 1 command (`run_lifecycle`) |

## 4. Technology assessment

### Database platform

| Option | Pros | Cons | Decision |
|---|---|---|---|
| Oracle Database 23ai Free | free, recent, partitioning available | 12 GB user data limit, 2 GB RAM, not the course container | Not needed |
| **Oracle 19c EE (course container)** | already installed, Partitioning option present, long-term support release used by most companies | licence cost in production (EE + Partitioning) | **Chosen** |

### Data segmentation

| Option | Pros | Cons | Decision |
|---|---|---|---|
| Single heap table + indexes (current) | simple | full scans for period reports, DELETE-based retention | Baseline |
| One table per month + `UNION ALL` view (partition view) | works without Partitioning option | view to regenerate monthly, app must route inserts, weaker pruning with binds | Documented alternative |
| Range partitioning, monthly partitions created by a job | standard | job must create future partitions or inserts fail | Rejected |
| **Interval-range partitioning by month on `bill_date`** | partitions created automatically, pruning, partition-level maintenance | needs Partitioning option, system partition names (renamed by DLM) | **Chosen** |
| Composite (range-list by service) | finer pruning on service | more segments, no workload filters on service only | Rejected (not needed by workload) |

### Archiving method

| Option | Pros | Cons | Decision |
|---|---|---|---|
| `INSERT ... SELECT` + `DELETE` (current) | simple | copies and deletes every row, huge redo/undo, table does not shrink | Baseline |
| Data Pump export of old partitions + drop | data leaves the database | archive no longer queryable with SQL, restore needed for audits | Rejected (F3) |
| **Exchange partition into an archive table** | metadata operation, archive stays queryable | global index maintenance, identical structures required | **Chosen** |

### Compression

| Option | Licence | Decision |
|---|---|---|
| **BASIC** (`ROW STORE COMPRESS BASIC`) | included in EE | **Chosen** for warm/archive (read-only data) |
| ADVANCED (OLTP) | Advanced Compression option | Not used (licence) |
| Hybrid Columnar | Exadata / engineered storage only | Not available |

### Tooling

| Need | Choice | Why |
|---|---|---|
| Lifecycle logic | PL/SQL package in the database | runs next to the data, transactional logging, schedulable with `DBMS_SCHEDULER` |
| Data generation | set-based SQL with `ORA_HASH` | millions of rows per minute, deterministic |
| Benchmark harness | Python 3.12 + python-oracledb (thin) | `V$MYSTAT` deltas, plans, JSON results, charts |
| Clients | SQL*Plus (in DB container), SQLcl (tools container) | no installation on the host |
| Automation | Bash scripts + Docker Compose | reproducible on any Docker host |
| Version control | Git | required by the brief |
