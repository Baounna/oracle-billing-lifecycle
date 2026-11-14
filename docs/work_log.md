# Work log - decisions, problems, corrective actions

The guidelines ask for a record of the main stages, technical decisions, problems and
corrective actions. Newest entries at the bottom.

## Environment assessment

| Check | Finding | Decision |
|---|---|---|
| Database | Oracle 19c EE 19.19 in Docker (`oracle19c`), PDB `ORCLPDB1` | Use it: Partitioning option present (`V$OPTION`), no need for Oracle Free |
| Partitioning | Created and dropped a test interval-partitioned table | Interval partitioning works |
| Memory | SGA 2.3 GB (buffer cache ~1.7 GB), PGA 784 MB | Dataset sized above the buffer cache (~3.5 GB table+indexes) so it does not fit in memory |
| UNDO / TEMP | autoextend up to 32 GB each | **Risk**: could fill the laptop disk -> capped (UNDO 4 GB, TEMP 3 GB) |
| Host disk | 20 GB free (96 % used) | Removed unused Hadoop containers/images (+9 GB). Tablespaces created with `MAXSIZE`; scripts abort if host free space is too low |
| Tools | No SQLcl / python-oracledb on the host | Tools container (`docker/tools`) - nothing installed on the laptop |

## Design decisions

1. **Monthly interval-range partitioning on `bill_date`** - matches the retention unit
   (month), the reporting unit (monthly/annual) and the billing cycle. Interval removes the
   need for a job that pre-creates partitions.
2. **Three tiers + purge** (hot 12 / online 36 / retention 60 months) stored in
   `DLM_CONFIG`, not hard-coded.
3. **Zero-copy archive** with two partition exchanges through `BILLING_XCHG` instead of
   `INSERT ... SELECT` + `DELETE`.
4. **Global PK on `record_id`, local index on `(customer_id, bill_date)`, no date index** -
   see trade-off in `docs/licensing.md`.
5. **BASIC compression, not ADVANCED** - included in EE, no extra licence; applied through
   `MOVE PARTITION` (direct path) on data that is no longer modified, then made read-only.
6. **Deterministic data generation in SQL** (`ORA_HASH` seeds) - reproducible dataset,
   ~24 M rows generated in ~3 minutes.
7. **Control totals** (count, sum, row-hash sum per month) captured at load time -
   objective proof of integrity after every operation.
8. **Baseline implemented with the same policy and guards** (`BASELINE_PKG`), so the
   benchmark compares techniques, not rules.

## Problems and corrective actions

| Problem | Cause | Correction |
|---|---|---|
| `sqlplus / as sysdba` -> ORA-12162 | `ORACLE_SID` not set in `docker exec` shells | `docker exec -e ORACLE_SID=ORCLCDB` in `lib.sh` |
| `DBA_PDB_SAVED_STATE` not found | view name is plural in 19c | `DBA_PDB_SAVED_STATES` (PDB is saved OPEN) |
| Interval partitions named `SYS_Pxxxx` | system-generated names | `dlm_pkg.rename_partitions` evaluates `HIGH_VALUE` and renames table **and** local index partitions to `P_YYYYMM` |
| Risk of losing data if archiving crashes mid-way | two-step exchange | Job detects rows left in `BILLING_XCHG`, resumes at step 2, never truncates it (tests T12-T17) |
| Passwords visible in `ps` / SQL*Plus echo | credentials on the command line | passwords piped through stdin; `SET VERIFY OFF`; `.env` mode 600 and git-ignored |
| Host disk nearly full | Docker images from older projects | cleanup + tablespace caps + disk guard in scripts |

## Validation milestones

- Smoke dataset (216 000 rows): 27/27 functional tests passed in the first version, 31/31 after
  the review below; security tests behave as expected (see `results/tests/`).
- Full dataset: 23 760 000 rows loaded in ~3 min (baseline) + ~2 min (partitioned copy);
  integrity check 72/72 months.
- First benchmark (~20 min): both designs 61/61 months valid after the retention policy.
- Final benchmark with the final code (~23 min): both designs 62/62 months valid; numbers in
  `results/summary.md`, interpretation and KPI status in `docs/results_analysis.md`.

