#!/usr/bin/env bash
# Build the technical report: report/Technical_Report.pdf
#   report/build.sh            compile only (figures already rendered)
#   report/build.sh --diagrams also re-render the Mermaid diagrams (needs a
#                              Chromium browser and Internet access for Mermaid)
# Requires XeLaTeX (TeX Live / MacTeX). Charts come from results/charts/.
set -euo pipefail
cd "$(dirname "$0")"
[[ "${1:-}" == "--diagrams" ]] && diagrams/render.sh
mkdir -p build
for _ in 1 2 3; do   # 3 passes: table of contents, lists, references
  xelatex -interaction=nonstopmode -halt-on-error -output-directory=build report.tex > build/xelatex.out \
    || { tail -40 build/xelatex.out; exit 1; }
done
cp build/report.pdf Technical_Report.pdf
echo "Wrote report/Technical_Report.pdf"
