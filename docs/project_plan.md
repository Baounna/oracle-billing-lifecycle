# Project plan, timeline and team responsibilities

## 1. Four-week plan (guidelines §5)

| Week | Activities | Expected outcome | Deliverables in this repository | Status |
|---|---|---|---|---|
| 1 | Requirements analysis, environment assessment, technology comparison, architecture, KPIs | Validated design, prepared environment | `docs/requirements.md`, `docs/architecture.md`, `docs/licensing.md`, `sql/00_admin/` | Done |
| 2 | Schema, data generator, partitioned design, lifecycle package, baseline package | First working version | `sql/01_schema/`, `sql/02_data/`, `scripts/01-03` | Done |
| 3 | Functional and security tests, incident simulation, benchmark, review rounds and fixes | Verifiable technical results | `sql/03_tests/`, `python/bench/`, `results/`, `docs/results_analysis.md`, `docs/work_log.md` | Done |
| 4 | Technical report (PDF), slides, demo rehearsal, defense | Final solution and demonstration | `sql/04_demo/`, `scripts/06_demo.sh`, `docs/demo.md`; report and slides | Report and slides pending |

## 2. Timeline of the main stages

| Stage | Main result | Evidence |
|---|---|---|
| Environment assessment | Oracle 19c EE container checked (Partitioning option present, PDB open); disk risk identified and capped | `docs/work_log.md` (environment) |
| Design | 3 tiers + purge, monthly interval partitioning, zero-copy archive, control totals | `docs/architecture.md` |
| First implementation | Schema, generator (24 M rows in ~3 min), DLM and baseline packages | `sql/01_schema/` |
| Smoke validation | Functional tests on a 216 000-row dataset | `results/tests/` |
| First benchmark | Query, maintenance and storage comparison | first version of `results/summary.md` |
| Review round 1 | Late-insert gap, portability, demo material | `docs/work_log.md` (full review) |
| Review round 2 | Independent review: integrity model, archive guards, security tests, password handling | `docs/work_log.md` (second round) |
| Review round 3 | Per-file review by three independent reviewers: warm robustness, `p_as_of`, test strength, monthly-job KPI | `docs/work_log.md` (third round) |
| Final run | Benchmark with the final code | `results/summary.md`, `docs/results_analysis.md` |

## 3. Distribution of responsibilities (to be confirmed by the team)

Both members must be able to explain the whole solution (guidelines §3). Suggested split of
**ownership** - each owner presents and answers first on their part, the other reviews it:

| Area | Files | Owner | Reviewer |
|---|---|---|---|
| Requirements, client scenario, KPIs, technology assessment | `docs/requirements.md`, `docs/licensing.md` | Member A | Member B |
| Architecture, partitioning and indexing design | `docs/architecture.md`, `sql/01_schema/03_billing_tables.sql` | Member A | Member B |
| Lifecycle package (warm / archive / purge / guards / integrity) | `sql/01_schema/05_dlm_pkg.sql` | Member A | Member B |
| Environment, tablespaces, accounts, security | `sql/00_admin/`, `sql/01_schema/07_grants.sql`, `scripts/lib.sh` | Member B | Member A |
| Data generator and baseline design | `sql/01_schema/04_datagen.sql`, `06_baseline_pkg.sql`, `sql/02_data/` | Member B | Member A |
| Tests (functional, security, incident) | `sql/03_tests/` | Member B | Member A |
| Benchmark harness and result analysis | `python/bench/`, `docs/results_analysis.md` | Member A | Member B |
| Demonstration | `sql/04_demo/`, `docs/demo.md` | both | - |
| Report and slides | PDF, PPTX | both | - |

Defense timing (15 min): context + architecture (3 min, Member A), live demo (5 min,
Member B drives, Member A comments), tests and results (2 min, Member A), questions (5 min,
both).
