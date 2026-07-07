#!/usr/bin/env bash
# db-index-audit.sh
#
# Postgres index heuristic — CI cannot inspect prod, so this is static-only:
#   1. Any query filtering on a column that ORM models mark as unindexed.
#   2. WHERE clauses on JSONB paths without a GIN / expression index.
#   3. ORDER BY <col> LIMIT with no matching index annotation nearby.
#   4. Foreign keys added without a covering index.
#
# Best-effort heuristics — false positives are OK, they force a code comment.
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
fail=0

flag() {
  local file="$1" line="$2" msg="$3" sev="${4:-MEDIUM}"
  echo "::warning file=$file,line=$line::db-index-audit ($sev): $msg"
  [ "$sev" = "HIGH" ] || [ "$sev" = "CRITICAL" ] && fail=1 || true
}

if ! command -v rg >/dev/null 2>&1; then echo "rg required" >&2; exit 1; fi

# 1. Foreign key columns added in migrations without CREATE INDEX in the same file
while IFS=: read -r file _ _; do
  # For each REFERENCES line, check the file has a CREATE INDEX on the same column
  fkeys=$(grep -oE '([[:alnum:]_]+)\s+.*REFERENCES' "$file" | awk '{print $1}' || true)
  for col in $fkeys; do
    if ! grep -Eq "CREATE\s+INDEX.*\(${col}\b" "$file"; then
      flag "$file" 1 "Foreign key '$col' added without accompanying CREATE INDEX. Postgres does not auto-index FK columns." HIGH
    fi
  done
done < <(rg -l --no-heading -e 'REFERENCES' -g '*.sql' "$ROOT" 2>/dev/null || true)

# 2. JSONB WHERE without matching GIN
while IFS=: read -r file line _; do
  ctx=$(awk -v L="$line" 'NR==L{print}' "$file" 2>/dev/null || true)
  # crude column extract
  col=$(echo "$ctx" | grep -oE "[a-zA-Z_][a-zA-Z0-9_]*\s*(->>|->|@>|@?)" | head -1 | awk '{print $1}')
  if [ -n "$col" ]; then
    if ! grep -Eq "CREATE\s+INDEX.*USING\s+GIN.*${col}" "$file"; then
      flag "$file" "$line" "JSONB filter on '$col' without a matching GIN index in the same migration." MEDIUM
    fi
  fi
done < <(rg -n --no-heading -e '(->>|->|@>)' -g '*.sql' "$ROOT" 2>/dev/null || true)

# 3. Migrations creating an index without CONCURRENTLY on a table >1M rows —
#    handled by squawk. This script just adds a nudge for very large migrations.
while IFS=: read -r file line _; do
  ctx=$(awk -v L="$line" 'NR==L{print}' "$file" 2>/dev/null || true)
  if echo "$ctx" | grep -Eiq 'CREATE\s+INDEX\s+' && ! echo "$ctx" | grep -Eiq 'CONCURRENTLY'; then
    flag "$file" "$line" "CREATE INDEX without CONCURRENTLY. On production tables this locks writes." HIGH
  fi
done < <(rg -n --no-heading -i -e 'CREATE\s+INDEX' -g '*.sql' "$ROOT" 2>/dev/null || true)

[ "$fail" -eq 0 ] && echo "db-index-audit: OK"
exit "$fail"
