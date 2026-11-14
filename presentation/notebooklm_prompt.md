# NotebookLM: defense slide deck

## 1. Sources to upload (in this order)

1. `report/Technical_Report.pdf` (main source)
2. `results/summary.md` (exact measured numbers)
3. `docs/demo.md` (demo script)
4. Images, as visual references:
   - `report/figures/01_architecture.png`, `02_tiers.png`, `03_archive_sequence.png`, `05_lifecycle_activity.png`
   - `results/charts/queries_before_lio.png`, `maintenance_time.png`, `space_after.png`
   - `docs/screenshots/*.png` (dashboard)

Then: Studio -> Slide deck -> customise -> paste the prompt below.

## 2. Prompt (copy everything between the lines)

---

Create a 14-slide presentation deck in English for the 15-minute defense of a Master's project in
Oracle Database Administration (Master SIIA). The audience is an evaluation committee, so treat
them as a demanding DBA Manager: technical, precise, short sentences, no marketing language.
Use ONLY facts and numbers from the uploaded sources, and never invent a figure. The deck must
summarise the mission, not copy the report.

Title: "Oracle Database Performance Optimization Through Partitioning and Data Lifecycle
Management", Project 22. Team: Mohamed Baounna, Amine Bazaoui. Academic year 2026-2027.

Visual style: light theme (white background, dark navy text, one accent blue #1f4e79). Use the
tier colours consistently: HOT orange, WARM amber, ARCHIVE blue, PURGED grey. At most 5 bullets
per slide and at most 12 words per bullet. Put a big number or a diagram on every slide where
possible. Mark each slide with its speaker (Mohamed or Amine) in the speaker notes, and keep the
timing: slides 1-6 = 3 minutes, slides 7-8 = 5-minute live demo, slides 9-12 = 2 minutes.

Slides:
1. Title slide: project title, team, Master SIIA, Oracle Database Administration, 2026-2027.
2. Client and context: a fictitious mobile operator with 500,000 subscribers and 12 regions;
   billing in Oracle 19c EE; sponsor = DBA Manager; one heap table holding 6 years (23.76 M rows).
3. Business problem and requirements: slow month-end reports, expensive DELETE-based retention,
   60-month legal retention, history must stay queryable, the application must never change
   history, and every action must be traceable.
4. Mission and measurable objectives: show the KPI table K1-K11 with its targets (for example
   >=10x fewer blocks on the month-end report, purge <1 s, storage >=25 % smaller, 100 %
   integrity, 0 rows lost after a crash, one command per month).
5. Architecture: the data lifecycle HOT (0-12 months, read/write) -> WARM (13-36, compressed,
   read-only) -> ARCHIVE (37-60, separate table via EXCHANGE PARTITION) -> PURGE (DROP
   PARTITION). Reuse the tiers diagram and the architecture diagram.
6. Technology choices and justification: interval-range partitioning by month; exchange partition
   instead of INSERT+DELETE; BASIC compression (included in EE, no Advanced Compression licence);
   PL/SQL package DLM_PKG; Docker + Bash + Python; base-product views only (no AWR/ASH).
7. Implementation and components: DLM_PKG (warm, archive in 2 exchanges through BILLING_XCHG,
   purge, run_lifecycle with dry run, integrity validation against control totals, job lock);
   three accounts (TELCO_OWNER, TELCO_APP, TELCO_ANALYST, least privilege); numbered scripts
   01-07; Streamlit web dashboard.
8. Live demonstration (5 min) as a numbered agenda: 1) business query on both designs, 54x fewer
   blocks; 2) dry run; 3) incident: the archive job crashes after step 1, integrity detects it,
   a re-run recovers it with 0 rows lost; 4) guard refuses an illegal purge, then the monthly job
   runs; 5) security checks. Leave room for a dashboard screenshot.
9. Testing and validation: 43/43 automated functional tests, 25/25 security checks (14 TELCO_APP
   + 11 TELCO_ANALYST), integrity 62/62 months after the full benchmark, guards tested at their
   exact boundary months.
10. Measured results, queries (bar chart): month-end report 54x fewer logical reads and 14x
    faster; audit query on an archived month 97x fewer blocks; queries without a date filter
    gain nothing (shown honestly).
11. Measured results, maintenance and storage: archive one month 26.17 s -> 0.42 s (62x) with
    redo 498.8 MB -> 6.3 MB; purge 5.14 s -> 0.02 s; whole monthly job 8.9x faster with 3.8x
    less redo; retained storage 4,552 MB -> 2,562 MB (-44 %).
12. Challenges and solutions: 3 rows "problem -> fix" taken from the challenges chapter (for
    example, the noisy elapsed times of direct-path reads -> logical reads as the main indicator;
    a crash between the two exchanges -> resumable steps; limited disk -> capped tablespaces).
13. Limitations and recommendations: global-index maintenance cost of WARM, no record_id index
    on archived rows, single-user measurements; next steps: measure under concurrent load and
    schedule with DBMS_SCHEDULER.
14. Conclusion: every KPI met, with 3 big numbers (54x, 8.9x, -44 %). Add the GitHub link
    https://github.com/Baounna/oracle-billing-lifecycle and "Questions?".

---

## 3. After generation (manual)

NotebookLM does not always place uploaded images. Check each slide and paste the screenshots
yourself where they fit best:

| Slide | Image |
|---|---|
| 5 | `report/figures/02_tiers.png` + `01_architecture.png` |
| 7 | `report/figures/03_archive_sequence.png` |
| 8 | `docs/screenshots/01_overview.png` (or `07_incident_recovered.png`) |
| 9 | `docs/screenshots/10_security.png` |
| 10 | `docs/screenshots/03_query_result.png` or `results/charts/queries_before_lio.png` |
| 11 | `results/charts/maintenance_time.png` + `space_after.png` |
| backup (if the live demo fails) | `06_incident_crash.png`, `07_incident_recovered.png`, `08a_monthly_guard.png`, `08_monthly_job.png` |

Check every number against `results/summary.md` before the defense. The deck must contain
12 to 15 slides and be committed to the repository as PDF or PPTX (`presentation/`).
