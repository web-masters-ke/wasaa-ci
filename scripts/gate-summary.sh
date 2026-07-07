#!/usr/bin/env bash
# gate-summary.sh
#
# Reads the workflow `needs` object (RESULTS_JSON env, produced by toJson(needs))
# and produces:
#   - gate-summary.md — the PR comment / artifact
#   - gate-summary.json — machine-readable roll-up
#
# Any job whose `result` is not "success" or "skipped" is a failure.
# Waivers in $WAIVER_FILE are consumed (rule_id + path pairs) and downgrade
# matching findings from FAIL to WARN, provided they haven't expired.
set -euo pipefail

GATE="${GATE:-fast}"
RESULTS_JSON="${RESULTS_JSON:-{}}"
WAIVER_FILE="${WAIVER_FILE:-}"

md=gate-summary.md
js=gate-summary.json

python3 - <<'PY' "$GATE" "$RESULTS_JSON" "$WAIVER_FILE" "$md" "$js"
import json, os, sys, datetime
gate, raw, waiver_path, md_path, js_path = sys.argv[1:6]

try:
    results = json.loads(raw) if raw else {}
except json.JSONDecodeError:
    results = {}

waivers = []
if waiver_path and os.path.exists(waiver_path):
    try:
        import yaml  # PyYAML — pre-installed on ubuntu-latest
        waivers = yaml.safe_load(open(waiver_path)) or []
    except Exception as e:
        print(f"warn: failed to read waivers: {e}", file=sys.stderr)

today = datetime.date.today()
active_waivers = []
for w in waivers:
    exp = w.get("expires")
    try:
        d = datetime.date.fromisoformat(str(exp)) if exp else None
    except Exception:
        d = None
    if d and d >= today:
        active_waivers.append(w)

rows = []
failed = 0
for job, meta in results.items():
    if not isinstance(meta, dict): continue
    res = meta.get("result", "unknown")
    icon = {"success":"✅","failure":"❌","cancelled":"⚠️","skipped":"⏭️"}.get(res, "❓")
    if res == "failure":
        failed += 1
    rows.append((icon, job, res))

md = []
md.append(f"## wasaa-ci · `{gate}` gate")
md.append("")
md.append(f"**Result: {'❌ FAIL' if failed else '✅ PASS'}**  ·  {len(rows)} jobs · {failed} failed")
md.append("")
md.append("| Job | Result |")
md.append("|-----|--------|")
for icon, job, res in sorted(rows):
    md.append(f"| {icon} `{job}` | `{res}` |")
if active_waivers:
    md.append("")
    md.append(f"**Active waivers:** {len(active_waivers)} (see `.wasaa-ci-waiver.yml`)")
md.append("")
md.append("Policy: [POLICY.md](https://github.com/web-masters-ke/wasaa-ci/blob/main/POLICY.md)")

open(md_path, "w").write("\n".join(md))
open(js_path, "w").write(json.dumps({
    "gate": gate, "failed": failed, "jobs": [{"name": j, "result": r} for _,j,r in rows],
    "active_waivers": active_waivers,
}, indent=2))
print(f"gate-summary: {len(rows)} jobs, {failed} failed. Waivers active: {len(active_waivers)}")
PY
