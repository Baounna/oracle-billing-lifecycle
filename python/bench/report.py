"""Turn results/benchmark_results.json into charts and a Markdown summary.

Usage:  python -m bench.report
Outputs:
  results/summary.md
  results/charts/*.png
"""
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
RESULTS = ROOT / "results"
CHARTS = RESULTS / "charts"

COLORS = {"baseline": "#9aa5b1", "partitioned": "#1f6f8b"}


def load() -> dict:
    return json.loads((RESULTS / "benchmark_results.json").read_text())


def ratio(a: float, b: float) -> str:
    if not b:
        return "n/a"
    r = a / b
    return f"{r:,.0f}x" if r >= 10 else f"{r:,.1f}x"


# --------------------------------------------------------------------------- tables
def query_table(df: pd.DataFrame, phase: str) -> str:
    d = df[df.phase == phase]
    lines = ["| Query | Description | Baseline ms | Partitioned ms | Speed-up | "
             "Baseline LIO | Partitioned LIO | LIO reduction |",
             "|---|---|---:|---:|---:|---:|---:|---:|"]
    for qid in sorted(d["query"].unique()):
        b = d[(d["query"] == qid) & (d.design == "baseline")].iloc[0]
        p = d[(d["query"] == qid) & (d.design == "partitioned")].iloc[0]
        lines.append(
            f"| {qid} | {b['name']} | {b.elapsed_s*1000:,.1f} | {p.elapsed_s*1000:,.1f} | "
            f"{ratio(b.elapsed_s, p.elapsed_s)} | {b.logical_reads:,.0f} | {p.logical_reads:,.0f} | "
            f"{ratio(b.logical_reads, p.logical_reads)} |")
    return "\n".join(lines)


def ops_table(ops: pd.DataFrame) -> str:
    g = (ops.groupby(["operation", "design"])
            .agg(count=("elapsed_s", "size"), total_s=("elapsed_s", "sum"),
                 avg_s=("elapsed_s", "mean"), redo_mb=("redo_bytes", lambda s: s.sum() / 1e6),
                 undo_mb=("undo_bytes", lambda s: s.sum() / 1e6))
            .reset_index())
    lines = ["| Operation | Design | # | Total s | Avg s / op | Redo MB | Undo MB |",
             "|---|---|---:|---:|---:|---:|---:|"]
    for _, r in g.iterrows():
        lines.append(f"| {r.operation} | {r.design} | {r['count']} | {r.total_s:,.1f} | "
                     f"{r.avg_s:,.2f} | {r.redo_mb:,.1f} | {r.undo_mb:,.1f} |")
    return "\n".join(lines)


BILLING_DATA = ["BILLING_RECORDS_BASE", "BILLING_ARCHIVE_BASE", "BILLING_RECORDS",
                "BILLING_ARCHIVE", "BILLING_XCHG"]


def space_table(before: pd.DataFrame, after: pd.DataFrame) -> str:
    b = before[before.table_name.isin(BILLING_DATA)].groupby("table_name").mb.sum()
    a = after[after.table_name.isin(BILLING_DATA)].groupby("table_name").mb.sum()
    s = pd.concat([b.rename("before"), a.rename("after")], axis=1).fillna(0)
    lines = ["| Table (incl. its indexes) | Before MB | After MB |", "|---|---:|---:|"]
    for name, r in s.iterrows():
        lines.append(f"| {name} | {r.before:,.0f} | {r.after:,.0f} |")
    return "\n".join(lines)


def monthly_job(ops: pd.DataFrame) -> pd.DataFrame:
    """Steady-state work per month for each design (one month through each step).
    baseline    = ARCHIVE (insert+delete) + PURGE (delete)
    partitioned = WARM (move+compress) + ARCHIVE (exchange) + PURGE (drop)
    """
    steps = {"baseline": ["ARCHIVE", "PURGE"], "partitioned": ["WARM", "ARCHIVE", "PURGE"]}
    rows = []
    for design, ops_list in steps.items():
        d = ops[(ops.design == design) & ops.operation.isin(ops_list)]
        means = d.groupby("operation")[["elapsed_s", "redo_bytes", "undo_bytes"]].mean()
        rows.append({"design": design, "steps": " + ".join(ops_list),
                     "elapsed_s": means.elapsed_s.sum(), "redo_bytes": means.redo_bytes.sum(),
                     "undo_bytes": means.undo_bytes.sum()})
    return pd.DataFrame(rows).set_index("design")


