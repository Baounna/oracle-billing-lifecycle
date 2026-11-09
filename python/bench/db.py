"""Database connection and measurement helpers.

Every measured operation records:
  * elapsed wall-clock time (client side)
  * session statistic deltas from V$MYSTAT: logical reads, physical reads,
    redo generated, undo generated, CPU time
Logical reads are the most stable indicator (independent of caching and of
other activity on the laptop), so results quote both time and logical reads.
"""
import os
import time

import oracledb

# V$STATNAME name -> key used in the results
STATS = {
    "session logical reads": "logical_reads",
    "physical reads": "physical_reads",
    "redo size": "redo_bytes",
    "undo change vector size": "undo_bytes",
    "CPU used by this session": "cpu_cs",
}


def connect() -> oracledb.Connection:
    """Connect as TELCO_OWNER with credentials taken from the environment (.env)."""
    dsn = oracledb.makedsn(
        os.environ.get("ORACLE_HOST", "host.docker.internal"),
        int(os.environ.get("ORACLE_PORT", "1521")),
        service_name=os.environ["ORACLE_PDB_SERVICE"],
    )
    conn = oracledb.connect(user="TELCO_OWNER",
                            password=os.environ["TELCO_OWNER_PASSWORD"], dsn=dsn)
    conn.call_timeout = 0
    return conn


class Meter:
    """Measures a callable and returns elapsed time + session statistic deltas."""

    def __init__(self, conn: oracledb.Connection):
        self.conn = conn
        self.cur = conn.cursor()
        names = list(STATS)
        placeholders = ", ".join(f":{i + 1}" for i in range(len(names)))
        self._names = names
        self._stat_sql = (
            "select n.name, m.value from v$mystat m "
            "join v$statname n on n.statistic# = m.statistic# "
            f"where n.name in ({placeholders})"
        )

    def _snapshot(self) -> dict:
        self.cur.execute(self._stat_sql, self._names)
        return {STATS[name]: value for name, value in self.cur}

    def _last_sql(self):
        self.cur.execute(
            "select prev_sql_id, prev_child_number from v$session "
            "where sid = sys_context('userenv', 'sid')")
        return self.cur.fetchone()

    def measure(self, fn):
        """Run fn(); return (metrics, fn_result, (sql_id, child_number)).

        The V$SESSION lookup that identifies the cursor runs inside the measured
        window; fixed views cost no logical reads, so it does not bias LIO.
        Elapsed time is client-side (includes fetch round-trips), so sub-ms
        queries (Q2, Q5) are dominated by network/driver noise.
        """
        before = self._snapshot()
        t0 = time.perf_counter()
        result = fn()
        elapsed = time.perf_counter() - t0
        sql = self._last_sql()
        after = self._snapshot()
        metrics = {key: after[key] - before[key] for key in before}
        metrics["elapsed_s"] = round(elapsed, 4)
        return metrics, result, sql

    def plan(self, sql_id: str, child: int) -> str:
        self.cur.execute(
            "select plan_table_output from "
            "table(dbms_xplan.display_cursor(:1, :2, 'TYPICAL -BYTES'))",
            [sql_id, child])
        return "\n".join(row[0] for row in self.cur)

    # ---- convenience wrappers -------------------------------------------
    def query(self, sql: str, binds: dict):
        def run():
            cur = self.conn.cursor()
            cur.arraysize = 1000
            cur.execute(sql, binds)
            return len(cur.fetchall())
        return self.measure(run)

    def call(self, proc: str, args=None, kwargs=None):
        def run():
            cur = self.conn.cursor()
            cur.callproc(proc, args or [], kwargs or {})
        metrics, _, _ = self.measure(run)
        return metrics

    def execute(self, sql: str, binds=None, commit: bool = True):
        def run():
            cur = self.conn.cursor()
            cur.execute(sql, binds or {})
            rows = cur.rowcount
            if commit:
                self.conn.commit()
            return rows
        metrics, rows, _ = self.measure(run)
        metrics["rows"] = rows
        return metrics