## Benchmark findings that changed the analysis

| Finding | Investigation | Conclusion |
|---|---|---|
| Incremental stats on the partitioned table took 71 s vs 32 s for the full baseline gather | `LAST_ANALYZED` per partition showed several partitions re-analysed; a second gather on unchanged data re-analysed none (9.8 s, index stats only) | One-time cost after the migration. The final benchmark loads two months and reports both: first gather re-analysed all 73 partitions (78 s), the routine one only the new partition (14 s vs 35 s for the baseline) |
| Q6 / Q3 slower after lifecycle although LIO dropped | warm partitions are BASIC-compressed | Decompression CPU; documented as a trade-off |
| Q2 uses more LIO on the partitioned table | plan: local index range scan over 3-4 index partitions | Inherent to local indexes; negligible in time |
| WARM generates ~160 MB redo per month | global PK maintained during `MOVE PARTITION` | Main cost of the new design; options documented (NOLOGGING + backup, local PK) |

## Full review before deliverables (corrections)

| Finding | Impact | Correction | Evidence |
|---|---|---|---|
| `TELCO_APP` could insert a row dated in an archived month into `BILLING_RECORDS`; even after `ROLLBACK`, Oracle kept a new empty interval partition for that month online | data back in the wrong tier, next archive run would be refused ("archive partition already contains data") | Application writes through `BILLING_CURRENT_V` (HOT window, `WITH CHECK OPTION`, refreshed by every run); `archive_partition` drops empty partitions | security tests, T27-T31 |
| Even a rejected insert through the view creates the empty interval partition | cosmetic (no data), but changes partition counts | documented Oracle behaviour; cleaned automatically by the next run | T29, T31 |
| Disk check used `df -g` (macOS only) | scripts not reproducible on Linux | POSIX `df -Pk` | `scripts/lib.sh` |
| Disk threshold 15 GB blocked re-loading the data on this laptop | could not reproduce the run | threshold 10 GB (load needs ~7 GB; space freed by reset is reused) | `.env.example` |
| Benchmark could be run twice on an already-processed dataset | meaningless results | benchmark refuses to start if the archive is not empty | `run_benchmark.py` |
| Statistics comparison mixed the one-time first gather with routine refreshes | misleading chart | benchmark now loads two months and reports `GATHER_STATS_FIRST` and routine `GATHER_STATS` separately | `results/summary.md` |
| Indicators were implicit | brief requires indicators defined before testing | `docs/requirements.md` §3 (targets), then a final run with the final code | `docs/results_analysis.md` |
| No demonstration material | deliverable 5 | `scripts/06_demo.sh` + `sql/04_demo/` + `docs/demo.md`, rehearsed on the smoke dataset | `results/demo/` |
| Demo step 5 ran the whole policy (~4 min on the full dataset) | too long for a 5-minute demo | step 0 applies last month's policy before the defense; the live run is the routine monthly job (1 purge, 1 warm, 1 archive) | `docs/demo.md` |
| Dry run listed months that were already warm (25 instead of 1) | misleading plan | `run_lifecycle` skips months already compressed in TELCO_ARCH (`is_warm`). Changed after the final benchmark; the benchmark calls the per-month procedures directly, which are unchanged | demo rehearsal (`results/demo/`), tests |

## Independent code review (second review round)

An independent reviewer (fresh AI agent, read-only, not given our conclusions) re-read the
whole repository. All findings were checked, then corrected:

| Finding | Correction | Evidence |
|---|---|---|
| Monthly job validated HOT months against load-time totals: a normal committed bill from the application would make `run_lifecycle` fail | Totals re-captured when a month is frozen (WARM); the job validates frozen months only | T32 |
| `archive_partition` accepted months inside the online window and un-warmed months (archive left uncompressed in TELCO_HOT) | Refuses months inside `ONLINE_MONTHS`; warms the month first if needed | T09, T12-T17 |
| Rejected far-future inserts left empty partitions forever | `run_lifecycle` drops empty partitions outside the application window | T28-T31 |
| Passwords substituted into a PL/SQL block (literals could stay readable in `V$SQL`, which TELCO_OWNER may query) | Plain `CREATE/ALTER USER` statements only | `sql/00_admin/02_users.sql` |
| Security tests only printed labels, nothing was asserted | PL/SQL assertions, script fails on any unexpected result (16 checks) | `results/tests/security_*.txt` |
| TEMP `resize 512M` could fail (ORA-03297) on a re-setup after TEMP grew | Resize only when smaller | `01_tablespaces.sql` |
| Partition lists not ordered; staged month not resumed first by `run_lifecycle` | `ORDER BY partition_position`; resume step 0 | code review |
| Row fingerprint ignored several columns | Fingerprint covers every column | `dlm_pkg.c_hash_expr` |
| Baseline purge guard used a different parameter than DLM | Same rule (`RETENTION_MONTHS`) | `06_baseline_pkg.sql` |
| Calendar values hard-coded in tests/benchmark although presented as configurable | Documented; tests and benchmark check the calendar and refuse another one | README, precondition |
| Archive KPI (62x) did not include the compression step it depends on | Results now also compare the full monthly job (warm + archive + purge) | `docs/results_analysis.md` |
| Unused/unpinned SQLcl download, compose ignored `ENV_FILE`, stale docstring option | SQLcl pinned (26.3.1), `env_file: ${ENV_FILE:-.env}`, docstring fixed | Dockerfile, compose |

## Per-file review (third review round)

Three independent reviewers (fresh AI agents, read-only) each reviewed one area file by file:
SQL schema and packages; scripts, tests and demo; Python, Docker and documentation. Every
finding was checked against the code before being fixed. The benchmark that was running
used the previous package version, so it was stopped and re-run with the final code.

| Area | Finding | Correction | Evidence |
|---|---|---|---|
| DLM | WARM matched the local index partition by **name**: for a system-named partition (`SYS_Pxxx`, every month created by an application insert) the index stayed UNUSABLE | Index partitions matched by **position**; `run_lifecycle` renames partitions first | T34 |
| DLM | WARM was not resumable (a move followed by a failed rebuild was later reported "already warm") | "Warm" now means compressed + read-only + usable index in TELCO_ARCH; a re-run completes an interrupted warm | T35 |
| DLM | `run_lifecycle(p_as_of)` planned with `p_as_of` but each operation checked guards with the configured month | `p_as_of` passed to every operation (DLM and baseline) | T36 |
| DLM | Application window refreshed at the end of the run, after freezing months | Refreshed at the start, before any month is frozen | code |
| DLM | A failed archive left the month read/write | Read-only restored in the error handler | code |
| Baseline | Guards differed from DLM (archive allowed inside the online window, no retention floor) | Same rules; only months still holding rows are processed | code |
| Admin | Re-running setup printed passwords (SQL*Plus echoes a failing `CREATE USER`) | Users created `NO AUTHENTICATION` in PL/SQL (no secret), password set by plain `ALTER USER`; no statement can fail | setup run twice, 0 password in logs |
| Admin | Teardown failed if a project session was connected | Sessions ended before `DROP USER` | `99_teardown.sql` |
| Tests | Precondition did not detect an already processed dataset; log counts not scoped to the run; weak assertions (T06, T29, T31, positive security checks without fetch) | Stronger precondition, run-scoped log checks, stray partitions asserted before cleanup, positive checks fetch data | 36/36 + 16/16 |
| Demo | Bind variables hid which partition is read; "12 HOT" should be 13 after step 0; usage text | Literal dates (plan shows `PARTITION RANGE SINGLE` 73/73), corrected texts | demo rehearsal |
| Bench | Results written only at the end; `--runs 0` crashed | JSON checkpoint after each phase; `--runs >= 1` | `run_benchmark.py` |
| Report | Archive KPI excluded the WARM step it depends on; charts too | Monthly-job comparison (warm + archive + purge vs archive + purge) in summary and charts | `results/summary.md` |
| Docs | No instructions to build the Oracle container; no team split / timeline; stale counts | README container section, `docs/project_plan.md`, counts updated | README |

## Ten-reviewer audit (fourth review round)

Ten independent reviewers each audited one slice of the project (DLM operations, DLM
orchestration and integrity, data generation and baseline, security, schema and licensing,
functional tests, security tests and demo, bash scripts, benchmark harness, report and
documentation). Each finding was re-checked in the code; two Oracle behaviours were verified
on the database before choosing a fix:

