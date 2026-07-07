#!/usr/bin/env python3
"""build_report.py <findings_dir> <out_dir>

Consolidates every SARIF and JSON artifact produced by the gate into:
  - report/findings.sarif   — merged SARIF (viewable in any SARIF viewer / GH code scanning)
  - report/findings.json    — machine-readable normalized findings
  - report/report.md        — sticky PR comment (concise summary)
  - report/index.html       — single-file HTML dashboard viewable from artifacts

Also used by the claude-autofix loop to know what's still failing.
"""
import json, os, sys, glob, html, re, datetime
from collections import defaultdict, Counter

SEV_ORDER = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3, "NOTE": 4, "INFO": 4}
SEV_COLOR = {"CRITICAL": "#c62828", "HIGH": "#e65100", "MEDIUM": "#f9a825",
             "LOW": "#558b2f", "NOTE": "#455a64", "INFO": "#455a64"}

def norm_sev(s):
    if not s: return "NOTE"
    s = s.upper()
    return {"ERROR":"CRITICAL","WARNING":"HIGH","NOTE":"LOW","NONE":"NOTE"}.get(s, s)

def load_sarifs(root):
    findings = []
    for p in glob.glob(os.path.join(root, "**", "*.sarif"), recursive=True):
        try:
            d = json.load(open(p))
        except Exception as e:
            print(f"warn: {p}: {e}", file=sys.stderr); continue
        tool_hint = os.path.basename(p).replace(".sarif","")
        for run in d.get("runs", []):
            tool = run.get("tool",{}).get("driver",{}).get("name", tool_hint)
            rules = {r["id"]: r for r in run.get("tool",{}).get("driver",{}).get("rules",[])}
            for r in run.get("results", []):
                rule_id = r.get("ruleId","")
                level = r.get("level") or rules.get(rule_id,{}).get("defaultConfiguration",{}).get("level")
                sev = norm_sev(level)
                # Bump security-critical tools to their appropriate severity
                if tool.lower() in ("gitleaks","trufflehog") and sev not in ("CRITICAL","HIGH"):
                    sev = "CRITICAL"
                loc = (r.get("locations") or [{}])[0].get("physicalLocation",{})
                uri = loc.get("artifactLocation",{}).get("uri","")
                region = loc.get("region",{})
                findings.append({
                    "tool": tool, "rule": rule_id, "severity": sev,
                    "file": uri, "line": region.get("startLine"),
                    "message": (r.get("message",{}).get("text") or "").strip(),
                    "source": os.path.relpath(p, root),
                })
    return findings

def load_extras(root):
    """Consume gate-summary.json and any tool-native JSON (semgrep.json, nplus1.json, query-index.json, etc.)"""
    extras = []
    # nplus1
    for p in glob.glob(os.path.join(root, "**", "nplus1.json"), recursive=True):
        try:
            d = json.load(open(p))
            for f in d.get("findings", []):
                endpoint = f.get("endpoint")
                msg = f.get("note","")
                if endpoint: msg = f"[endpoint: {endpoint}] {msg}"
                extras.append({
                    "tool":"wasaa-nplus1","rule":f.get("pattern","nplus1"),
                    "severity":(f.get("severity") or "HIGH").upper(),
                    "file":f.get("file",""),"line":f.get("line"),
                    "message":msg,"source":os.path.relpath(p,root),
                })
        except Exception: pass
    # query-index audit
    for p in glob.glob(os.path.join(root, "**", "query-index.json"), recursive=True):
        try:
            d = json.load(open(p))
            for f in d.get("findings", []):
                extras.append({
                    "tool":"wasaa-query-index","rule":"missing-index",
                    "severity":(f.get("severity") or "MEDIUM").upper(),
                    "file":f.get("file",""),"line":f.get("line"),
                    "message":f.get("note",""),"source":os.path.relpath(p,root),
                })
        except Exception: pass
    return extras