def monthly_job_table(ops: pd.DataFrame) -> str:
    j = monthly_job(ops)
    b, p = j.loc["baseline"], j.loc["partitioned"]
    return "\n".join([
        "| Design | Steps per month | Seconds | Redo MB | Undo MB |",
        "|---|---|---:|---:|---:|",
        f"| baseline | {b.steps} | {b.elapsed_s:,.2f} | {b.redo_bytes/1e6:,.1f} | {b.undo_bytes/1e6:,.1f} |",
        f"| partitioned | {p.steps} | {p.elapsed_s:,.2f} | {p.redo_bytes/1e6:,.1f} | {p.undo_bytes/1e6:,.1f} |",
        f"| **gain** | | **{ratio(b.elapsed_s, p.elapsed_s)}** | **{ratio(b.redo_bytes, p.redo_bytes)}** | "
        f"**{ratio(b.undo_bytes, p.undo_bytes)}** |"])


# --------------------------------------------------------------------------- charts
def bar_compare(df: pd.DataFrame, phase: str, metric: str, ylabel: str, fname: str, title: str):
    d = df[df.phase == phase].pivot(index="query", columns="design", values=metric)
    if metric == "elapsed_s":
        d = d * 1000
    ax = d[["baseline", "partitioned"]].plot.bar(
        color=[COLORS["baseline"], COLORS["partitioned"]], figsize=(9, 4.5), rot=0, width=0.75)
    ax.set_yscale("log")
    ax.set_ylabel(ylabel + " (log scale)")
    ax.set_xlabel("")
    ax.set_title(title)
    ax.grid(axis="y", alpha=0.3)
    ax.legend(title="", loc="upper center", bbox_to_anchor=(0.5, -0.07), ncol=2, frameon=False)
    plt.tight_layout()
    plt.savefig(CHARTS / fname, dpi=150)
    plt.close()


def ops_chart(ops: pd.DataFrame):
    order = ["LOAD_MONTH", "GATHER_STATS", "WARM", "ARCHIVE", "PURGE", "MONTHLY JOB"]
    d = ops[ops.operation.isin(order)]
    job = monthly_job(ops)
    for metric, scale, ylabel, fname, title in (
        ("elapsed_s", 1, "Seconds per operation", "maintenance_time.png",
         "Maintenance: time per operation (one month; GATHER_STATS = one refresh)"),
        ("redo_bytes", 1e6, "Redo MB per operation", "maintenance_redo.png",
         "Maintenance: redo per operation (one month; GATHER_STATS = one refresh)")):
        g = d.groupby(["operation", "design"])[metric].mean().unstack() / scale
        g.loc["MONTHLY JOB"] = job[metric] / scale
        g = g.reindex(order)[["baseline", "partitioned"]]
        ax = g.plot.bar(color=[COLORS["baseline"], COLORS["partitioned"]],
                        figsize=(10, 4.5), rot=0, width=0.75)
        ax.set_yscale("log")
        ax.set_ylabel(ylabel + " (log scale)")
        ax.set_xlabel("")
        ax.set_title(title)
        ax.grid(axis="y", alpha=0.3)
        ax.legend(title="", loc="upper center", bbox_to_anchor=(0.5, -0.07), ncol=2, frameon=False)
        plt.tight_layout()
        plt.savefig(CHARTS / fname, dpi=150)
        plt.close()


