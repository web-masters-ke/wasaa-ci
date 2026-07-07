#!/usr/bin/env bash
# query-index-audit.sh — thin wrapper around query_index_audit.py.
# Exists so the CI workflow can invoke it consistently with the other
# audits.  Never blocks (MEDIUM severity by design).  See policy notes.
set -euo pipefail
python3 "$(dirname "$0")/query_index_audit.py" "${GITHUB_WORKSPACE:-$(pwd)}"
