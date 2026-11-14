"""Web dashboard for the billing data lifecycle (Streamlit).

Shows the same steps as scripts/06_demo.sh, driven by buttons instead of
commands. Runs in the tools container:

    scripts/07_dashboard.sh            -> http://localhost:8501

Every action calls the real PL/SQL package (DLM_PKG) on the live database;
nothing is simulated in Python. Write actions are serialised by a lock so two
browser tabs cannot run lifecycle operations at the same time.
"""
import datetime as dt
import os
import re
import threading
import time
from pathlib import Path

import altair as alt
import oracledb
import pandas as pd
import streamlit as st

ROOT = Path(os.environ.get("PROJECT_ROOT", "/work"))
TIER_COLORS = {
    "HOT": "#e8590c",
    "WARM": "#f59f00",
    "ARCHIVE": "#1971c2",
    "STAGED": "#c2255c",
    "PURGED": "#ced4da",
}
TIER_TEXT = {
    "HOT": "last 12 months - read/write, uncompressed, TELCO_HOT",
    "WARM": "months 13-36 - compressed, read-only, TELCO_ARCH",
    "ARCHIVE": "months 37-60 - BILLING_ARCHIVE (exchange partition), compressed",
    "STAGED": "interrupted archive - rows wait in BILLING_XCHG",
    "PURGED": "older than the 60-month legal retention - dropped",
}

st.set_page_config(page_title="Billing Data Lifecycle", page_icon="🗄️",
                   layout="wide")

