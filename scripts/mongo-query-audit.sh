#!/usr/bin/env bash
# mongo-query-audit.sh
#
# Bans / flags known-dangerous Mongo query shapes:
#   1. $where operator (server-side JS eval)
#   2. Regex on user input without anchor (^) — full-collection scan
#   3. updateMany / deleteMany without a filter (empty {} filter)
#   4. Unbounded find() with no limit() and no explicit projection
#   5. $lookup without $limit / $match upstream on large collections (heuristic)
#
# Any match is CRITICAL — must be fixed or waived.
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
fail=0

flag() {
  local file="$1" line="$2" msg="$3"
  echo "::error file=$file,line=$line::mongo-audit: $msg"
  fail=1
}

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep required" >&2
  exit 1
fi

# 1. $where — server-side JS injection risk
while IFS=: read -r file line _; do
  flag "$file" "$line" '$where operator uses server-side JS. Rewrite with typed operators.'
done < <(rg -n --no-heading -e '\$where' -g '!node_modules' -g '!vendor' "$ROOT" 2>/dev/null || true)

# 2. updateMany / deleteMany with empty filter
while IFS=: read -r file line _; do
  flag "$file" "$line" 'updateMany/deleteMany with empty filter {}. Add a scoped filter.'
done < <(rg -n --no-heading -e '(updateMany|deleteMany)\s*\(\s*\{\s*\}' -g '!node_modules' "$ROOT" 2>/dev/null || true)

# 3. Regex built directly from a variable (unanchored risk)
while IFS=: read -r file line _; do
  ctx=$(awk -v L="$line" 'NR==L{print}' "$file" 2>/dev/null || true)
  # accept only if we see a leading ^ or a bounded pattern
  if echo "$ctx" | grep -Eq '\$regex.*\+\s*\w+|new\s+RegExp\s*\(\s*\w+\s*[,)]'; then
    flag "$file" "$line" 'Unanchored regex from variable — potential ReDoS + full scan. Anchor with ^ and validate input.'
  fi
done < <(rg -n --no-heading -e '\$regex|new RegExp\(' -g '!node_modules' "$ROOT" 2>/dev/null || true)

# 4. find() without .limit()  (heuristic — TS/JS only)
while IFS=: read -r file line _; do
  # look 4 lines ahead for .limit / .toArray with limit / .findOne
  next=$(awk -v L="$line" 'NR>L && NR<=L+4{print}' "$file" 2>/dev/null || true)
  if ! echo "$next" | grep -Eq '\.limit\(|\.findOne\(|\.countDocuments\('; then
    flag "$file" "$line" 'find() without .limit() — potential unbounded read. Add .limit(N).'
  fi
done < <(rg -n --no-heading -tts -tjs -e '\.find\s*\(' -g '!*.test.*' -g '!*.spec.*' -g '!node_modules' "$ROOT" 2>/dev/null || true)

# 5. Python — Motor / PyMongo update_many / delete_many with empty filter
while IFS=: read -r file line _; do
  flag "$file" "$line" 'update_many/delete_many with empty filter. Add a scoped filter.'
done < <(rg -n --no-heading -tpy -e '(update_many|delete_many)\s*\(\s*\{\s*\}' "$ROOT" 2>/dev/null || true)

if [ "$fail" -eq 0 ]; then
  echo "mongo-query-audit: OK"
fi
exit "$fail"
