"""End-to-end benchmark: baseline (heap + DELETE) vs partitioned lifecycle design.

Phases
  1. queries_before   workload Q1..Q7 on both designs, full 72-month history
  2. monthly_load     load two new months (Nov, Dec 2026) + statistics refresh
  3. lifecycle        purge / warm / archive every eligible month, per operation
  4. queries_after    workload again once retention has been applied
  5. space            segment sizes before and after, per table and tablespace
  6. integrity        both designs validated against load-time control totals

The run is DESTRUCTIVE (it applies the retention policy). To run it again:
  scripts/reset.sh --yes && scripts/01_setup_db.sh && scripts/02_create_schema.sh \
    && scripts/03_load_data.sh
Results are saved after every phase (results/raw/benchmark_partial.json), so a
failure late in the run does not lose the measurements already taken.

The workload dates, the two loaded months (2026-11, 2026-12) and the policy
windows assume the default calendar of .env.example (DATA_START_MONTH=2020-11,
DATA_MONTHS=72, AS_OF_MONTH=2026-11) and policy 12/36/60; the run refuses to
start otherwise. Dataset scale (ROWS_PER_MONTH, CUSTOMERS) is free.

Usage:  python -m bench.run_benchmark [--runs 5]
"""
import argparse
import json
import os
import platform
import shutil
import statistics
from datetime import datetime
from pathlib import Path

import oracledb

from bench.db import Meter, connect
from bench.workload import HISTORY_TARGETS, QUERIES, TARGETS

ROOT = Path(__file__).resolve().parents[2]
RESULTS = ROOT / "results"
PLANS = RESULTS / "plans"


def log(msg: str) -> None:
    print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


def summarize(samples: list[dict]) -> dict:
    """Median of every metric over the measured runs."""
    keys = samples[0].keys()
    return {k: statistics.median(s[k] for s in samples) for k in keys}


# --------------------------------------------------------------------------- queries
def run_queries(meter: Meter, phase: str, runs: int, recent_id: int, customer: int) -> list[dict]:
    out = []
    (PLANS / phase).mkdir(parents=True, exist_ok=True)
    for q in QUERIES:
        binds = dict(q["binds"])
        if "rid" in binds:
            binds["rid"] = recent_id
        if "cust" in binds:
            binds["cust"] = customer
        targets = HISTORY_TARGETS[phase] if q.get("history") else TARGETS[phase]
        for design, table in targets.items():
            sql = q["sql"].format(t=table)
            meter.query(sql, binds)                       # warm-up (parse, cache)
            samples, rows, sql_ref = [], None, None
            for _ in range(runs):
                metrics, rows, sql_ref = meter.query(sql, binds)
                samples.append(metrics)
            plan = meter.plan(*sql_ref)
            (PLANS / phase / f"{q['id']}_{design}.txt").write_text(
                f"-- {q['id']} {q['name']} | {design} | {table}\n{sql}\n\n{plan}\n")
            med = summarize(samples)
            out.append({"phase": phase, "query": q["id"], "name": q["name"],
                        "design": design, "table": table, "rows": rows,
                        "runs": runs, **med,
                        "elapsed_all": [s["elapsed_s"] for s in samples]})
            log(f"  {phase} {q['id']} {design:<11} {med['elapsed_s']*1000:9.1f} ms "
                f"{med['logical_reads']:>10,.0f} LIO  rows={rows}")
    return out


# --------------------------------------------------------------------------- space
SPACE_SQL = """
select nvl(i.table_name, s.segment_name) table_name, s.tablespace_name,
       s.segment_type, round(sum(s.bytes) / 1048576, 1) mb
from   user_segments s
left   join user_indexes i on i.index_name = s.segment_name
where  nvl(i.table_name, s.segment_name) like 'BILLING%'
group  by nvl(i.table_name, s.segment_name), s.tablespace_name, s.segment_type
order  by 1, 2, 3"""


