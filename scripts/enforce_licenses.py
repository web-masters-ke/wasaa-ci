#!/usr/bin/env python3
"""enforce_licenses.py <licenses.json> <allowlist.json>

Reads pip-licenses JSON output and enforces the org allowlist.
"""
import json, re, sys

def norm(x: str) -> str:
    return re.sub(r"\s+", "", (x or "")).lower()

def main(lic_path: str, allow_path: str) -> int:
    licenses = json.load(open(lic_path))
    allow = json.load(open(allow_path))
    allowed = {norm(a) for a in allow["allowed"]}
    denied = [re.compile("^" + a.replace("*", ".*") + "$", re.I) for a in allow["denied"]]
    fail = 0
    for p in licenses:
        name = p.get("Name", "<unknown>")
        lic = p.get("License", "UNKNOWN")
        parts = re.split(r"\s+OR\s+|,\s*|\s+AND\s+", lic)
        blocked = any(any(pat.match(x.strip()) for pat in denied) for x in parts)
        ok = any(norm(x) in allowed for x in parts)
        if blocked:
            print(f"::error::license DENIED: {name} ({lic})"); fail += 1
        elif not ok:
            print(f"::error::license UNAPPROVED: {name} ({lic}) — request Legal review or add to allowlist"); fail += 1
    if fail:
        print(f"license enforcement failed: {fail} package(s)"); return 1
    print("license enforcement: OK")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
