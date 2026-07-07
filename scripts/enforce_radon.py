#!/usr/bin/env python3
"""enforce_radon.py <radon.out> <max_cc>

Parses `radon cc -a -nc` output and fails on any function above <max_cc>.
"""
import re, sys

def main(path, max_cc):
    max_cc = int(max_cc)
    fail = 0
    for line in open(path):
        m = re.match(r"\s+([A-Z])\s+(\d+):(\d+)\s+(\S+)\s+-\s+(\d+)", line)
        if m:
            grade, lineno, col, name, cc = m.groups()
            if int(cc) > max_cc:
                print(f"::error file=?,line={lineno}::radon: {name} cyclomatic {cc} > {max_cc}")
                fail += 1
    if fail:
        print(f"radon gate failed: {fail} finding(s)"); sys.exit(1)
    print("radon gate: OK")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