def render_md(all_findings, gate, repo, sha, run_id):
    total = len(all_findings)
    by_sev = Counter(f["severity"] for f in all_findings)
    by_tool = Counter(f["tool"] for f in all_findings)
    critical = by_sev.get("CRITICAL",0)
    high = by_sev.get("HIGH",0)
    verdict = ("PASS" if (critical==0 and (gate=="fast" or high==0)) else "FAIL")

    lines = []
    lines.append(f"## wasaa-ci · `{gate}` gate · **{'✅ PASS' if verdict=='PASS' else '❌ FAIL'}**")
    lines.append("")
    lines.append(f"`{repo}` @ `{sha[:8]}` · [Run {run_id}](https://github.com/{repo}/actions/runs/{run_id})")
    lines.append("")
    lines.append(f"| Severity | Count |")
    lines.append(f"|----------|-------|")
    for s in ["CRITICAL","HIGH","MEDIUM","LOW","NOTE"]:
        if by_sev.get(s): lines.append(f"| {s} | {by_sev[s]} |")
    lines.append("")
    if by_tool:
        lines.append("**By tool:** " + ", ".join(f"{t}={n}" for t,n in by_tool.most_common()))
        lines.append("")
    # Top 15 blocking findings
    blocking = [f for f in all_findings if f["severity"] in ("CRITICAL","HIGH")]
    if blocking:
        lines.append("### Top blocking findings")
        lines.append("")
        for f in sorted(blocking, key=lambda x: SEV_ORDER[x["severity"]])[:15]:
            loc = f"`{f['file']}:{f['line']}`" if f.get("file") else ""
            lines.append(f"- **{f['severity']}** `{f['tool']}/{f['rule']}` {loc} — {f['message'][:200]}")
        lines.append("")

    # ---- Copy-pasteable block for Claude ------------------------------------
    # Everything below is a self-contained prompt the developer can paste into
    # Claude Code / claude.ai to get a targeted fix plan for their repo.
    if blocking:
        lines.append("---")
        lines.append("")
        lines.append("### 📋 Share with Claude (copy the block below)")
        lines.append("")
        lines.append("Paste the fenced block into Claude Code (in the failing repo's working dir) or claude.ai. It contains the failing findings only — trimmed to fit in a single message.")
        lines.append("")
        lines.append("```text")
        lines.append(f"I need to fix wasaa-ci gate findings in `{repo}` at commit {sha[:8]}. Full CI run: https://github.com/{repo}/actions/runs/{run_id}")
        lines.append("")
        lines.append(f"Gate: {gate} · Verdict: {'PASS' if verdict=='PASS' else 'FAIL'} · Findings: {total} ({by_sev.get('CRITICAL',0)} CRITICAL, {by_sev.get('HIGH',0)} HIGH, {by_sev.get('MEDIUM',0)} MEDIUM)")
        lines.append("")
        lines.append("Ground rules (from wasaa-ci POLICY.md — do not violate):")
        lines.append("- No `eslint-disable` / `# noqa` / `# nosec` / `//nolint` / `nosemgrep:` suppression comments.")
        lines.append("- No widening to `any` / `interface{}` / `dynamic` to bypass type errors.")
        lines.append("- No deleting tests or lowering coverage thresholds.")
        lines.append("- No removing NOT NULL / UNIQUE / FK constraints to bypass migration linters.")
        lines.append("- Do not edit `.github/workflows/**` or `.wasaa-ci-waiver.yml` — those are CI/policy, not code.")
        lines.append("")
        lines.append("Findings to fix (severity | tool/rule | location | message):")
        for f in sorted(blocking, key=lambda x: (SEV_ORDER[x["severity"]], x.get("file") or "", x.get("line") or 0))[:40]:
            loc = f"{f.get('file','')}:{f.get('line') or ''}"
            msg = (f.get('message') or '').replace('\n', ' ').strip()[:220]
            lines.append(f"- {f['severity']} | {f['tool']}/{f['rule']} | {loc} | {msg}")
        lines.append("")
        lines.append("Please:")
        lines.append("1. Group findings by root cause where possible (multiple hits from one bug).")
        lines.append("2. For each group, propose the minimum fix that resolves the underlying issue.")
        lines.append("3. Show me the exact diff (file + before/after) for each fix.")
        lines.append("4. If any finding is a genuine false positive, say so and explain why — do NOT suggest suppression.")
        lines.append("5. If a fix requires policy/waiver approval, flag it and stop on that one.")
        lines.append("```")
        lines.append("")
        lines.append("Need the complete finding set (not just the top 40)? Download the `wasaa-ci-report-" + gate + "` artifact and attach `findings.json` to your Claude conversation.")
        lines.append("")

    lines.append(f"Full report: download the `wasaa-ci-report-{gate}` artifact from the run.")
    return "\n".join(lines)

