#!/usr/bin/env python3
"""enforce_go_licenses.py <licenses.(json|csv)> <allowlist.json>

Consumes `go-licenses` output — JSON via a template, or CSV fallback:
  <module>,<license URL>,<SPDX id or best guess>
Enforces the shared allowlist.
"""
import csv, json, re, sys, os

def norm(x): return re.sub(r"\s+", "", (x or "")).lower()

def parse(path):
    if path.endswith(".json"):
        return [(p["name"], p.get("license","UNKNOWN")) for p in json.load(open(path))]
    out=[]
    for row in csv.reader(open(path)):
        if len(row) >= 3:
            out.append((row[0], row[2]))
        elif len(row) == 2:
            out.append((row[0], "UNKNOWN"))
    return out

def main(lic_path, allow_path):
    allow = json.load(open(allow_path))
    allowed = {norm(a) for a in allow["allowed"]}
    denied = [re.compile("^"+a.replace("*",".*")+"$", re.I) for a in allow["denied"]]
    fail = 0
    for name, lic in parse(lic_path):
        parts = re.split(r"\s+OR\s+|,\s*|\s+AND\s+", lic or "UNKNOWN")
        blocked = any(any(pat.match(x.strip()) for pat in denied) for x in parts)
        ok = any(norm(x) in allowed for x in parts)
        if blocked:
            print(f"::error::license DENIED (go): {name} ({lic})"); fail += 1
        elif not ok:
            print(f"::error::license UNAPPROVED (go): {name} ({lic}) — Legal review or add to allowlist"); fail += 1
    if fail: sys.exit(1)
    print("go license enforcement: OK")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