- `MOVE PARTITION` **is allowed** on a read-only partition; `DROP PARTITION` is **not**
  (ORA-14466).
- An account holding `SELECT` can `LOCK TABLE` a view (and so its base tables); with `READ`
  it cannot (ORA-01031), nor `SELECT ... FOR UPDATE`.

| Area | Finding (reviewers) | Correction | Evidence |
|---|---|---|---|
| Benchmark | Purge measured on the online table (global PK upkeep) instead of the archive as in steady state, so the purge KPI and the monthly-job composite were wrong (1) | Months are warmed and archived first, then purged from the archive - same order for the baseline | `run_benchmark.py` |
| DLM | A row committed between the capture of a month's totals and its MOVE made every later run fail (3) | WARM freezes the month (READ ONLY, waits for in-flight DML) **before** capturing totals, then moves it | code |
| Security | Analyst could lock the tables and block the lifecycle job (1, confirmed on the DB) | `READ` instead of `SELECT`; DDL waits up to 60 s (`ddl_lock_timeout`) | A06, A10, S14 |
| DLM | Archive interrupted after the second exchange left the archive month read/write (2) | Each run re-applies READ ONLY to archive partitions holding data | code |
| DLM | Failed archive re-froze months that were never warmed (1) | Only warm months are re-frozen | code |
| DLM | Application window could re-open already frozen months (1) | Window starts after the last read-only month | S12 |
| DLM | Dry run planned WARM/ARCHIVE for partitions it also planned to drop (2) | Skipped in dry run | demo step 3 |
| Tests | Guards never tested at their exact boundary; integrity gate, resume by `run_lifecycle`, archive state, re-capture at freeze, baseline archive move untested; T25 weak (1) | T37-T42 added, T25/T32/T33 strengthened (43 tests) | `results/tests/` |
| Tests | Destructive tests could run on the benchmark dataset (1) | Refused above 2 M rows; old outputs deleted before a run | precondition |
| Security tests | Window boundary and several analyst actions not checked (1) | S12-S14, A06-A11 (25 checks) | `results/tests/` |
| Demo | "Pstart = partition position" is wrong for interval partitioning; plan type; step 5 wording; step 6 also changes state (2) | Corrected texts; incident checks the archive range only | `results/demo/` |
| Admin | Teardown killed any `TELCO%` session in the shared container; accounts not locked first (2) | Locks and ends only the three project accounts | `99_teardown.sql` |
| Docker | Tools container received all three passwords; relative `ENV_FILE` read from two places (2) | Only the owner password is passed; `ENV_FILE` made absolute | `docker-compose.yml`, `lib.sh` |
| Benchmark | Measurements of the running phase lost on a crash; rerun after a partial run not detected; Q2/Q4 changed meaning after the loads; plans of several runs mixed (1) | Checkpoint after every operation, stricter guard, fixed upper bounds, plans cleared per run | `run_benchmark.py` |
| Docs | SE2 compression advice wrong (basic compression is EE-only); "local PK on record_id" impossible (ORA-14039); Q5 claim for archived rows; README commands that fail in SQL*Plus; `.env.smoke` created world-readable; stale test numbers; no risk analysis (3) | All corrected; risk table and environments in `architecture.md` §6 | docs |
| Datagen | `invoice_id` collides with >= 1 M customers (1) | Generator refuses such a scale | `04_datagen.sql` |

Not changed (documented instead): statistics of archive partitions are re-computed after an
exchange (no synopsis on `BILLING_XCHG`); synthetic-data realism limits (payment status per
line, bills before signup date).

## Final review (pre-presentation)

| Area | Finding | Fix |
|---|---|---|
| DLM_PKG | Two concurrent lifecycle runs share `BILLING_XCHG` and could mix two months | Entry points take a `DBMS_LOCK` user lock (released on exit and on error); a second run gets ORA-20050 |
| DLM_PKG | "archive partition already contains data" was checked after exchange step 1 | Also checked before step 1, while the month is still online |
| DLM_PKG | A direct purge could drop a month whose rows wait in `BILLING_XCHG` | Purge refuses it (resume the archive first) |
