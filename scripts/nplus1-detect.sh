#!/usr/bin/env bash
# nplus1-detect.sh
#
# Heuristic N+1 detection across TS/Python/Dart ORMs.
# Flags cases where an async/await DB call happens INSIDE a loop over
# a previously fetched collection — the canonical N+1 shape.
#
# Emits SARIF-lite JSON at ./nplus1.json and a human summary. Exits 1 on any
# high-confidence finding.
#
# Intentionally strict/regex-based: false positives are fine, they force
# authors to add a comment or restructure. False negatives are the enemy.
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
OUT="$ROOT/nplus1.json"
: > "$OUT"

echo '{"tool":"wasaa-nplus1","findings":[' > "$OUT"
first=1

emit() {
  local file="$1" line="$2" pattern="$3" note="$4"
  local comma=","
  [ $first -eq 1 ] && comma="" && first=0
  printf '%s{"file":"%s","line":%s,"pattern":"%s","note":"%s","severity":"HIGH"}' \
    "$comma" "$file" "$line" "$pattern" "$note" >> "$OUT"
}

# -------- TypeScript / JavaScript --------
# await X.find/findOne/findMany/findUnique/get/aggregate inside a for/forEach/map/while
if command -v rg >/dev/null 2>&1; then
  # Prisma / TypeORM / Sequelize / Mongoose common shapes
  while IFS=: read -r file line _; do
    ctx=$(awk -v L="$line" 'NR>=L-6 && NR<=L{print}' "$file" 2>/dev/null || true)
    if echo "$ctx" | grep -Eq '(for\s*\(|forEach\s*\(|\.map\s*\(|while\s*\()'; then
      emit "$file" "$line" "await-in-loop-ts" "await on ORM inside iteration; likely N+1. Batch via findMany/whereIn/include."
    fi
  done < <(rg -n --no-heading -tts -tjs \
      -e '\bawait\s+\w+\.(findOne|findFirst|findUnique|findMany|find|get|aggregate|count)\s*\(' \
      "$ROOT" 2>/dev/null || true)

  # -------- Python — SQLAlchemy / Django / Tortoise --------
  while IFS=: read -r file line _; do
    ctx=$(awk -v L="$line" 'NR>=L-6 && NR<=L{print}' "$file" 2>/dev/null || true)
    if echo "$ctx" | grep -Eq '^\s*(for\s+\w+\s+in|while\s+)'; then
      emit "$file" "$line" "orm-call-in-loop-py" "ORM call inside a Python loop; likely N+1. Use joinedload/select_related/prefetch_related."
    fi
  done < <(rg -n --no-heading -tpy \
      -e '\.(query|filter|get|first|one|all|scalar|scalars|execute)\s*\(' \
      -e '\.objects\.(get|filter|all)\s*\(' \
      "$ROOT" 2>/dev/null || true)

  # -------- Dart / Drift / Isar --------
  while IFS=: read -r file line _; do
    ctx=$(awk -v L="$line" 'NR>=L-6 && NR<=L{print}' "$file" 2>/dev/null || true)
    if echo "$ctx" | grep -Eq '(for\s*\(|\.forEach\s*\(|\.map\s*\(|await\s+for)'; then
      emit "$file" "$line" "await-in-loop-dart" "await on DB call inside iteration; likely N+1. Use join / joinAll."
    fi
  done < <(rg -n --no-heading -tdart \
      -e '\bawait\s+\w+\.(select|getSingle|getSingleOrNull|get|findAll|findOne)\s*\(' \
      "$ROOT" 2>/dev/null || true)

  # -------- Go — GORM / sqlx / database/sql --------
  # DB call inside a for/range loop is the canonical N+1 in Go.
  while IFS=: read -r file line _; do
    ctx=$(awk -v L="$line" 'NR>=L-6 && NR<=L{print}' "$file" 2>/dev/null || true)
    if echo "$ctx" | grep -Eq '^\s*for\s|^\s*for\s+_?,?\s*\w+\s*(:?=)\s*range'; then
      emit "$file" "$line" "db-call-in-loop-go" "DB call inside a Go loop; likely N+1. Use IN(...) / Preload / joins / batching."
    fi
  done < <(rg -n --no-heading -tgo \
      -e '\.(First|Find|Take|Last|FirstOrCreate|Preload|Where)\s*\(' \
      -e '\.(Query|QueryRow|QueryRowx|Get|Select|Exec|GetContext|SelectContext|QueryContext)\s*\(' \
      "$ROOT" 2>/dev/null || true)
else
  echo "ripgrep not available — skipping N+1 heuristic" >&2
fi

echo ']}' >> "$OUT"

count=$(grep -c '"file"' "$OUT" || echo 0)
echo "N+1 heuristic: $count finding(s) — see nplus1.json"
if [ "$count" -gt 0 ]; then
  echo "::error::N+1 heuristic tripped. Batch your queries or add an explicit include/join. See nplus1.json."
  # Render annotations
  python3 - <<'PY' || true
import json,sys
d=json.load(open("nplus1.json"))
for f in d.get("findings",[]):
    print(f"::error file={f['file']},line={f['line']}::N+1 candidate: {f['note']}")
PY
  exit 1
fi
