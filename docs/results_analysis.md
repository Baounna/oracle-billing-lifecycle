# Results analysis

Raw numbers: [`results/summary.md`](../results/summary.md), generated from
`results/benchmark_results.json` (final run with the final code, 2026-11-09).
Execution plans: `results/plans/`. Test outputs: `results/tests/`. Demo rehearsal on the
full dataset: `results/demo/`.

Context: Oracle 19c EE in Docker on a laptop (8 vCPU, ~8 GB RAM for Docker, buffer cache
~1.7 GB), 23.76 M billing rows over 72 months (~3.1 GB table + indexes per design). Each query
ran once to warm up, then 5 times; medians are reported.

**How to read the times.** The baseline table (1.6 GB) is read with serial *direct path reads*
(full scans of large tables bypass the buffer cache), so every baseline full scan goes to disk
(about 204 000 physical reads per execution) and its elapsed time varies with the laptop's
I/O. Single partitions stay in cache. **Logical reads (LIO) are the stable, comparable
indicator.** Times are client-side (they include fetch round-trips), so sub-millisecond
queries (Q2, Q5) are dominated by noise.

## 1. Query performance

| Query | Before lifecycle: time / LIO | After lifecycle: time / LIO | Explanation |
|---|---|---|---|
| Q1 monthly revenue | **14x / 54x** | **14x / 56x** | Partition pruning (`PARTITION RANGE ITERATOR`, `Pstart/Pstop = KEY` with bind variables; `RANGE SINGLE` with literals) reads one month. One month is ~1.8 % of the rows, still too many for the baseline's `bill_date` index, so the baseline full-scans the table |
| Q7 audit, archived month | 109x (noisy) / **86x** | **43x / 97x** | Pruning on the online table, then on `BILLING_ARCHIVE` through `BILLING_ALL`; the archived month is compressed |
| Q4 open receivables, 6 months | 3.5x / 9.3x | 3.4x / 9.7x | 6 partitions instead of the whole table |
| Q3 annual revenue 2025 | 1.9x / 5.1x | 1.5x / 7.0x | 12 partitions; aggregating ~4.4 M rows is CPU-bound, and after the lifecycle 10 of those months are compressed (decompression costs CPU) |
| Q6 no date filter | 1.0x / 1.0x | 1.3x / 2.0x | No predicate on the partition key: no pruning. After the lifecycle the online table holds 38 months, 24 of them compressed: half the blocks |
| Q5 lookup by id | 1.0x / 1.0x | 1.0x / 1.0x | Global PK index: one probe in both designs (online months) |
| Q2 customer, 3 months | 0.9 -> 0.8 ms / 6 -> 12 LIO | 1.2 -> 0.8 ms / 6 -> 12 LIO | The local index has one B-tree per month, so a 3-month range probes 3 index partitions instead of one. Same time |

Partitioning is not a universal accelerator: it helps queries that filter on the partition key
(the bulk of billing reports), is neutral for lookups through the global index, and costs a
few extra logical reads for multi-month lookups through a local index.

## 2. Maintenance operations

Measured in steady-state order: the oldest months are warmed and archived first, then purged
**from the archive** (as they would be after two years in the archive), in both designs.

| Operation (one month) | Baseline | Partitioned | Gain |
|---|---|---|---|
| Archive | 26.2 s, 499 MB redo, 197 MB undo | **0.42 s**, 6.3 MB redo | 62x time, 79x redo |
| Purge | 5.1 s, 110 MB redo | **0.02 s**, < 0.1 MB redo | ~250x time |
| Warm (freeze + move + compress) | - | 3.1 s, 153 MB redo | new step, no baseline equivalent |
| **Monthly job** (baseline archive + purge; partitioned warm + archive + purge) | **31.3 s, 609 MB redo** | **3.5 s, 159 MB redo** | **8.9x time, 3.8x redo** |
| Load one month (429 000 rows, direct path) | 4.4 s | **2.1 s** | 2.0x (no `bill_date` index, smaller local index) |
| Statistics after a routine monthly load | 35.4 s | **14.4 s**, 1 partition re-analysed | 2.5x |
| First statistics refresh after the migration | 32.2 s | 75.3 s, all 73 partitions re-analysed | one-time cost (see below) |

The month populations differ slightly between steps (purge: the 12 oldest, smallest months;
warm: 60 months), so the monthly-job figure is an average month, not one specific month.

Whole policy applied to the 6-year history (60 months warmed, 36 archived, 12 purged):
baseline **1 004 s and 19.3 GB of redo**, partitioned **199 s and 9.4 GB** (of which warm =
184 s and 9.2 GB). The catch-up is a one-time migration cost; month after month only the
monthly job runs.

Observations:

- **WARM is the expensive step of the new design.** It moves and compresses the month and
  maintains the global PK (`UPDATE GLOBAL INDEXES`), rebuilds the local index partition and
  re-captures the control totals. The split between these costs was not measured separately;
  the global index maintenance is the likely main part (it rewrites one index entry per row).
  Options: `NOLOGGING` move followed by a backup (not acceptable with a standby), or a local
  PK on `(record_id, bill_date)` (no global index to maintain, but `record_id` alone is no
  longer guaranteed unique and lookups by `record_id` probe every partition).