def space_chart(after: pd.DataFrame):
    d = after.copy()
    d = d[d.table_name.isin(BILLING_DATA)]
    d["design"] = d.table_name.map(lambda t: "baseline" if t.endswith("_BASE") else "partitioned")
    g = d.groupby(["design", "tablespace_name"]).mb.sum().unstack().fillna(0)
    ax = g.plot.bar(stacked=True, figsize=(7, 4.5), rot=0,
                    color=["#d1495b", "#edae49", "#00798c"][: len(g.columns)])
    ax.set_ylabel("MB")
    ax.set_xlabel("")
    ax.set_title("Storage after applying the retention policy")
    ax.grid(axis="y", alpha=0.3)
    plt.tight_layout()
    plt.savefig(CHARTS / "space_after.png", dpi=150)
    plt.close()


# --------------------------------------------------------------------------- main
def main() -> None:
    r = load()
    CHARTS.mkdir(parents=True, exist_ok=True)
    q = pd.DataFrame(r["queries_before"] + r["queries_after"])
    ops = pd.DataFrame(r["monthly_load"] + r["lifecycle"])
    sb, sa = pd.DataFrame(r["space_before"]), pd.DataFrame(r["space_after"])

    bar_compare(q, "before", "elapsed_s", "Median elapsed ms", "queries_before_time.png",
                "Query time - full history (72 months), before lifecycle")
    bar_compare(q, "before", "logical_reads", "Logical reads", "queries_before_lio.png",
                "Logical reads - full history, before lifecycle")
    bar_compare(q, "after", "elapsed_s", "Median elapsed ms", "queries_after_time.png",
                "Query time - after retention policy applied")
    ops_chart(ops)
    space_chart(sa)

    m = r["meta"]
    load_rows = int(ops[ops.operation == "LOAD_MONTH"]["rows"].mean())
    integ = "\n".join(f"| {i['design']} | {i['view']} | {i['months_checked']} | {i['months_in_error']} |"
                      for i in r["integrity"])
    md = f"""# Benchmark summary

Generated from `results/benchmark_results.json` by `python -m bench.report`.

- Run: {m['started']} -> {m['finished']}
- Database: Oracle {m['db_version']} (Docker, laptop) - client {m['client']}
- Initial history: {m['total_rows_initial']:,} billing records over 72 months
- Each query: 1 warm-up + {m['runs_per_query']} measured runs, **median** reported.
  LIO = logical reads (blocks read from the buffer cache) - the most stable metric.

## 1. Queries on the full history (before lifecycle)

{query_table(q, "before")}

![](charts/queries_before_time.png)
![](charts/queries_before_lio.png)

## 2. Queries after applying the retention policy

Baseline = DELETE-based retention on the heap table; partitioned = DLM package.
Q7 reads archived data through the unified views (`BILLING_ALL_BASE` / `BILLING_ALL`).

{query_table(q, "after")}

![](charts/queries_after_time.png)

## 3. Maintenance operations

{ops_table(ops)}

- `LOAD_MONTH`: direct-path load of one new month (2026-11 and 2026-12, ~{load_rows:,} rows each).
- `GATHER_STATS_FIRST`: first statistics refresh after the migration (one-time cost while
  incremental synopses settle). `GATHER_STATS`: routine refresh after the next monthly load.
- `PURGE` / `ARCHIVE` / `WARM`: one operation = one month. The partitioned ARCHIVE
  (exchange) relies on the month having been compressed by WARM first, so the fair
  steady-state comparison is the whole **monthly job** below.

### Monthly job (steady state: one month through every step)

{monthly_job_table(ops)}

![](charts/maintenance_time.png)
![](charts/maintenance_redo.png)

## 4. Storage

Sizes include each table's indexes (baseline archive: 2 indexes; partitioned archive:
1 local index), so differences combine compression and indexing choices.

{space_table(sb, sa)}

![](charts/space_after.png)

## 5. Data integrity

| Design | View checked | Months checked | Months in error |
|---|---|---:|---:|
{integ}
"""
    (RESULTS / "summary.md").write_text(md)
    print(f"Wrote {RESULTS / 'summary.md'} and charts in {CHARTS}")


if __name__ == "__main__":
    main()