# =============================================================================
# Visual design: one CSS block + small HTML helpers. Offline only (no CDN, no
# web fonts); selectors use Streamlit data-testid attributes (stable across
# versions), never the generated st-emotion-cache-* classes.
# =============================================================================
CSS = """
<style>
/* ---- design tokens ------------------------------------------------------ */
:root {
  --accent: #1f4e79; --accent-2: #2b6cb0; --accent-soft: #e8f0f9;
  --bg: #f7f9fc; --surface: #ffffff; --border: #e3e8ef; --ink: #1d2733;
  --muted: #5b6878; --faint: #8a96a5;
  --ok: #2f9e44; --warn: #f08c00; --bad: #e03131;
  --r-card: 12px; --r-ctl: 8px;
  --shadow: 0 1px 2px rgba(16, 24, 40, .05), 0 4px 12px rgba(16, 24, 40, .06);
  --shadow-hover: 0 2px 4px rgba(16, 24, 40, .06), 0 10px 24px rgba(16, 24, 40, .10);
  --ease: cubic-bezier(.2, .7, .2, 1);
}

/* ---- base --------------------------------------------------------------- */
html, body, [data-testid="stApp"], button, input, textarea, select {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, Roboto, "Helvetica Neue",
               Arial, sans-serif !important;
}
[data-testid="stApp"], [data-testid="stAppViewContainer"], [data-testid="stMain"] {
  background: var(--bg); }
[data-testid="stMainBlockContainer"] { max-width: 1400px; padding-top: 3.4rem;
  padding-bottom: 4rem; }
[data-testid="stDecoration"] { display: none; }
[data-testid="stHeader"] { background: rgba(247, 249, 252, .85); backdrop-filter: blur(6px); }
[data-testid="stMain"] p, [data-testid="stMain"] li { font-size: 15.5px; line-height: 1.6;
  color: var(--ink); }
[data-testid="stCaptionContainer"] p { font-size: 13px !important; color: var(--muted) !important; }
[data-testid="stMetricValue"], .num, .kpi .v, .tiercard .v { font-variant-numeric: tabular-nums; }
code { color: var(--accent) !important; background: var(--accent-soft) !important;
  border-radius: 5px; padding: .1em .35em; }
[data-testid="stHeadingWithActionElements"] h2 { font-size: 28px !important; font-weight: 700 !important;
  color: var(--ink); letter-spacing: -.015em; padding-bottom: .2rem; }
[data-testid="stHeadingWithActionElements"] h3 { font-size: 18px !important; font-weight: 650 !important;
  color: var(--ink); display: flex; align-items: center; gap: 10px; }
[data-testid="stHeadingWithActionElements"] h3::before { content: ""; width: 4px; height: 18px;
  border-radius: 2px; background: linear-gradient(180deg, var(--accent-2), var(--accent)); }
[data-testid="stHeaderActionElements"] { display: none; }

/* ---- motion: content fades in and rises on page load ------------------- */
@keyframes rise { from { opacity: 0; transform: translateY(8px); }
                  to   { opacity: 1; transform: none; } }
[data-testid="stMainBlockContainer"] [data-testid="stElementContainer"],
[data-testid="stMainBlockContainer"] [data-testid="stHorizontalBlock"] {
  animation: rise .32s var(--ease) both; }

/* ---- header band ------------------------------------------------------- */
.hdr { position: relative; overflow: hidden; display: flex; align-items: center;
  justify-content: space-between; gap: 18px; color: #fff; border-radius: 14px;
  padding: 18px 24px; margin-bottom: 1.1rem;
  background:
    radial-gradient(circle at 92% -30%, rgba(255, 255, 255, .18) 0, transparent 38%),
    radial-gradient(circle at 70% 140%, rgba(120, 180, 255, .25) 0, transparent 45%),
    linear-gradient(110deg, #143656 0%, #1f4e79 50%, #2b6cb0 100%);
  box-shadow: 0 6px 20px rgba(20, 54, 86, .22); }
.hdr .brand { display: flex; align-items: center; gap: 14px; }
.hdr .logo { width: 44px; height: 44px; border-radius: 11px; display: grid; place-items: center;
  background: rgba(255, 255, 255, .14); border: 1px solid rgba(255, 255, 255, .25); }
.hdr .t { font-size: 20px; font-weight: 700; letter-spacing: -.01em; line-height: 1.2; }
.hdr .s { font-size: 13.5px; opacity: .82; margin-top: 3px; }
.hdr .badges { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
.pill { display: inline-flex; align-items: center; gap: 7px; padding: 6px 13px;
  border-radius: 999px; font-size: 13px; font-weight: 650; white-space: nowrap; }
.pill .dot { width: 8px; height: 8px; border-radius: 50%; background: currentColor;
  box-shadow: 0 0 0 3px rgba(255, 255, 255, .35); }
.pill.month { background: rgba(255, 255, 255, .14); color: #fff;
  border: 1px solid rgba(255, 255, 255, .3); }
.pill.FRESH { background: #fff4d6; color: #8a5a00; }
.pill.READY { background: #dcf7e3; color: #1d6b32; }
.pill.DONE  { background: #e3f0ff; color: #0b4a7a; }

/* ---- stepper ----------------------------------------------------------- */
.stepper { display: flex; align-items: center; margin: .2rem 0 1rem; }
.stepper .st { display: flex; align-items: center; gap: 8px; color: var(--faint);
  font-size: 13px; font-weight: 600; white-space: nowrap; }
.stepper .c { width: 26px; height: 26px; border-radius: 50%; display: grid; place-items: center;
  font-size: 12.5px; font-weight: 700; border: 2px solid #cfd8e3; background: #fff;
  color: var(--faint); transition: all .2s var(--ease); }
.stepper .st.done { color: var(--muted); }
.stepper .st.done .c { background: var(--accent-soft); border-color: var(--accent); color: var(--accent); }
.stepper .st.cur { color: var(--accent); }
.stepper .st.cur .c { background: linear-gradient(135deg, var(--accent-2), var(--accent));
  border-color: var(--accent); color: #fff; box-shadow: 0 0 0 4px rgba(43, 108, 176, .15); }
.stepper .ln { flex: 1; height: 2px; margin: 0 10px; min-width: 18px;
  background: #dbe2ea; border-radius: 1px; }
.stepper .ln.done { background: linear-gradient(90deg, var(--accent), var(--accent-2)); }

/* ---- callout ("what you will see") ------------------------------------ */
.callout { display: flex; gap: 12px; align-items: flex-start; background: var(--surface);
  border: 1px solid var(--border); border-left: 4px solid var(--accent-2);
  border-radius: 10px; padding: 12px 16px; margin: .2rem 0 1rem; box-shadow: var(--shadow);
  color: var(--ink); font-size: 15px; line-height: 1.55; }
.callout .ic { flex: none; width: 26px; height: 26px; border-radius: 8px; display: grid;
  place-items: center; background: var(--accent-soft); color: var(--accent); font-weight: 800; }

/* ---- KPI and tier cards ------------------------------------------------ */
.kpi, .tiercard, [data-testid="stMetric"] { background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--r-card); box-shadow: var(--shadow);
  transition: transform .18s var(--ease), box-shadow .18s var(--ease); }
.kpi:hover, .tiercard:hover, [data-testid="stMetric"]:hover { transform: translateY(-2px);
  box-shadow: var(--shadow-hover); }
.kpi { padding: 16px 18px; min-height: 128px; }
.kpi .top { display: flex; align-items: center; gap: 10px; color: var(--muted);
  font-size: 13px; font-weight: 650; }
.kpi .chip { width: 30px; height: 30px; border-radius: 9px; display: grid; place-items: center;
  background: var(--chip-bg); color: var(--chip); }
.kpi .v { font-size: 30px; font-weight: 750; color: var(--ink); margin: 8px 0 2px;
  letter-spacing: -.02em; }
.kpi .sub { font-size: 13px; color: var(--muted); }
.ratio { display: flex; height: 8px; border-radius: 99px; overflow: hidden; margin-top: 10px;
  background: #edf1f6; }
.ratio span { display: block; height: 100%; }
.tiercard { overflow: hidden; padding: 0; min-height: 178px; }
.tiercard .tint { height: 6px; background: linear-gradient(90deg, var(--c), color-mix(in srgb, var(--c) 45%, white)); }
.tiercard .body { padding: 12px 16px 14px;
  background: linear-gradient(180deg, color-mix(in srgb, var(--c) 7%, white) 0, #fff 60px); }
.tiercard .n { font-size: 12px; font-weight: 800; letter-spacing: .09em; color: var(--tc); }
.tiercard .v { font-size: 28px; font-weight: 750; color: var(--ink); margin-top: 4px;
  letter-spacing: -.02em; }
.tiercard .v small { font-size: 14px; font-weight: 600; color: var(--muted); margin-left: 4px; }
.tiercard .r { font-size: 13.5px; color: var(--muted); }
.tiercard .bar { height: 5px; border-radius: 99px; background: #edf1f6; margin: 10px 0 8px; }
.tiercard .bar span { display: block; height: 100%; border-radius: 99px; background: var(--c); }
.tiercard .d { font-size: 12.5px; color: var(--muted); line-height: 1.4; }
[data-testid="stMetric"] { padding: 14px 18px; }
[data-testid="stMetricLabel"] p { color: var(--muted) !important; font-size: 13px !important;
  font-weight: 650 !important; }
[data-testid="stMetricValue"] { font-size: 28px !important; color: var(--ink); font-weight: 750;
  letter-spacing: -.02em; }

/* ---- comparison (Business query) -------------------------------------- */
.win { display: flex; gap: 14px; flex-wrap: wrap; align-items: stretch; margin: .3rem 0 .6rem; }
.win .big { flex: none; min-width: 200px; display: flex; flex-direction: column;
  justify-content: center; border-radius: var(--r-card); padding: 16px 20px; color: #fff;
  background: linear-gradient(135deg, #2f9e44, #237a35); box-shadow: 0 6px 18px rgba(47, 158, 68, .25); }
.win .big .x { font-size: 44px; font-weight: 800; line-height: 1; letter-spacing: -.03em; }
.win .big .l { font-size: 13.5px; opacity: .92; margin-top: 6px; }
.win .big.blue { background: linear-gradient(135deg, #2b6cb0, #1f4e79);
  box-shadow: 0 6px 18px rgba(31, 78, 121, .25); }
.cmp { flex: 1; min-width: 320px; background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--r-card); padding: 14px 18px; box-shadow: var(--shadow); }
.cmp .row { display: grid; grid-template-columns: 120px 1fr 110px; align-items: center; gap: 12px;
  margin: 8px 0; font-size: 13.5px; }
.cmp .lbl { color: var(--muted); font-weight: 650; }
.cmp .trk { height: 14px; background: #edf1f6; border-radius: 99px; overflow: hidden; }
.cmp .trk span { display: block; height: 100%; border-radius: 99px;
  animation: grow .7s var(--ease) both; transform-origin: left; }
.cmp .val { text-align: right; font-weight: 700; color: var(--ink); font-variant-numeric: tabular-nums; }
.cmp .ttl { font-size: 13px; font-weight: 700; color: var(--ink); }
@keyframes grow { from { transform: scaleX(0); } to { transform: scaleX(1); } }

/* ---- incident timeline ------------------------------------------------- */
.tl { display: flex; align-items: center; background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--r-card); padding: 14px 20px; box-shadow: var(--shadow); margin: .4rem 0 .8rem; }
.tl .ev { display: flex; align-items: center; gap: 10px; color: var(--faint); font-weight: 650;
  font-size: 14px; }
.tl .ev .c { width: 30px; height: 30px; border-radius: 50%; display: grid; place-items: center;
  border: 2px solid #d5dde6; background: #fff; transition: all .25s var(--ease); }
.tl .ev small { display: block; font-weight: 500; font-size: 12px; color: var(--faint); }
.tl .ev.on { color: var(--ink); }
.tl .ev.on .c { color: #fff; border-color: var(--k); background: var(--k);
  box-shadow: 0 0 0 4px color-mix(in srgb, var(--k) 18%, transparent); }
.tl .ln { flex: 1; height: 3px; margin: 0 14px; border-radius: 2px; background: #e2e8ef; }
.tl .ln.on { background: linear-gradient(90deg, var(--k1), var(--k2)); }

/* ---- sidebar ------------------------------------------------------------ */
[data-testid="stSidebar"] { background: linear-gradient(180deg, #eef3f9 0%, #f4f7fb 100%);
  border-right: 1px solid var(--border); }
[data-testid="stSidebarUserContent"] { padding-top: .6rem; }
.sb-logo { display: flex; align-items: center; gap: 11px; margin-bottom: 14px; }
.sb-logo .mk { width: 40px; height: 40px; border-radius: 11px; display: grid; place-items: center;
  background: linear-gradient(135deg, var(--accent-2), var(--accent));
  box-shadow: 0 4px 12px rgba(31, 78, 121, .3); }
.sb-logo .t { font-size: 16px; font-weight: 800; color: var(--ink); line-height: 1.15; }
.sb-logo .s { font-size: 12px; color: var(--muted); }
.sb-status { display: flex; gap: 10px; align-items: flex-start; background: #fff;
  border: 1px solid var(--border); border-radius: 10px; padding: 10px 12px; margin-bottom: 14px;
  box-shadow: var(--shadow); font-size: 12.5px; line-height: 1.45; color: var(--muted); }
.sb-status b { display: block; font-size: 13px; color: var(--ink); }
.sb-status .dot { flex: none; width: 10px; height: 10px; border-radius: 50%; margin-top: 4px;
  background: var(--k); box-shadow: 0 0 0 4px color-mix(in srgb, var(--k) 20%, transparent); }
.sb-h { font-size: 11px; font-weight: 800; letter-spacing: .1em; color: var(--faint);
  margin: 4px 0 6px 4px; }
[data-testid="stSidebar"] [role="radiogroup"] { gap: 3px; }
[data-testid="stSidebar"] [role="radiogroup"] label { width: 100%; padding: .55rem .75rem;
  border-radius: 10px; margin: 0; transition: background .15s var(--ease), box-shadow .15s var(--ease); }
[data-testid="stSidebar"] [role="radiogroup"] label > div:first-child { display: none; }
[data-testid="stSidebar"] [role="radiogroup"] label p { font-size: 14.5px; color: #34404f;
  display: flex; align-items: center; gap: 8px; }
[data-testid="stSidebar"] [role="radiogroup"] label:hover { background: rgba(255, 255, 255, .9); }
[data-testid="stSidebar"] [role="radiogroup"] label:has(input:checked) {
  background: linear-gradient(135deg, var(--accent-2), var(--accent));
  box-shadow: 0 4px 12px rgba(31, 78, 121, .28); }
[data-testid="stSidebar"] [role="radiogroup"] label:has(input:checked) p { color: #fff;
  font-weight: 650; }
[data-testid="stSidebar"] [role="radiogroup"] label:has(input:checked) p span { color: #fff !important; }

/* ---- buttons ------------------------------------------------------------ */
[data-testid="stBaseButton-primary"], [data-testid="stBaseButton-secondary"] {
  border-radius: var(--r-ctl) !important; font-weight: 650 !important; padding: .5rem 1.05rem !important;
  transition: transform .12s var(--ease), box-shadow .15s var(--ease), filter .15s,
              background .15s, border-color .15s !important; }
[data-testid="stBaseButton-primary"], [data-testid="stBaseButton-primary"] p,
[data-testid="stBaseButton-primary"] span { color: #fff !important; }
[data-testid="stBaseButton-primary"] { border: none !important;
  background: linear-gradient(135deg, var(--accent-2), var(--accent)) !important;
  box-shadow: 0 3px 10px rgba(31, 78, 121, .28); }
[data-testid="stBaseButton-primary"]:hover { filter: brightness(1.08);
  box-shadow: 0 6px 16px rgba(31, 78, 121, .32); }
[data-testid="stBaseButton-secondary"] { background: #fff !important;
  border: 1.5px solid #c9d6e4 !important; color: var(--accent) !important; }
[data-testid="stBaseButton-secondary"]:hover { border-color: var(--accent-2) !important;
  background: var(--accent-soft) !important; }
[data-testid="stBaseButton-primary"]:active, [data-testid="stBaseButton-secondary"]:active {
  transform: scale(.98); }
[data-testid="stBaseButton-primary"]:disabled, [data-testid="stBaseButton-secondary"]:disabled {
  filter: grayscale(1); opacity: .45; box-shadow: none !important; }

/* ---- code, tables, alerts, expanders ----------------------------------- */
[data-testid="stCode"] pre { background: #fbfcfe !important; border: 1px solid var(--border);
  border-radius: 10px; }
[data-testid="stCode"] code { background: transparent !important; font-size: 12.8px !important;
  line-height: 1.5; }
[data-testid="stDataFrame"] { border: 1px solid var(--border); border-radius: 10px;
  box-shadow: var(--shadow); background: #fff; overflow: hidden; }
[data-testid="stAlert"] > div { border-radius: 10px; }
[data-testid="stExpander"] details { border-radius: 10px !important; border-color: var(--border) !important;
  background: #fff; box-shadow: var(--shadow); transition: box-shadow .18s var(--ease); }
[data-testid="stExpander"] details:hover { box-shadow: var(--shadow-hover); }
[data-testid="stVegaLiteChart"] { background: #fff; border: 1px solid var(--border);
  border-radius: var(--r-card); box-shadow: var(--shadow); overflow: hidden; }
[data-testid="stImage"] img, [data-testid="stFullScreenFrame"] img { border-radius: 10px; }
[data-testid="stSelectbox"] div[data-baseweb="select"] > div { border-radius: var(--r-ctl);
  background: #fff; border-color: #d5dee8; }

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation: none !important; transition: none !important; }
}
</style>
"""