def space(conn) -> list[dict]:
    cur = conn.cursor()
    cur.execute(SPACE_SQL)
    cols = [c[0].lower() for c in cur.description]
    return [dict(zip(cols, r)) for r in cur]


# --------------------------------------------------------------------------- helpers
def scalar(conn, sql, binds=None):
    cur = conn.cursor()
    cur.execute(sql, binds or {})
    return cur.fetchone()[0]


def months(conn, table: str) -> list[datetime]:
    cur = conn.cursor()
    cur.execute("select partition_name from user_tab_partitions "
                "where table_name = :t and partition_name <> 'P_INITIAL'", t=table)
    names = [r[0] for r in cur]
    return sorted(scalar(conn, "select dlm_pkg.partition_month(:t, :p) from dual",
                         {"t": table, "p": n}) for n in names)


def add_months(d: datetime, n: int) -> datetime:
    y, m = divmod(d.month - 1 + n, 12)
    return datetime(d.year + y, m + 1, 1)


# --------------------------------------------------------------------------- phases
def monthly_load(conn, meter: Meter) -> list[dict]:
    """Load two new months (Nov and Dec 2026) into both designs; refresh statistics
    after each load.

    The first gather after the migration re-analyses several partitions while the
    incremental synopses settle (one-time cost, recorded as GATHER_STATS_FIRST).
    The second one is the routine monthly situation (GATHER_STATS).
    """
    avg = int(os.environ.get("ROWS_PER_MONTH", "330000"))
    rows = round(avg * 1.3)
    cur = conn.cursor()
    out = []
    for new_month, stats_label in ((datetime(2026, 11, 1), "GATHER_STATS_FIRST"),
                                   (datetime(2026, 12, 1), "GATHER_STATS")):
        first_id = scalar(conn, "select max(record_id) from billing_records_base")
        log(f"Preparing {rows:,} rows for {new_month:%Y-%m} in BILLING_LOAD_STAGE (untimed)")
        cur.execute("truncate table billing_load_stage")
        cur.callproc("generate_billing_month",
                     ["BILLING_LOAD_STAGE", new_month, rows, first_id, new_month])
        conn.commit()

        for design, table in (("baseline", "BILLING_RECORDS_BASE"),
                              ("partitioned", "BILLING_RECORDS")):
            m = meter.execute(f"insert /*+ append */ into {table} select * from billing_load_stage")
            out.append({"operation": "LOAD_MONTH", "design": design,
                        "target": f"{new_month:%Y-%m}", **m})
            log(f"  load {new_month:%Y-%m} {design:<11} {m['elapsed_s']:7.2f} s  "
                f"redo={m['redo_bytes']/1e6:8.1f} MB")

        cur.callproc("dlm_pkg.rename_partitions", ["BILLING_RECORDS"])
        cur.callproc("dlm_pkg.capture_control_totals", ["BILLING_LOAD_STAGE"])
        cur.execute("truncate table billing_load_stage")

        for design, table in (("baseline", "BILLING_RECORDS_BASE"),
                              ("partitioned", "BILLING_RECORDS")):
            m = meter.call("dbms_stats.gather_table_stats", ["TELCO_OWNER", table])
            m["partitions_analysed"] = scalar(
                conn, "select count(*) from user_tab_partitions where table_name = :t "
                      "and last_analyzed >= sysdate - :s / 86400",
                {"t": table, "s": m["elapsed_s"] + 1})
            out.append({"operation": stats_label, "design": design, "target": table, **m})
            log(f"  {stats_label:<18} {design:<11} {m['elapsed_s']:7.2f} s  "
                f"LIO={m['logical_reads']:,}  partitions re-analysed={m['partitions_analysed']}")
    return out


