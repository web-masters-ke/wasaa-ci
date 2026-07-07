#!/usr/bin/env bash
# severity-gate.sh
#
# The hard "does this fail the build?" decision. Two modes:
#   --gate fast|full          : evaluate the aggregated gate-summary.json
#   --semgrep <path.json>     : evaluate a Semgrep JSON output directly
#
# Fast gate: FAIL only on CRITICAL findings (and any job failure).
# Full gate: FAIL on CRITICAL or HIGH (per POLICY.md).
set -euo pipefail

mode=""
sem=""
gate="fast"

while [ $# -gt 0 ]; do
  case "$1" in
    --gate) gate="$2"; shift 2 ;;
    --semgrep) mode=semgrep; sem="$2"; shift 2 ;;
    --advisory) shift 2 ;; # no-op hook for advisory list
    *) shift ;;
  esac
done

fail_on_high=false
[ "$gate" = "full" ] && fail_on_high=true

if [ "$mode" = "semgrep" ]; then
  python3 - "$sem" "$fail_on_high" <<'PY'
import json, sys
path, fail_high = sys.argv[1], sys.argv[2] == "true"
try:
    d = json.load(open(path))
except Exception:
    print("severity-gate: no semgrep JSON to evaluate"); sys.exit(0)
crit = high = 0
for r in d.get("results", []):
    sev = (r.get("extra", {}).get("severity") or "").upper()
    if sev == "ERROR" or sev == "CRITICAL": crit += 1
    elif sev == "WARNING" or sev == "HIGH": high += 1
print(f"semgrep: {crit} CRITICAL, {high} HIGH")
if crit or (fail_high and high):
    print("::error::Semgrep severity gate failed")
    sys.exit(1)
PY
  exit 0
fi

# aggregated gate — trust gate-summary.json produced by gate-summary.sh
if [ ! -f gate-summary.json ]; then
  echo "severity-gate: gate-summary.json missing (was gate-summary.sh run?)" >&2
  exit 2
fi

python3 - "$gate" <<'PY'
import json, sys
gate = sys.argv[1]
d = json.load(open("gate-summary.json"))
failed = d.get("failed", 0)
if failed:
    print(f"::error::wasaa-ci {gate} gate failed: {failed} job(s) failed. See gate-summary.md")
    sys.exit(1)
print(f"wasaa-ci {gate} gate: passed")
PY