STATE_TEXT = {"FRESH": "Fresh load", "READY": "Ready for demo", "DONE": "Monthly job done"}
STATE_COLOR = {"FRESH": "#f08c00", "READY": "#2f9e44", "DONE": "#2b6cb0"}

# inline SVG icons (stroke = currentColor)
_SVG = '<svg width="{s}" height="{s}" viewBox="0 0 24 24" fill="none" stroke="{c}" ' \
       'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{p}</svg>'
ICONS = {
    "db": '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v6c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/>'
          '<path d="M4 11v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6"/>',
    "layers": '<path d="M12 3 2 8l10 5 10-5-10-5z"/><path d="m2 16 10 5 10-5"/><path d="m2 12 10 5 10-5"/>',
    "archive": '<rect x="3" y="4" width="18" height="4" rx="1"/><path d="M5 8v11h14V8"/><path d="M10 12h4"/>',
    "disk": '<path d="M21 12H3"/><path d="M5.5 5h13L21 12v6a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1v-6z"/>'
            '<path d="M7 16h.01M11 16h.01"/>',
    "check": '<path d="M20 6 9 17l-5-5"/>',
    "shield": '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9 12 2 2 4-4"/>',
    "bolt": '<path d="M13 2 3 14h9l-1 8 10-12h-9l1-8z"/>',
    "search": '<circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/>',
    "heal": '<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8z"/>',
    "info": '<circle cx="12" cy="12" r="9"/><path d="M12 16v-4M12 8h.01"/>',
}


def icon(name: str, size: int = 18, color: str = "currentColor") -> str:
    return _SVG.format(s=size, c=color, p=ICONS[name])


def html(markup: str, where=st):
    where.markdown(markup, unsafe_allow_html=True)


def header_band(p, state):
    html(f'<div class="hdr"><div class="brand"><div class="logo">{icon("db", 24, "#fff")}</div>'
         f'<div><div class="t">Telecom Billing &middot; Data Lifecycle Management</div>'
         f'<div class="s">Oracle 19c &middot; interval partitioning &middot; compression '
         f'&middot; exchange-partition archive</div></div></div>'
         f'<div class="badges"><span class="pill month">Policy month {p["AS_OF_MONTH"]}</span>'
         f'<span class="pill {state}"><span class="dot"></span>{STATE_TEXT[state]}</span>'
         f'</div></div>')


STEPS = ["Business query", "Dry run", "Incident", "Monthly job", "Security"]


def stepper(current: int):
    parts = []
    for i, name in enumerate(STEPS, start=1):
        cls = "cur" if i == current else ("done" if i < current else "")
        mark = icon("check", 14) if i < current else str(i)
        if i > 1:
            parts.append(f'<div class="ln {"done" if i <= current else ""}"></div>')
        parts.append(f'<div class="st {cls}"><div class="c">{mark}</div>{name}</div>')
    html(f'<div class="stepper">{"".join(parts)}</div>')


def callout(text: str):
    html(f'<div class="callout"><div class="ic">{icon("info", 16)}</div><div>{text}</div></div>')


def kpi(where, title: str, value: str, sub: str, ic: str, color: str, extra: str = ""):
    # Streamlit strips CSS custom properties from style attributes: plain properties only
    html(f'<div class="kpi"><div class="top"><div class="chip" '
         f'style="background:{color}1f;color:{color}">{icon(ic, 17)}</div>{title}</div>'
         f'<div class="v">{value}</div><div class="sub">{sub}</div>{extra}</div>', where)