def render_html(all_findings, gate, repo, sha, run_id):
    total = len(all_findings)
    by_sev = Counter(f["severity"] for f in all_findings)
    by_tool = Counter(f["tool"] for f in all_findings)
    grouped = defaultdict(list)
    for f in all_findings: grouped[(f["severity"], f["tool"])].append(f)
    rows = []
    for f in sorted(all_findings, key=lambda x: (SEV_ORDER.get(x["severity"],9), x["tool"], x.get("file",""), x.get("line") or 0)):
        color = SEV_COLOR.get(f["severity"], "#455a64")
        loc = f"{html.escape(f.get('file') or '')}:{f.get('line') or ''}"
        rows.append(f"""<tr>
          <td><span class="sev" style="background:{color}">{f['severity']}</span></td>
          <td><code>{html.escape(f['tool'])}</code></td>
          <td><code>{html.escape(f['rule'] or '')}</code></td>
          <td><code>{loc}</code></td>
          <td>{html.escape(f['message'][:400])}</td>
        </tr>""")
    sev_pills = " ".join(
        f'<span class="pill" style="background:{SEV_COLOR.get(s,"#455a64")}">{s} · {by_sev.get(s,0)}</span>'
        for s in ["CRITICAL","HIGH","MEDIUM","LOW","NOTE"] if by_sev.get(s)
    )
    tool_pills = " ".join(f'<span class="pill" style="background:#37474f">{html.escape(t)} · {n}</span>' for t,n in by_tool.most_common())
    critical = by_sev.get("CRITICAL",0); high = by_sev.get("HIGH",0)
    verdict = "PASS" if (critical==0 and (gate=="fast" or high==0)) else "FAIL"
    verdict_color = "#2e7d32" if verdict=="PASS" else "#c62828"
    now = datetime.datetime.utcnow().isoformat(timespec="seconds")+"Z"
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>wasaa-ci · {gate} · {html.escape(repo)}</title>
<style>
 body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 0; padding: 24px; background:#f5f5f7; color:#1c1c1e; }}
 h1 {{ margin: 0 0 8px; font-size: 22px; }}
 .verdict {{ display:inline-block; padding: 6px 14px; border-radius: 6px; color:white; background:{verdict_color}; font-weight:600; letter-spacing:.5px; }}
 .meta {{ color:#5f6368; font-size:13px; margin-bottom:16px }}
 .pill {{ display:inline-block; padding:4px 10px; border-radius:14px; color:white; margin:2px 4px 2px 0; font-size:12px; }}
 .sev {{ display:inline-block; padding:2px 8px; border-radius:4px; color:white; font-size:11px; font-weight:600; }}
 table {{ width:100%; border-collapse: collapse; background:white; border-radius:8px; overflow:hidden; box-shadow: 0 1px 3px rgba(0,0,0,.06); }}
 th, td {{ padding: 10px 12px; text-align: left; border-bottom: 1px solid #eee; font-size:13px; vertical-align: top; }}
 th {{ background:#fafafa; font-weight:600; }}
 code {{ background:#f0f0f4; padding: 1px 5px; border-radius:3px; font-size: 12px; }}
 .filter {{ margin: 12px 0; }}
 .filter input {{ width:100%; padding:8px 10px; border:1px solid #ddd; border-radius:6px; font-size:13px; }}
</style></head>
<body>
 <h1>wasaa-ci · {gate} gate · <span class="verdict">{verdict}</span></h1>
 <div class="meta">
  <strong>{html.escape(repo)}</strong> @ <code>{sha[:12]}</code> ·
  <a href="https://github.com/{html.escape(repo)}/actions/runs/{run_id}">Run {run_id}</a> ·
  Generated {now} · {total} finding(s)
 </div>
 <div>{sev_pills}</div>
 <div style="margin-top:6px">{tool_pills}</div>
 <div class="filter"><input id="q" placeholder="Filter by tool, rule, file, message…" oninput="filterRows(this.value)"></div>
 <table id="t">
  <thead><tr><th>Severity</th><th>Tool</th><th>Rule</th><th>Location</th><th>Message</th></tr></thead>
  <tbody>{''.join(rows) or '<tr><td colspan=5 style="text-align:center;padding:24px;color:#5f6368">No findings — clean run.</td></tr>'}</tbody>
 </table>
<script>
 function filterRows(q) {{
   q = q.toLowerCase();
   for (const row of document.querySelectorAll('#t tbody tr')) {{
     row.style.display = row.textContent.toLowerCase().includes(q) ? '' : 'none';
   }}
 }}
</script>
</body></html>"""

def merge_sarif(root, out_path):
    merged = {"$schema":"https://json.schemastore.org/sarif-2.1.0.json","version":"2.1.0","runs":[]}
    for p in glob.glob(os.path.join(root, "**", "*.sarif"), recursive=True):
        try:
            d = json.load(open(p))
            merged["runs"].extend(d.get("runs",[]))
        except Exception: pass
    json.dump(merged, open(out_path, "w"), indent=2)

def main(root, out):
    os.makedirs(out, exist_ok=True)
    findings = load_sarifs(root) + load_extras(root)
    json.dump(findings, open(os.path.join(out,"findings.json"),"w"), indent=2)
    merge_sarif(root, os.path.join(out,"findings.sarif"))
    gate = os.environ.get("GATE","fast")
    repo = os.environ.get("REPO","local/repo")
    sha  = os.environ.get("SHA","0"*40)
    run_id = os.environ.get("RUN_ID","0")
    open(os.path.join(out,"report.md"),"w").write(render_md(findings, gate, repo, sha, run_id))
    open(os.path.join(out,"index.html"),"w").write(render_html(findings, gate, repo, sha, run_id))
    print(f"report: {len(findings)} finding(s) written to {out}")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