def lifecycle_partitioned(conn, meter: Meter, out: list, save) -> None:
    """Apply the policy month by month, in steady-state order.

    In normal operation a month past retention has already been archived for
    two years, so it is purged from BILLING_ARCHIVE. To measure that situation
    the oldest months are warmed and archived first, then purged from the
    archive. Each operation is appended to `out` and saved immediately.
    """
    as_of = datetime(2026, 11, 1)
    hot_cut, online_cut, purge_cut = add_months(as_of, -12), add_months(as_of, -36), add_months(as_of, -60)
    run_id = scalar(conn, "select dlm_run_seq.nextval from dual")
    all_months = months(conn, "BILLING_RECORDS")

    def op(name, proc, month):
        m = meter.call(proc, [month, run_id])
        out.append({"operation": name, "design": "partitioned", "target": f"{month:%Y-%m}", **m})
        save()

    log("Partitioned lifecycle: WARM (freeze + move + compress)")
    for mth in [x for x in all_months if x < hot_cut]:
        op("WARM", "dlm_pkg.warm_partition", mth)
    log("Partitioned lifecycle: ARCHIVE (double partition exchange)")
    for mth in [x for x in all_months if x < online_cut]:
        op("ARCHIVE", "dlm_pkg.archive_partition", mth)
    log("Partitioned lifecycle: PURGE (drop archive partition)")
    for mth in [x for x in all_months if x < purge_cut]:
        op("PURGE", "dlm_pkg.purge_partition", mth)

    for table in ("BILLING_RECORDS", "BILLING_ARCHIVE"):
        m = meter.call("dbms_stats.gather_table_stats", ["TELCO_OWNER", table])
        out.append({"operation": "STATS_AFTER_LIFECYCLE", "design": "partitioned", "target": table, **m})
        save()


def lifecycle_baseline(conn, meter: Meter, out: list, save) -> None:
    """Same order for the baseline: archive (INSERT SELECT + DELETE) every month
    past the online window, then purge (DELETE) the expired ones from the
    baseline archive table."""
    as_of = datetime(2026, 11, 1)
    online_cut, purge_cut = add_months(as_of, -36), add_months(as_of, -60)
    run_id = scalar(conn, "select dlm_run_seq.nextval from dual")
    cur = conn.cursor()
    cur.execute("select trunc(bill_date, 'MM') m from billing_records_base "
                "where bill_date < :c group by trunc(bill_date, 'MM') order by 1", c=online_cut)
    old_months = [r[0] for r in cur]

    log("Baseline lifecycle: ARCHIVE (INSERT SELECT + DELETE)")
    for mth in old_months:
        m = meter.call("baseline_pkg.archive_month", [mth, run_id])
        out.append({"operation": "ARCHIVE", "design": "baseline", "target": f"{mth:%Y-%m}", **m})
        save()
        log(f"  archive {mth:%Y-%m} {m['elapsed_s']:6.2f} s")
    log("Baseline lifecycle: PURGE (DELETE from the archive)")
    for mth in [x for x in old_months if x < purge_cut]:
        m = meter.call("baseline_pkg.purge_month", [mth, run_id])
        out.append({"operation": "PURGE", "design": "baseline", "target": f"{mth:%Y-%m}", **m})
        save()
    for table in ("BILLING_RECORDS_BASE", "BILLING_ARCHIVE_BASE"):
        m = meter.call("dbms_stats.gather_table_stats", ["TELCO_OWNER", table])
        out.append({"operation": "STATS_AFTER_LIFECYCLE", "design": "baseline", "target": table, **m})
        save()


def integrity(conn) -> list[dict]:
    out = []
    for design, view in (("baseline", "BILLING_ALL_BASE"), ("partitioned", "BILLING_ALL")):
        cur = conn.cursor()
        bad = cur.callfunc("dlm_pkg.validate_integrity", int, [view])
        months_checked = scalar(conn, "select count(*) from billing_control_totals "
                                      "where month_start >= add_months(dlm_pkg.as_of_month, -60)")
        out.append({"design": design, "view": view, "months_checked": months_checked,
                    "months_in_error": bad})
        log(f"  integrity {design:<11} {months_checked - bad}/{months_checked} months match")
    return out


