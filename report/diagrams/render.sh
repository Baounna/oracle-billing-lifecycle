#!/usr/bin/env bash
# Render every report/diagrams/*.mmd to report/figures/<name>.png with Mermaid in
# headless Brave/Chrome, then trim the white margins (Pillow).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/../figures"; mkdir -p "$OUT"
BROWSER="${BROWSER:-/Applications/Brave Browser.app/Contents/MacOS/Brave Browser}"
TMP="$(mktemp -d)"
for f in "$DIR"/*.mmd; do
  name="$(basename "$f" .mmd)"
  { echo '<!doctype html><html><head><meta charset="utf-8">'
    echo '<script src="https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js"></script>'
    echo '<style>body{margin:0;background:#fff}</style></head><body><div class="mermaid">'
    cat "$f"
    echo '</div><script>mermaid.initialize({startOnLoad:true,theme:"neutral",fontFamily:"Helvetica",flowchart:{htmlLabels:true,curve:"basis"},er:{fontSize:14}});</script></body></html>'
  } > "$TMP/$name.html"
  rm -f "$TMP/$name.png"
  "$BROWSER" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=1800,1600 --virtual-time-budget=10000 \
    --screenshot="$TMP/$name.png" "file://$TMP/$name.html" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 60); do [[ -s "$TMP/$name.png" ]] && break; sleep 1; done
  sleep 1; kill "$pid" 2>/dev/null || true
  python3 - "$TMP/$name.png" "$OUT/$name.png" <<'PY'
import sys
from PIL import Image, ImageChops
im = Image.open(sys.argv[1]).convert("RGB")
bbox = ImageChops.difference(im, Image.new("RGB", im.size, (255, 255, 255))).getbbox()
im.crop((max(bbox[0]-20, 0), max(bbox[1]-20, 0), bbox[2]+20, bbox[3]+20)).save(sys.argv[2])
print(sys.argv[2].split("/")[-1], im.crop(bbox).size)
PY
done
rm -rf "$TMP"
