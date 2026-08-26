#!/usr/bin/env bash
# Build and serve EXPERIMENT 7. Then open http://127.0.0.1:8731/ in a browser.
#
# Probe C needs TWO tabs: the second must report connections_total 2, which is
# the whole claim (one actor instance, N tabs). One tab alone cannot prove it.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/aiko-e7"
mkdir -p "$OUT"
dart compile js -O2 -o "$OUT/e7.js" tool/experiments/e7_one_artifact_two_roles.dart
cat > "$OUT/index.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>E7 — one artifact, two roles</title>
<style>
  body { font: 14px ui-monospace, SFMono-Regular, monospace; padding: 24px;
         background: #0f1115; color: #d8dee9; line-height: 1.5; }
  h1 { font-size: 15px; color: #88c0d0; margin: 0 0 16px; }
</style>
<h1>E7 — can one dart2js artifact be both the page and the Worker?</h1>
<script src="e7.js"></script>
HTML
echo "serving $OUT on http://127.0.0.1:8731/ (ctrl-c to stop)"
echo "OPEN IT IN TWO TABS -- probe C is only proven by the second."
cd "$OUT" && exec python3 -m http.server 8731 --bind 127.0.0.1