# --------------------------------------------------------------------------- db
def _dsn() -> str:
    return oracledb.makedsn(os.environ.get("ORACLE_HOST", "host.docker.internal"),
                            int(os.environ.get("ORACLE_PORT", "1521")),
                            service_name=os.environ["ORACLE_PDB_SERVICE"])


@st.cache_resource
def owner_pool() -> oracledb.ConnectionPool:
    return oracledb.create_pool(user="TELCO_OWNER",
                                password=os.environ["TELCO_OWNER_PASSWORD"],
                                dsn=_dsn(), min=1, max=4, increment=1)


@st.cache_resource
def write_lock() -> threading.Lock:
    return threading.Lock()


def q(sql: str, binds=None) -> pd.DataFrame:
    with owner_pool().acquire() as conn:
        cur = conn.cursor()
        cur.execute(sql, binds or {})
        cols = [c[0].lower() for c in cur.description]
        return pd.DataFrame(cur.fetchall(), columns=cols)


def scalar(sql: str, binds=None):
    with owner_pool().acquire() as conn:
        cur = conn.cursor()
        cur.execute(sql, binds or {})
        row = cur.fetchone()
        return row[0] if row else None


def plsql(block: str, binds=None):
    """Run a PL/SQL block as TELCO_OWNER. Returns (seconds, error message or None)."""
    t0 = time.perf_counter()
    try:
        with owner_pool().acquire() as conn:
            conn.call_timeout = 0
            conn.cursor().execute(block, binds or {})
            conn.commit()
        return time.perf_counter() - t0, None
    except oracledb.DatabaseError as exc:
        return time.perf_counter() - t0, str(exc.args[0].message).strip().splitlines()[0]


def run_write(label: str, block: str, binds=None):
    """Serialised write action with a spinner. Returns (seconds, error)."""
    lock = write_lock()
    if not lock.acquire(blocking=False):
        st.warning("Another lifecycle operation is running. Wait until it finishes.")
        return None, "busy"
    try:
        with st.spinner(f"{label} ..."):
            return plsql(block, binds)
    finally:
        lock.release()


def lit(d: dt.date) -> str:
    """Date literal for SQL text (used where plans must show the partition number)."""
    return f"date '{d:%Y-%m-%d}'"


def mlabel(d) -> str:
    return pd.Timestamp(d).strftime("%Y-%m")


def show_error(err: str):
    st.error(err, icon=":material/error:")


# ----------------------------------------------------------------------- state
def params() -> dict:
    df = q("select param_name, param_value from dlm_config")
    p = dict(zip(df.param_name, df.param_value))
    p["as_of"] = dt.datetime.strptime(p["AS_OF_MONTH"], "%Y-%m").date()
    for k in ("HOT_MONTHS", "ONLINE_MONTHS", "RETENTION_MONTHS"):
        p[k] = int(p[k])
    return p


