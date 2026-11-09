# Live demonstration (5 minutes)

## Before the defense

```bash
docker start oracle19c                       # wait until (healthy)
scripts/reset.sh --yes && scripts/01_setup_db.sh \
  && scripts/02_create_schema.sh && scripts/03_load_data.sh   # ~6 min, fresh data
scripts/06_demo.sh 0                         # apply last month's policy (~4 min)
scripts/06_demo.sh 1                         # check everything answers
```

Steps 0, 4, 5 and 6 change the database (step 6's rejected inserts leave empty
partitions, removed by the next lifecycle run). Step 0 puts the database in a realistic state: the retention policy has been applied up to
last month (as of 2026-10). The live demo then shows the **routine monthly job** for
2026-11: 1 month purged, 1 month compressed, 1 month archived. Measured on the full dataset
(`results/demo/timings.txt`): step 0 4 min (before the defense), step 2 3 s, step 4 16 s,
step 5 46 s (validates 48 frozen months and refreshes statistics), other steps under 1 s.
Reload and re-run step 0 before a second rehearsal.

## Storyline

| Time | Step | Command | What to say / show |
|---|---|---|---|
| 0:00 | 1. Situation | `scripts/06_demo.sh 1` | Tiers as of last month: 13 HOT partitions (2025-10 .. 2026-10), 24 WARM (compressed, read-only), archive, sizes; retention policy is data in `DLM_CONFIG` |
| 0:40 | 2. Business scenario | `scripts/06_demo.sh 2` | Finance month-end report: baseline = `TABLE ACCESS FULL` on 24 M rows; partitioned = `PARTITION RANGE SINGLE`, reads one month (Pstart/Pstop = interval number 73, not the position). Compare timings |
| 1:40 | 3. Dry run | `scripts/06_demo.sh 3` | New month 2026-11: the job plans 1 purge (2021-10), 1 warm (2025-10), 1 archive (2023-10) - nothing changed yet |
| 2:10 | 4. Incident | `scripts/06_demo.sh 4` | Job crashes in the middle of archiving 2023-10: data waits in `BILLING_XCHG`, integrity check of that month flags it, re-run resumes, check passes, audit trail |
| 3:30 | 5. Monthly job | `scripts/06_demo.sh 5` | Guard refuses a 24-month purge; monthly run: 1 purge + 1 warm (2023-10 was already archived in step 4, so no archive row); validation of the frozen months (48/48); archived 2022 data still queryable via `BILLING_ALL`; new tier layout |
| 4:30 | 6. Security | `scripts/06_demo.sh 6` | Application can write the HOT window only: late insert in 2022 rejected (ORA-01402), no delete, no DDL, no access to archive or policy |

## Likely committee questions

| Question | Short answer | Where |
|---|---|---|
| Why monthly partitions? | Retention, reporting and billing cycle are monthly; ~330 k rows per partition | `docs/requirements.md` |
| Why a global PK index? | Single-probe lookup by `record_id`; cost = maintenance during move/exchange | `docs/architecture.md` §5 |
| What if the archive job crashes? | Two exchanges, data parked in `BILLING_XCHG`, resumable, tested (T12-T17) | `dlm_pkg.archive_partition` |
| Why is Q6 not faster? | No predicate on the partition key -> no pruning | `docs/results_analysis.md` |
| Licence? | Partitioning = EE option; BASIC compression included; no packs used | `docs/licensing.md` |
| Without the Partitioning option? | Partition view (one table per month + `UNION ALL`) | `docs/licensing.md` |
| How do you prove no data was lost? | Control totals (count, sum, row-hash sum) per month captured at load | `dlm_pkg.validate_integrity` |
| A late correction for an old month? | Rejected by the app window; owner must explicitly set the partition `READ WRITE` | `docs/architecture.md` §6 |
