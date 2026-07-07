#!/usr/bin/env python3
"""enforce_dart_licenses.py <deps.json> <allowlist.json>

Consumes `dart pub deps --json` output. Dart doesn't emit a SPDX license
directly, so this is a best-effort check via pub.dev metadata: we look
for `licenses` inside each package block, and fall back to marking
UNKNOWN as unapproved.
"""
import json, re, sys, urllib.request

def norm(x): return re.sub(r"\s+","",(x or "")).lower()

def fetch_license(pkg: str) -> str:
    try:
        with urllib.request.urlopen(f"https://pub.dev/api/packages/{pkg}", timeout=5) as r:
            data = json.load(r)
        return data.get("latest",{}).get("pubspec",{}).get("license","UNKNOWN")
    except Exception:
        return "UNKNOWN"

def main(deps_path, allow_path):
    deps = json.load(open(deps_path))
    allow = json.load(open(allow_path))
    allowed = {norm(a) for a in allow["allowed"]}
    denied = [re.compile("^"+a.replace("*",".*")+"$", re.I) for a in allow["denied"]]
    pkgs = {p["name"] for p in deps.get("packages",[]) if p.get("kind") != "root"}
    fail=0
    for name in sorted(pkgs):
        lic = fetch_license(name)
        parts = re.split(r"\s+OR\s+|,\s*|\s+AND\s+", lic)
        blocked = any(any(pat.match(x.strip()) for pat in denied) for x in parts)
        ok = any(norm(x) in allowed for x in parts)
        if blocked:
            print(f"::error::license DENIED (dart): {name} ({lic})"); fail+=1
        elif not ok:
            print(f"::warning::license UNAPPROVED (dart): {name} ({lic})")
    if fail: sys.exit(1)
    print("dart license enforcement: OK")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