- **First statistics refresh after the migration re-analysed every partition** (75 s); the next
  routine refresh re-analysed only the new partition (14 s). Likely cause: the 24 M-row
  migration was recorded by DML monitoring after the initial gather, so every partition was
  seen as stale once. A one-time cost of the migration.
- Baseline deletes generate undo and redo for every row and every index entry; in ARCHIVELOG
  mode (production) the redo also becomes archived logs to back up and ship to a standby.

## 3. Storage

| Table + indexes | Before | After policy |
|---|---:|---:|
| Baseline online (`BILLING_RECORDS_BASE`) | 3 152 MB | **3 248 MB** |
| Baseline archive (`BILLING_ARCHIVE_BASE`, 2 indexes) | 0 | 1 304 MB |
| Partitioned online (`BILLING_RECORDS`) | 3 121 MB | **1 975 MB** |
| Partitioned archive (`BILLING_ARCHIVE`, 1 local index) | 0 | 587 MB |

- After moving 36 of 74 months out, the baseline table did **not shrink** (it grew: new months
  were loaded above the high-water mark), and full scans still read ~212 000 blocks (Q6 after).
  The baseline archive also keeps the space of the 12 months deleted from it. Releasing space
  would need `SHRINK SPACE` or `MOVE` on large tables.
- Purged partitions release their space immediately; BASIC compression shrinks warm and
  archived months. The archive comparison mixes compression, one fewer index and the space
  the baseline did not release.
- Retained data (online + archive): baseline 4 552 MB vs partitioned 2 562 MB (**-44 %**).

## 4. Data integrity and reliability

- Both designs: **62/62 months** match their control totals after the whole policy; purged
  months are absent. Control totals are captured at load time and re-captured when a month is
  frozen (WARM); on the static benchmark dataset both captures are identical, so the baseline
  is validated against the same reference.
- 43/43 automated functional tests (smoke dataset), including: crash in the middle of an
  archive (T12-T17) and its automatic resume by the monthly job (T41), interrupted warm (T35),
  system-named partitions (T34), late and far-future inserts (T27-T31), guards at their exact
  boundaries (T37-T39), and the monthly job stopping on a deliberately altered frozen month
  (T40, ORA-20040).
- 25/25 asserted security checks: 22 unauthorised actions rejected, 3 allowed actions work.
- Demo rehearsed on the full dataset (`results/demo/`): incident + recovery 16 s, monthly job
  with validation of 48 frozen months 46 s.

## 5. Indicators vs targets (targets in `docs/requirements.md` §3)

| KPI | Target | Result | Status |
|---|---|---|---|
| K1 date-bounded report (Q1) | >= 5x time, >= 10x LIO | 14x / 54x before, 14x / 56x after | Met |
| K2 audit on archived month (Q7) | >= 5x fewer LIO | 86x before, 97x after | Met |
| K3 OLTP queries (Q2, Q5) | no time regression > 2x | Q5 unchanged; Q2 0.9 -> 0.8 ms (twice the LIO, same time) | Met |
| K4 archive one month | >= 10x faster, < 5 s | archive operation 62x, 0.42 s. **Whole monthly job (with the WARM step the archive relies on): 8.9x, 3.5 s** | Met for the archive operation; **partly met** for the whole monthly job (8.9x < 10x) |
| K5 purge one month | < 1 s | 0.02 s | Met |
| K6 routine monthly load + stats | not slower | load 2.0x faster, stats 2.5x faster | Met (first post-migration gather slower, one-time) |
| K7 storage of retained data | >= 25 % smaller | -44 % | Met |
| K8 integrity | 100 % | 62/62 months, both designs | Met |
| K9 recovery after crash | 0 rows lost, re-run | T12-T17, T41 | Met |
| K10 security controls | 100 % | 25/25 checks | Met |
| K11 automation | 1 command | `dlm_pkg.run_lifecycle` (dry run available) | Met |

## 6. Acceptance criteria of the brief

| Criterion | Status | Evidence |
|---|---|---|
| The design preserves data integrity | Met | §4, tests T01, T17, T23, T31, T33, T40 |
| Retention operations work correctly | Met | tests T03-T42, `DLM_JOB_LOG`, demo |
| Improvements measured with comparable workloads | Met | same SQL, binds, data, policy and operation order for both designs; §1-3 |
| Licensing restrictions and trade-offs documented | Met | `docs/licensing.md`, §1-2 |

## 7. Limits of the evaluation

- Laptop + Docker: absolute times are indicative and noisy for disk-bound full scans; LIO and
  redo are the reliable comparisons.
- Single-user benchmark: no concurrent application load during lifecycle jobs (concurrency is
  handled by design - freeze before capture, lock timeout - and tested functionally, not
  measured).
- Synthetic data: uniform customer distribution, payment status drawn per bill line, no
  corrections of old bills.
- 24 M rows: production volumes are larger; pruning and partition-level maintenance gains
  grow with volume, while DELETE-based retention grows linearly with it.