# --------------------------------------------------------------------------- main
def checkpoint(result: dict) -> None:
    """Save what has been measured so far (git-ignored)."""
    raw = RESULTS / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    (raw / "benchmark_partial.json").write_text(json.dumps(result, indent=2, default=str))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=5, help="measured runs per query (>= 1)")
    args = ap.parse_args()
    if args.runs < 1:
        ap.error("--runs must be >= 1")

    conn = connect()
    meter = Meter(conn)
    if scalar(conn, "select count(*) from user_tab_partitions "
                    "where table_name = 'BILLING_ARCHIVE' and partition_name <> 'P_INITIAL'"):
        raise SystemExit("The retention policy has already been applied to this dataset. "
                         "Reload it first: scripts/reset.sh --yes && scripts/01_setup_db.sh "
                         "&& scripts/02_create_schema.sh && scripts/03_load_data.sh")
    calendar = (scalar(conn, "select dlm_pkg.get_param('AS_OF_MONTH') from dual"),
                scalar(conn, "select count(*) from billing_control_totals"),
                scalar(conn, "select to_char(min(month_start), 'YYYY-MM') from billing_control_totals"),
                scalar(conn, "select dlm_pkg.get_param('HOT_MONTHS') || '/' || "
                             "dlm_pkg.get_param('ONLINE_MONTHS') || '/' || "
                             "dlm_pkg.get_param('RETENTION_MONTHS') from dual"))
    if calendar[0] != "2026-11" or calendar[2:] != ("2020-11", "12/36/60"):
        raise SystemExit(f"Benchmark needs the default calendar and policy, found {calendar}")
    if calendar[1] != 72 or scalar(conn, "select count(*) from billing_records_base "
                                         "where bill_date >= date '2026-11-01'"):
        raise SystemExit("This dataset was already modified by a previous (interrupted) "
                         "benchmark run. Reload it first: scripts/reset.sh --yes && "
                         "scripts/01_setup_db.sh && scripts/02_create_schema.sh && "
                         "scripts/03_load_data.sh")
    started = datetime.now()
    result = {
        "meta": {
            "started": started.isoformat(timespec="seconds"),
            "db_version": conn.version,
            "client": f"python-oracledb {oracledb.__version__} / {platform.python_version()}",
            "runs_per_query": args.runs,
            "rows_per_month_avg": int(os.environ.get("ROWS_PER_MONTH", "330000")),
            "total_rows_initial": scalar(conn, "select sum(row_count) from billing_control_totals"),
        }
    }
    recent_id = scalar(conn, "select max(record_id) - 5000 from billing_records_base")
    customers = scalar(conn, "select count(*) from customers")
    q2_customer = 123457 if customers >= 123457 else customers // 2
    shutil.rmtree(PLANS, ignore_errors=True)   # plans of this run only

    log("Space snapshot (before)")
    result["space_before"] = space(conn)
    checkpoint(result)

    log("Phase 1 - queries before lifecycle")
    result["queries_before"] = run_queries(meter, "before", args.runs, recent_id, q2_customer)
    checkpoint(result)

    log("Phase 2 - monthly load + statistics")
    result["monthly_load"] = monthly_load(conn, meter)
    checkpoint(result)

    result["lifecycle"] = []
    log("Phase 3 - lifecycle (partitioned design)")
    lifecycle_partitioned(conn, meter, result["lifecycle"], lambda: checkpoint(result))
    log("Phase 3 - lifecycle (baseline design)")
    lifecycle_baseline(conn, meter, result["lifecycle"], lambda: checkpoint(result))

    log("Phase 4 - queries after lifecycle")
    result["queries_after"] = run_queries(meter, "after", args.runs, recent_id, q2_customer)
    checkpoint(result)

    log("Phase 5 - space snapshot (after)")
    result["space_after"] = space(conn)
    checkpoint(result)

    log("Phase 6 - integrity validation")
    result["integrity"] = integrity(conn)

    result["meta"]["finished"] = datetime.now().isoformat(timespec="seconds")
    RESULTS.mkdir(exist_ok=True)
    out = RESULTS / "benchmark_results.json"
    out.write_text(json.dumps(result, indent=2, default=str))
    log(f"Results written to {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