def add_months(d: dt.date, n: int) -> dt.date:
    m = d.year * 12 + d.month - 1 + n
    return dt.date(m // 12, m % 12 + 1, 1)


TIERS_SQL = """
with rec as (
  select dlm_pkg.partition_month('BILLING_RECORDS', p.partition_name) month_start,
         p.partition_name, p.read_only, p.tablespace_name, p.compression, p.num_rows,
         'RECORDS' src
  from   user_tab_partitions p
  where  p.table_name = 'BILLING_RECORDS' and p.partition_name <> 'P_INITIAL'),
arc as (
  select dlm_pkg.partition_month('BILLING_ARCHIVE', p.partition_name) month_start,
         p.partition_name, p.read_only, p.tablespace_name, p.compression, p.num_rows,
         'ARCHIVE' src
  from   user_tab_partitions p
  where  p.table_name = 'BILLING_ARCHIVE' and p.partition_name <> 'P_INITIAL'),
seg as (
  select segment_name, partition_name, bytes from user_segments
  where  segment_type = 'TABLE PARTITION'
  and    segment_name in ('BILLING_RECORDS', 'BILLING_ARCHIVE'))
select x.*, round(s.bytes / 1048576, 1) mb, ct.row_count control_rows
from   (select * from rec union all select * from arc) x
left   join seg s on s.partition_name = x.partition_name
                 and s.segment_name = decode(x.src, 'RECORDS', 'BILLING_RECORDS', 'BILLING_ARCHIVE')
left   join billing_control_totals ct on ct.month_start = x.month_start
"""


def tier_table() -> pd.DataFrame:
    """One row per month: tier, rows, MB, where it lives."""
    parts = q(TIERS_SQL)
    staged_month = scalar("select min(trunc(bill_date, 'MM')) from billing_xchg")
    staged_rows = scalar("select count(*) from billing_xchg")
    totals = q("select month_start, row_count from billing_control_totals")

    rows = {}
    for r in parts.itertuples():
        m = pd.Timestamp(r.month_start)
        n = r.num_rows if pd.notna(r.num_rows) else r.control_rows
        if r.src == "ARCHIVE":
            tier = "ARCHIVE"
        else:
            tier = "WARM" if r.read_only == "YES" else "HOT"
        # an empty partition (stray, or emptied by an interrupted exchange)
        if pd.isna(n) or n == 0:
            continue
        if m not in rows or tier == "ARCHIVE":
            rows[m] = dict(month=m, tier=tier, rows=n or 0, mb=r.mb or 0,
                           partition=r.partition_name, tablespace=r.tablespace_name,
                           compression=r.compression, read_only=r.read_only)
    if staged_month is not None and staged_rows:
        m = pd.Timestamp(staged_month)
        rows[m] = dict(month=m, tier="STAGED", rows=staged_rows, mb=0, partition="BILLING_XCHG",
                       tablespace="", compression="", read_only="")
    for t in totals.itertuples():
        m = pd.Timestamp(t.month_start)
        if m not in rows:
            rows[m] = dict(month=m, tier="PURGED", rows=t.row_count, mb=0, partition="",
                           tablespace="", compression="", read_only="")
    df = pd.DataFrame(sorted(rows.values(), key=lambda x: x["month"]))
    df["label"] = df.month.dt.strftime("%Y-%m")
    return df


def demo_state(p: dict, tiers: pd.DataFrame) -> str:
    present = tiers[tiers.tier != "PURGED"]
    if not (present.tier.isin(["WARM", "ARCHIVE"])).any():
        return "FRESH"
    purge_cut = pd.Timestamp(add_months(p["as_of"], -p["RETENTION_MONTHS"]))
    if (present.month < purge_cut).any():
        return "READY"          # policy applied for the previous month only
    return "DONE"


def tier_chart(tiers: pd.DataFrame, height: int = 260):
    """Bars per month coloured by tier, with a dashed rule where each tier starts."""
    domain = list(TIER_COLORS)
    step = max(1, len(tiers) // 18)
    x = alt.X("label:O", title=None, sort=list(tiers.label),
              axis=alt.Axis(labelAngle=-45, values=list(tiers.label)[::step], ticks=False,
                            domain=False, labelPadding=6))
    bars = (alt.Chart(tiers)
            .mark_bar(cornerRadiusTopLeft=3, cornerRadiusTopRight=3)
            .encode(x=x,
                    y=alt.Y("rows:Q", title="rows per month",
                            axis=alt.Axis(format="~s", domain=False, ticks=False, tickCount=4)),
                    color=alt.Color("tier:N", scale=alt.Scale(domain=domain,
                                                              range=[TIER_COLORS[t] for t in domain]),
                                    legend=alt.Legend(orient="top", title=None, labelFontSize=13,
                                                      symbolType="circle", symbolSize=120)),
                    tooltip=[alt.Tooltip("label:N", title="Month"), alt.Tooltip("tier:N", title="Tier"),
                             alt.Tooltip("rows:Q", title="Rows", format=","),
                             alt.Tooltip("mb:Q", title="Size (MB)", format=",.1f"),
                             alt.Tooltip("partition:N", title="Partition"),
                             alt.Tooltip("tablespace:N", title="Tablespace")]))
    starts = tiers[tiers.tier.ne(tiers.tier.shift())].iloc[1:]
    rules = (alt.Chart(starts).mark_rule(strokeDash=[4, 4], color="#8a96a5", strokeWidth=1.2)
             .encode(x=x))
    text = (alt.Chart(starts).mark_text(align="left", dx=4, dy=-4, fontSize=11, fontWeight=600,
                                        color="#5b6878", baseline="bottom")
            .encode(x=x, y=alt.value(0), text=alt.Text("tier:N")))
    return (alt.layer(bars, rules, text, background="#ffffff")
            .properties(height=height, padding={"left": 14, "right": 22, "top": 12, "bottom": 8})
            .configure_view(strokeWidth=0)
            .configure_axis(gridColor="#eef2f6", labelColor="#5b6878", titleColor="#5b6878",
                            labelFontSize=12, titleFontSize=12, titleFontWeight=600)
            .configure_legend(labelColor="#34404f")
            .configure_title(fontSize=14, color="#1d2733", anchor="start", fontWeight=600))


def job_log(where: str = "1 = 1", binds=None, limit: int = 20) -> pd.DataFrame:
    return q(f"""select log_id, run_id, to_char(logged_at, 'HH24:MI:SS') at_time, action,
                        target, rows_affected, elapsed_sec, status, message
                 from dlm_job_log where {where}
                 order by log_id desc fetch first {int(limit)} rows only""", binds) \
        .astype({"log_id": "Int64", "run_id": "Int64", "rows_affected": "Int64"})


def last_run_id():
    return scalar("select max(run_id) from dlm_job_log")


# ---------------------------------------------------------------------- pages
def page_overview(p, tiers):
    st.header("State of the tiers")
    callout(f"Where every month of billing history lives today. Policy month "
            f"<b>{p['AS_OF_MONTH']}</b>: hot {p['HOT_MONTHS']} months, online "
            f"{p['ONLINE_MONTHS']} months, legal retention {p['RETENTION_MONTHS']} months.")

    kept = tiers[tiers.tier.isin(["HOT", "WARM", "ARCHIVE", "STAGED"])]
    total = int(kept.rows.sum()) or 1
    online = int(kept[kept.tier.isin(["HOT", "WARM"])].rows.sum())
    archived = total - online
    last_check = scalar("select message from dlm_job_log where action = 'VALIDATE' "
                        "order by log_id desc fetch first 1 row only") or "not run yet"
    check_val = re.match(r"(\d+/\d+)", last_check)
    share = (f'<div class="ratio"><span style="width:{online / total:.1%};background:#f59f00"></span>'
             f'<span style="width:{archived / total:.1%};background:#1971c2"></span></div>')
    k = st.columns(4)
    kpi(k[0], "Retained history", f"{total / 1e6:,.2f} M", f"rows over {len(kept)} months",
        "layers", "#1f4e79")
    kpi(k[1], "Online / archived", f"{online / total:.0%} / {archived / total:.0%}",
        f"{online:,} online &middot; {archived:,} archived", "archive", "#1971c2", share)
    kpi(k[2], "Storage saved", "-44 %", "retained data 4,552 &rarr; 2,562 MB (benchmark)",
        "disk", "#2f9e44")
    kpi(k[3], "Last integrity check", check_val[1] if check_val else "-",
        "months match their control totals", "check", "#2f9e44")
    st.write("")

    cols = st.columns(5)
    for col, tier in zip(cols, TIER_COLORS):
        t = tiers[tiers.tier == tier]
        n = int(t.rows.sum())
        all_rows = int(tiers.rows.sum()) or 1
        text_color = "#868e96" if tier == "PURGED" else TIER_COLORS[tier]
        c = TIER_COLORS[tier]
        html(f'<div class="tiercard">'
             f'<div class="tint" style="background:linear-gradient(90deg,{c},{c}66)"></div>'
             f'<div class="body" style="background:linear-gradient(180deg,{c}14 0,#ffffff 64px)">'
             f'<div class="n" style="color:{text_color}">{tier}</div>'
             f'<div class="v">{len(t)}<small>months</small></div>'
             f'<div class="r num">{n:,} rows</div>'
             f'<div class="bar"><span style="width:{n / all_rows:.1%};background:{c}"></span></div>'
             f'<div class="d">{TIER_TEXT[tier]}</div></div></div>', col)
    st.write("")

    st.altair_chart(tier_chart(tiers), use_container_width=True)

    c1, c2 = st.columns(2)
    with c1:
        st.subheader("Size per table (MB, with indexes)")
        st.dataframe(q("""
            select nvl(i.table_name, s.segment_name) table_name, round(sum(s.bytes) / 1048576) mb
            from   user_segments s left join user_indexes i on i.index_name = s.segment_name
            where  nvl(i.table_name, s.segment_name) like 'BILLING%'
            group  by nvl(i.table_name, s.segment_name) order by 1"""),
            hide_index=True, use_container_width=True)
    with c2:
        st.subheader("Retention policy (DLM_CONFIG)")
        st.dataframe(q("select param_name, param_value, description from dlm_config order by 1"),
                     hide_index=True, use_container_width=True)
        text = scalar("select text from user_views where view_name = 'BILLING_CURRENT_V'") or ""
        dates = re.findall(r"date\s*'(\d{4}-\d{2})-\d{2}'", text, flags=re.I)
        if len(dates) >= 2:
            st.info(f"Application write window (BILLING_CURRENT_V): from **{dates[0]}** "
                    f"to before **{dates[1]}** - rows outside are rejected (WITH CHECK OPTION).")

    with st.expander("Every month and where it lives"):
        st.dataframe(tiers[["label", "tier", "rows", "mb", "partition", "tablespace",
                            "compression", "read_only"]],
                     hide_index=True, use_container_width=True)


def _measured(conn, sql: str):
    """Run sql, return (dataframe, elapsed ms, stats delta, plan text)."""
    cur = conn.cursor()
    stat_sql = ("select n.name, m.value from v$mystat m join v$statname n "
                "on n.statistic# = m.statistic# "
                "where n.name in ('session logical reads', 'physical reads')")
    cur.execute(stat_sql)
    before = dict(cur.fetchall())
    t0 = time.perf_counter()
    cur.execute(sql)
    cols = [c[0].lower() for c in cur.description]
    data = cur.fetchall()
    ms = (time.perf_counter() - t0) * 1000
    cur.execute("select prev_sql_id, prev_child_number from v$session "
                "where sid = sys_context('userenv', 'sid')")
    sql_id, child = cur.fetchone()
    cur.execute(stat_sql)
    after = dict(cur.fetchall())
    cur.execute("select plan_table_output from table(dbms_xplan.display_cursor(:1, :2, "
                "'BASIC +ROWS +PARTITION'))", [sql_id, child])
    lines = [r[0] or "" for r in cur]
    start = next((i for i, l in enumerate(lines) if l.startswith("Plan hash value")), 0)
    plan = "\n".join(l for l in lines[start:] if l.strip())
    delta = {k: after[k] - before[k] for k in before}
    return pd.DataFrame(data, columns=cols), ms, delta, plan


def page_query(p, tiers):
    stepper(1)
    st.header("Business query: same SQL on both designs")
    callout("You will see the same report run on both designs, the blocks each one reads, and "
            "the execution plans that explain the difference.")
    st.write("Finance asks for the revenue by service over a period. The query runs on the "
             "**current design** (one heap table, `BILLING_RECORDS_BASE`) and on the "
             "**partitioned design** (`BILLING_RECORDS`). Logical reads (blocks read) are the "
             "stable measure; time depends on the cache.")
    online = tiers[tiers.tier.isin(["HOT", "WARM"])].sort_values("month", ascending=False)
    if online.empty:
        st.warning("No online month.")
        return
    labels = list(online.label)
    c1, c2, _ = st.columns([1, 1, 2])
    first = c1.selectbox("From month", labels, index=0)
    last = c2.selectbox("To month (included)", labels, index=0)
    d1 = dt.datetime.strptime(min(first, last), "%Y-%m").date()
    d2 = add_months(dt.datetime.strptime(max(first, last), "%Y-%m").date(), 1)
    sql_tpl = ("select service_type, count(*) records, round(sum(amount), 2) revenue\n"
               "from   {t}\n"
               f"where  bill_date >= {lit(d1)} and bill_date < {lit(d2)}\n"
               "group  by service_type order by service_type")
    st.code(sql_tpl.format(t="<table>"), language="sql")

    if st.button("Run on both designs", type="primary", icon=":material/play_arrow:"):
        with st.spinner("Running ..."), owner_pool().acquire() as conn:
            base = _measured(conn, sql_tpl.format(t="billing_records_base"))
            part = _measured(conn, sql_tpl.format(t="billing_records"))
        st.session_state["query_result"] = (base, part, f"{min(first, last)} .. {max(first, last)}")

    if "query_result" in st.session_state:
        base, part, period = st.session_state["query_result"]
        st.subheader(f"Result for {period}")
        lio_b, lio_p = base[2]["session logical reads"], part[2]["session logical reads"]
        speed, fewer = base[1] / max(part[1], 0.1), lio_b / max(lio_p, 1)

        def bar(label, value, ref, color, unit):
            return (f'<div class="row"><div class="lbl">{label}</div><div class="trk">'
                    f'<span style="width:{max(value / ref, .012):.1%};background:{color}"></span></div>'
                    f'<div class="val">{value:,.0f} {unit}</div></div>')
        ref_t, ref_l = max(base[1], part[1]), max(lio_b, lio_p, 1)
        html(f'<div class="win">'
             f'<div class="big"><div class="x">{fewer:.0f}&times;</div>'
             f'<div class="l">fewer blocks read</div></div>'
             f'<div class="big blue"><div class="x">{speed:.1f}&times;</div>'
             f'<div class="l">faster on this run</div></div>'
             f'<div class="cmp"><div class="ttl">Logical reads (blocks)</div>'
             f'{bar("Baseline", lio_b, ref_l, "#adb5bd", "")}'
             f'{bar("Partitioned", lio_p, ref_l, "#2f9e44", "")}'
             f'<div class="ttl" style="margin-top:10px">Elapsed time</div>'
             f'{bar("Baseline", base[1], ref_t, "#adb5bd", "ms")}'
             f'{bar("Partitioned", part[1], ref_t, "#2b6cb0", "ms")}</div></div>')
        same = base[0].equals(part[0])
        (st.success if same else st.error)(
            "Both designs return identical results." if same else "Results differ!")
        c1, c2 = st.columns(2)
        with c1:
            st.markdown("**Baseline (heap table)**")
            st.dataframe(base[0], hide_index=True, use_container_width=True)
        with c2:
            st.markdown("**Partitioned design**")
            st.dataframe(part[0], hide_index=True, use_container_width=True)
        st.markdown("**Execution plan - baseline**")
        st.code(base[3], language=None)
        st.markdown("**Execution plan - partitioned**")
        st.code(part[3], language=None)
        st.caption("PARTITION RANGE SINGLE / ITERATOR = only the partitions of the period are "
                   "read. For interval partitioning Pstart/Pstop is the interval number counted "
                   "from the first partition, not the current position.")


def page_dry_run(p, tiers):
    stepper(2)
    st.header("Dry run of the monthly job")
    callout("You will see exactly what the monthly job is going to do, before anything changes.")
    st.write(f"What would `dlm_pkg.run_lifecycle` do for **{p['AS_OF_MONTH']}**? "
             "The dry run only writes `PLANNED` lines in the job log; no data changes.")
    if st.button("Run the dry run", type="primary", icon=":material/visibility:"):
        _, err = run_write("Planning", "begin dlm_pkg.run_lifecycle(p_dry_run => true); end;")
        if err and err != "busy":
            show_error(err)
        elif not err:
            st.session_state["dry_run_id"] = last_run_id()
    rid = st.session_state.get("dry_run_id")
    if rid:
        plan = q("""select action, count(*) months, min(target) first_month, max(target) last_month
                    from dlm_job_log where run_id = :r and status = 'PLANNED'
                    group by action order by decode(action, 'PURGE', 1, 'WARM', 2, 'ARCHIVE', 3, 4)""",
                 {"r": rid})
        if plan.empty:
            st.success("Nothing to do: the policy is already applied for this month.")
        else:
            st.subheader(f"Plan (run {rid})")
            st.dataframe(plan, hide_index=True, use_container_width=True)
            if (plan.action == "DROP_EMPTY").any():
                st.caption("DROP_EMPTY: empty partitions created by rejected inserts (for "
                           "example the security checks). The job removes them.")
        st.caption("The partitions are unchanged - check the Overview page.")


def _incident_month(p, tiers):
    staged = tiers[tiers.tier == "STAGED"]
    if not staged.empty:
        return staged.month.iloc[0].date(), True
    if "incident_month" in st.session_state:
        return st.session_state["incident_month"], False
    online_cut = pd.Timestamp(add_months(p["as_of"], -p["ONLINE_MONTHS"]))
    cand = tiers[tiers.tier.isin(["HOT", "WARM"]) & (tiers.month < online_cut)]
    if cand.empty:
        return None, False
    return cand.month.min().date(), False


def timeline(events):
    """events: (title, subtitle, reached, colour, icon) - a horizontal 3-step timeline."""
    parts = []
    for i, (title, sub, on, color, ic) in enumerate(events):
        if i:
            prev = events[i - 1]
            line = f"background:linear-gradient(90deg,{prev[3]},{color})" if on else ""
            parts.append(f'<div class="ln" style="{line}"></div>')
        dot = (f"background:{color};border-color:{color};box-shadow:0 0 0 4px {color}2e"
               if on else "")
        parts.append(f'<div class="ev {"on" if on else ""}">'
                     f'<div class="c" style="{dot}">{icon(ic, 15, "#fff" if on else "#aab4c0")}</div>'
                     f'<div>{title}<small>{sub}</small></div></div>')
    html(f'<div class="tl">{"".join(parts)}</div>')


def page_incident(p, tiers):
    stepper(3)
    st.header("Incident: the archive job crashes, then recovers")
    callout("You will see the archive job crash in the middle of a month, the integrity check "
            "detect it, and a simple re-run finish the work without losing a row.")
    month, crashed = _incident_month(p, tiers)
    if month is None:
        st.info("No month is due for archiving. The incident scenario needs a month older than "
                f"{p['ONLINE_MONTHS']} months still online (the state before the monthly job).")
        return
    label = mlabel(month)
    present = tiers[tiers.tier != "PURGED"]
    v_from = present.month.min().date()
    v_to = add_months(month, 1)
    st.write(f"Archiving **{label}** is done with two `EXCHANGE PARTITION` steps through the "
             "empty table `BILLING_XCHG`. We make the job crash right after step 1.")

    def validate():
        return scalar(f"select dlm_pkg.validate_integrity('BILLING_ALL', {lit(v_from)}, null, "
                      f"{lit(v_to)}) from dual")

    def counts():
        rng = f"bill_date >= {lit(month)} and bill_date < {lit(add_months(month, 1))}"
        return (scalar(f"select count(*) from billing_records where {rng}"),
                scalar("select count(*) from billing_xchg"),
                scalar(f"select count(*) from billing_archive where {rng}"))

    c1, c2, c3 = st.columns([1, 0.9, 1.1])
    done = "incident_done" in st.session_state
    if c1.button("1\\. Crash the archive job", type="primary", disabled=crashed or done,
                 icon=":material/bolt:"):
        _, err = run_write("Archiving with a simulated crash",
                           "begin dlm_pkg.archive_partition(:m, p_simulate_failure => 'AFTER_STEP1'); end;",
                           {"m": month})
        if err != "busy":
            st.session_state["incident_month"] = month
        if err and err != "busy":
            st.session_state["incident_error"] = err
        st.rerun()
    if c2.button("2\\. Check integrity", icon=":material/fact_check:"):
        with st.spinner("Comparing every month with its control totals ..."):
            st.session_state["incident_check"] = validate()
    if c3.button("3\\. Recover: re-run the job", disabled=not crashed, icon=":material/healing:"):
        t, err = run_write("Resuming the archive", "begin dlm_pkg.archive_partition(:m); end;",
                           {"m": month})
        st.session_state.pop("incident_error", None)
        if err and err != "busy":
            show_error(err)
        elif not err:
            st.session_state["incident_check"] = validate()
            st.session_state["incident_done"] = f"{label} archived after recovery ({t:.1f} s)"
        st.rerun()

    if "incident_error" in st.session_state and crashed:
        st.error(st.session_state["incident_error"], icon=":material/bolt:")
    if "incident_done" in st.session_state and not crashed:
        st.success(st.session_state["incident_done"])

    chk_now = st.session_state.get("incident_check")
    finished = "incident_done" in st.session_state and not crashed
    timeline([("Crash", "ORA-20020 after step 1", crashed or finished, "#e03131", "bolt"),
              ("Detected", "integrity check", (chk_now or 0) > 0 or finished, "#f08c00", "search"),
              ("Recovered", "re-run resumes at step 2", finished, "#2f9e44", "heal")])

    online_rows, xchg_rows, arch_rows = counts()
    m = st.columns(4)
    m[0].metric(f"{label} rows online", f"{online_rows:,}", help="BILLING_RECORDS")
    m[1].metric("Rows in BILLING_XCHG", f"{xchg_rows:,}", help="staging table of the exchange")
    m[2].metric(f"{label} rows archived", f"{arch_rows:,}", help="BILLING_ARCHIVE")
    chk = st.session_state.get("incident_check")
    m[3].metric("Months in error", help=f"integrity check {mlabel(v_from)} .. {label}", value=
                "-" if chk is None else chk)
    if crashed:
        st.warning("The job crashed, but no row is lost: they wait in BILLING_XCHG. "
                   "The integrity check sees one incomplete month. Re-running the job resumes "
                   "at step 2.")
    st.subheader("Audit trail")
    st.dataframe(job_log("action in ('ARCHIVE', 'VALIDATE')", limit=6),
                 hide_index=True, use_container_width=True,
                 column_config={"message": st.column_config.TextColumn(width="large")})


def page_monthly(p, tiers):
    stepper(4)
    st.header("Monthly lifecycle job")
    callout("You will see a guard refuse a dangerous request, then the real monthly job move "
            "each month to its next tier and prove that nothing was lost.")
    st.write(f"Policy month: **{p['AS_OF_MONTH']}**. The job purges months older than "
             f"{p['RETENTION_MONTHS']} months, compresses the month leaving the hot tier, "
             "archives the month leaving the online window, gathers statistics and checks every "
             "frozen month against its control totals.")

    st.subheader("1. A guard refuses a dangerous request")
    present = tiers[tiers.tier != "PURGED"]
    guard_month = add_months(present.month.min().date(), 3)
    st.code(f"exec dlm_pkg.purge_partition({lit(guard_month)}, p_retention_months => 24)",
            language="sql")
    if st.button("Try it", icon=":material/gpp_bad:"):
        _, err = run_write("Purging", "begin dlm_pkg.purge_partition(:m, p_retention_months => 24); end;",
                           {"m": guard_month})
        if err == "busy":
            pass
        elif err:
            st.error(err, icon=":material/block:")
        else:
            st.warning("The purge was accepted (unexpected).")

    st.subheader("2. Run the monthly job")
    if "monthly" not in st.session_state:
        st.altair_chart(tier_chart(tiers, 240).properties(title="Current state"),
                        use_container_width=True)
    if st.button("Run dlm_pkg.run_lifecycle", type="primary", icon=":material/play_arrow:"):
        before = tiers.copy()
        t, err = run_write("Running the monthly job (purge, warm, archive, stats, validation)",
                           "begin dlm_pkg.run_lifecycle; end;")
        if err and err != "busy":
            show_error(err)
        elif not err:
            st.session_state["monthly"] = (last_run_id(), t, before)
            st.rerun()
    if "monthly" in st.session_state:
        rid, t, before = st.session_state["monthly"]
        st.success(f"Run {rid} finished in {t:.1f} s.")
        c1, c2 = st.columns(2)
        c1.altair_chart(tier_chart(before, 230).properties(title="Before"),
                        use_container_width=True)
        c2.altair_chart(tier_chart(tiers, 230).properties(title="After"), use_container_width=True)
        st.dataframe(q("""select action, status, count(*) operations, round(sum(elapsed_sec), 2) total_sec,
                                 sum(case when action <> 'VALIDATE' then rows_affected end) rows_processed
                          from dlm_job_log where run_id = :r group by action, status order by 1""",
                       {"r": rid}).astype({"rows_processed": "Int64"}),
                     hide_index=True, use_container_width=True)
        msg = scalar("select message from dlm_job_log where run_id = :r and action = 'VALIDATE' "
                     "order by log_id desc fetch first 1 row only", {"r": rid})
        if msg:
            st.info(f"Integrity: {msg}")

    st.subheader("3. Archived history is still one query away")
    st.code("select count(*) from billing_all\nwhere bill_date >= date '2022-03-01' "
            "and bill_date < date '2022-04-01'\nand payment_status = 'DISPUTED'", language="sql")
    if st.button("Query BILLING_ALL", icon=":material/search:"):
        n = scalar("select count(*) from billing_all where bill_date >= date '2022-03-01' "
                   "and bill_date < date '2022-04-01' and payment_status = 'DISPUTED'")
        st.metric("Disputed bills of 2022-03", f"{n:,}")


def _security_block(path: Path) -> str:
    lines = path.read_text().splitlines()
    start = next(i for i, l in enumerate(lines) if l.strip().lower() == "declare")
    end = next(i for i in range(start, len(lines)) if lines[i].strip() == "/")
    return "\n".join(lines[start:end])


def run_security(user: str, pw_env: str, path: Path) -> pd.DataFrame:
    conn = oracledb.connect(user=user, password=os.environ[pw_env], dsn=_dsn())
    try:
        cur = conn.cursor()
        cur.callproc("dbms_output.enable", [None])
        err = None
        try:
            cur.execute(_security_block(path))
        except oracledb.DatabaseError as exc:
            err = exc.args[0].message
        line, status = cur.var(str), cur.var(int)
        out = []
        while True:
            cur.callproc("dbms_output.get_line", (line, status))
            if status.getvalue() != 0:
                break
            out.append(line.getvalue() or "")
        conn.rollback()
    finally:
        conn.close()
    rows = []
    for l in out:
        mo = re.match(r"(PASS|FAIL)\s+(\S+)\s+(.*?)(?:\s+\((ORA-?\d+)\))?\s*$", l)
        if mo:
            rows.append(dict(result=mo[1], check=mo[2], description=mo[3],
                             oracle_error=(f"ORA-{abs(int(mo[4][3:])):05d}" if mo[4] else "-")))
    df = pd.DataFrame(rows)
    df.attrs["summary"] = next((l for l in out if "passed" in l), err or "")
    return df


def page_security(p, tiers):
    stepper(5)
    st.header("Least privilege: what each account can and cannot do")
    callout("You will see each account try real statements: what it is allowed to do succeeds, "
            "everything else is refused with a precise Oracle error.")
    st.write("Each check runs a real statement with the account's own connection and expects a "
             "precise outcome (success or a given Oracle error). Writes are rolled back.")
    state = demo_state(p, tiers)
    if state != "DONE":
        st.info(f"The checks use the write window of {p['AS_OF_MONTH']}: run the monthly job "
                "first (page 4. Monthly job).")
    accounts = [("TELCO_APP", "billing application", "TELCO_APP_PASSWORD", "02_security_app.sql"),
                ("TELCO_ANALYST", "analysts / auditors", "TELCO_ANALYST_PASSWORD",
                 "03_security_analyst.sql")]
    for user, role, env, fname in accounts:
        with st.container():
            st.subheader(f"{user} ({role})")
            if st.button(f"Run the {user} checks", key=user, icon=":material/shield:",
                         disabled=state != "DONE"):
                with st.spinner("Checking ..."):
                    st.session_state[f"sec_{user}"] = run_security(
                        user, env, ROOT / "sql" / "03_tests" / fname)
            df = st.session_state.get(f"sec_{user}")
            if df is not None:
                ok = not df.empty and (df.result == "PASS").all()
                (st.success if ok else st.error)(df.attrs.get("summary", ""))
                styled = df.style.map(
                    lambda v: ("background-color:#dcf7e3;color:#1d6b32;font-weight:700"
                               if v == "PASS" else
                               "background-color:#ffe3e3;color:#c92a2a;font-weight:700"),
                    subset=["result"])
                st.dataframe(styled, hide_index=True, use_container_width=True,
                             height=35 * (len(df) + 1) + 3,
                             column_config={"description": st.column_config.TextColumn(width="large")})


def page_benchmark(p, tiers):
    st.header("Benchmark on 23.76 million rows (final run)")
    summary = ROOT / "results" / "summary.md"
    if not summary.exists():
        st.warning("results/summary.md not found - run scripts/05_benchmark.sh.")
        return
    m = st.columns(4)
    m[0].metric("Monthly report (Q1)", "14x faster", "54x fewer blocks", delta_color="off")
    m[1].metric("Archive one month", "26.17 s -> 0.42 s", "62x, redo 499 -> 6 MB",
                delta_color="off")
    m[2].metric("Monthly job", "31.3 s -> 3.5 s", "8.9x, redo 3.8x lower", delta_color="off")
    m[3].metric("Retained data", "4552 -> 2570 MB", "-44 %", delta_color="off")
    charts = sorted((ROOT / "results" / "charts").glob("*.png"))
    for i in range(0, len(charts), 2):
        cols = st.columns(2)
        for col, path in zip(cols, charts[i:i + 2]):
            col.image(str(path), caption=path.stem.replace("_", " "), use_container_width=True)
    with st.expander("Full results (results/summary.md)"):
        text = "\n".join(l for l in summary.read_text().splitlines() if not l.startswith("!["))
        st.markdown(text)


def page_log(p, tiers):
    st.header("Job log (DLM_JOB_LOG)")
    c1, c2 = st.columns([1, 3])
    status = c1.multiselect("Status", ["OK", "SKIPPED", "REFUSED", "ERROR", "PLANNED", "RESUMED"])
    limit = c2.slider("Lines", 20, 500, 100, step=20)
    where, binds = "1 = 1", {}
    if status:
        where = "status in (" + ", ".join(f":s{i}" for i in range(len(status))) + ")"
        binds = {f"s{i}": s for i, s in enumerate(status)}
    st.dataframe(job_log(where, binds, limit), hide_index=True, use_container_width=True,
                 column_config={"message": st.column_config.TextColumn(width="large")})


PAGES = {
    "Overview": (page_overview, ":material/dashboard:"),
    "1. Business query": (page_query, ":material/query_stats:"),
    "2. Dry run": (page_dry_run, ":material/visibility:"),
    "3. Incident & recovery": (page_incident, ":material/bolt:"),
    "4. Monthly job": (page_monthly, ":material/autorenew:"),
    "5. Security": (page_security, ":material/shield:"),
    "Benchmark results": (page_benchmark, ":material/bar_chart:"),
    "Job log": (page_log, ":material/list_alt:"),
}


def sidebar(p, tiers):
    html(f'<div class="sb-logo"><div class="mk">{icon("db", 22, "#fff")}</div>'
         f'<div><div class="t">Billing Data Lifecycle</div>'
         f'<div class="s">Project 22 &middot; Oracle 19c</div></div></div>', st.sidebar)
    state = demo_state(p, tiers)
    status_text = {
        "FRESH": "The policy has never been applied.",
        "READY": f"Policy applied up to the previous month. The monthly job for "
                 f"{p['AS_OF_MONTH']} has not run yet.",
        "DONE": f"The monthly job for {p['AS_OF_MONTH']} has run. Replay the demo with "
                f"<code>scripts/07_dashboard.sh --fresh</code> (~10 min).",
    }[state]
    k = STATE_COLOR[state]
    html(f'<div class="sb-status"><span class="dot" style="background:{k};'
         f'box-shadow:0 0 0 4px {k}33"></span>'
         f'<div><b>{STATE_TEXT[state]}</b>{status_text}</div></div>', st.sidebar)
    if state == "FRESH":
        prev = add_months(p["as_of"], -1)
        if st.sidebar.button(f"Prepare the demo (apply policy as of {prev:%Y-%m}, ~4 min)"):
            _, err = run_write("Preparing", "begin dlm_pkg.run_lifecycle(p_as_of => :d); end;",
                               {"d": prev})
            if err and err != "busy":
                st.sidebar.error(err)
            st.rerun()
    html('<div class="sb-h">DEMO STEPS</div>', st.sidebar)
    # icon + label; "1." is escaped so markdown does not turn it into a numbered list
    choice = st.sidebar.radio("Steps", list(PAGES), label_visibility="collapsed",
                              format_func=lambda k: f"{PAGES[k][1]} "
                                                    + re.sub(r"^(\d+)\. ", r"\1\\. ", k))
    st.sidebar.divider()
    st.sidebar.caption(f"Connected to {os.environ.get('ORACLE_PDB_SERVICE')} as TELCO_OWNER")
    return choice


def main():
    st.markdown(CSS, unsafe_allow_html=True)
    try:
        p = params()
        tiers = tier_table()
    except Exception as exc:  # database down or schema missing
        st.error(f"Cannot read the database: {exc}")
        st.stop()
    choice = sidebar(p, tiers)
    header_band(p, demo_state(p, tiers))
    PAGES[choice][0](p, tiers)


main()
