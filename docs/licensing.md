# Licensing and technical trade-offs

## Oracle features used

| Feature | Edition / option | Used for | Production licence impact |
|---|---|---|---|
| Range-interval partitioning, partition exchange, read-only partitions, `MOVE PARTITION` | **Partitioning option** (Enterprise Edition, extra cost) | Monthly partitions, zero-copy archiving, metadata purge | Requires EE + Partitioning licences |
| `ROW STORE COMPRESS BASIC` | Included in Enterprise Edition | Compressing warm/archive partitions | None beyond EE |
| Incremental statistics (`INCREMENTAL=TRUE`) | Included in EE | Stats refresh after monthly load | None |
| `DBMS_XPLAN.DISPLAY_CURSOR`, `V$MYSTAT`, `V$SQL` | Base product | Benchmark measurements | None |
| AWR, ASH, SQL Monitor, SQL Tuning Advisor | Diagnostics / Tuning Packs | **Not used on purpose** | - |
| Advanced Row Compression (`ROW STORE COMPRESS ADVANCED`) | Advanced Compression option | **Not used on purpose** | - |

The lab database is Oracle 19c EE in Docker, used for development and education under the
Oracle Technology Network licence. `control_management_pack_access` is set to
`DIAGNOSTIC+TUNING` in this container, but the project deliberately relies only on
base-product views so that the measurement method stays valid on a licence that does not
include the packs.

## Alternative without the Partitioning option

On Standard Edition 2 (or EE without the Partitioning option) the same lifecycle can be
approximated with a **partition view**:

- one heap table per month (`BILLING_2026_10`, ...) with a `CHECK (bill_date >= ... and < ...)`
- a `UNION ALL` view over the monthly tables; the optimizer skips tables whose check
  constraint contradicts the predicate (similar effect to pruning, less robust)
- archiving = `ALTER TABLE ... MOVE TABLESPACE` (plus `COMPRESS` only on EE: basic table
  compression is not available in SE2) + re-create the view; purge = `DROP TABLE`

Costs: application must insert into the right monthly table (or through an
`INSTEAD OF` trigger), views must be regenerated every month, no global index across
months, and the optimizer behaviour with bind variables is less predictable.
This is why the partitioned design was chosen for this client (EE already licensed).

## Technical trade-offs of the chosen design

| Decision | Benefit | Cost / risk |
|---|---|---|
| Monthly interval partitions | Pruning for date queries, partition-level maintenance, no "add partition" job | Queries without a date filter still scan all partitions (Q6) |
| Global PK on `record_id` | Single-probe lookup (Q5) | Must be maintained on MOVE / EXCHANGE (`UPDATE GLOBAL INDEXES`) - the main cost of warm/archive |
| Local `(customer_id, bill_date)` index | Maintained with each partition, small segments | Customer query over many months probes several index partitions |
| BASIC compression on warm/archive | Less storage, fewer blocks to read for history | Conventional DML on compressed blocks is inefficient -> partitions made read-only |
| Read-only warm/archive partitions | History cannot be altered (integrity, audit) | Late corrections to old bills need an explicit `READ WRITE` step by the owner |
| Separate `BILLING_ARCHIVE` table | Online table holds only 36 months; archive can live on cheaper storage | Queries over all history must use `BILLING_ALL` (`UNION ALL`) |
| Deterministic synthetic data | Reproducible benchmarks | Real data distributions (skew, late arrivals) may differ |
