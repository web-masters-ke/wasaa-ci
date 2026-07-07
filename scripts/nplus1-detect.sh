#!/usr/bin/env bash
# nplus1-detect.sh
#
# Heuristic N+1 detection across TS/Python/Dart/Go ORMs.
# Flags cases where a DB call happens INSIDE a loop over a previously
# fetched collection — the canonical N+1 shape.
#
# For each finding, tries to identify the enclosing route handler
# (Express, NestJS, FastAPI, Flask, Django, Gin, Echo, Fiber, Chi,
#  Shelf) and includes METHOD + PATH in the finding message. N+1s
# on API endpoints are P0; the same pattern in a background job is
# P2. This context lets triage prioritize correctly.
#
# Emits SARIF-lite JSON at ./nplus1.json + GH annotations. Exits 1
# on any finding. False positives are OK; false negatives are the enemy.
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
OUT="$ROOT/nplus1.json"

echo '{"tool":"wasaa-nplus1","findings":[' > "$OUT"
first=1

# ---------- Route-handler resolver ---------------------------------------
# Given (file, line), walk upward looking for the closest route/handler
# declaration within 120 lines. Returns "METHOD /path" or empty string.
# Frameworks covered:
#   Express/Fastify/Fiber JS   NestJS decorators   FastAPI decorators
#   Flask decorators           Django urls.py      Gin/Echo/Chi/Fiber Go
#   Dart Shelf
resolve_route() {
  local file="$1" line="$2"
  python3 - "$file" "$line" <<'PY' 2>/dev/null || true
import re, sys
path, ln = sys.argv[1], int(sys.argv[2])
try:
    lines = open(path, errors='replace').read().splitlines()
except Exception:
    sys.exit(0)
start = max(0, ln - 120)
window = lines[start:ln]
pats = [
    # 1. NestJS: @Get('/x') @Post() @Controller('/base')  (check FIRST so it wins over generic .get)
    (re.compile(r"^\s*@(Get|Post|Put|Patch|Delete|Head|Options|All)\s*\(\s*[`'\"]?([^`'\"()]*)"), True),
    # 2. FastAPI: @app.get("/x") @router.post("/x")
    (re.compile(r"^\s*@[a-zA-Z_][a-zA-Z0-9_]*\.(get|post|put|patch|delete)\s*\(\s*[`'\"]([^`'\"]+)"), True),
    # 3. Flask: @app.route("/x") @bp.route("/x")
    (re.compile(r"^\s*@[a-zA-Z_][a-zA-Z0-9_]*\.route\s*\(\s*[`'\"]([^`'\"]+)"), False),
    # 4. Django urls.py: path("users/", view)
    (re.compile(r"^\s*(?:path|re_path|url)\s*\(\s*[`'\"]([^`'\"]+)"), False),
    # 5. Go frameworks: r.GET("/x", ...) e.POST("/x", ...) app.Get("/x", ...)
    (re.compile(r"\b[a-zA-Z_][a-zA-Z0-9_]*\.(GET|POST|PUT|PATCH|DELETE|Get|Post|Put|Patch|Delete)\s*\(\s*\"([^\"]+)"), True),
    # 6. Express/Fastify/Fiber JS: app.get('/x', ...) router.post("/x", ...)
    (re.compile(r"\b[a-zA-Z_][a-zA-Z0-9_]*\.(get|post|put|patch|delete|head|options|all)\s*\(\s*[`'\"]([^`'\"]+)"), True),
]
best = None
best_line_no = -1
for i, l in enumerate(window):
    for pat, has_method in pats:
        m = pat.search(l)
        if m:
            if has_method:
                method = m.group(1).upper(); rpath = m.group(2) or "/"
            else:
                method = "ROUTE" if "route" in l.lower() else "PATH"
                rpath = m.group(1)
            # Prefer the LATEST (closest above the finding) match
            if i > best_line_no:
                best_line_no = i
                best = f"{method} {rpath}"
if best:
    print(best, end="")
PY
}

emit() {
  local file="$1" line="$2" pattern="$3" note="$4" sev="${5:-HIGH}"
  local route
  route=$(resolve_route "$file" "$line" || echo "")
  local endpoint_json=""
  local endpoint_annot=""
  if [ -n "$route" ]; then
    endpoint_json=",\"endpoint\":\"$(printf '%s' "$route" | sed 's/"/\\"/g')\""
    endpoint_annot=" [endpoint: $route]"
    # Endpoint N+1 is higher priority than background N+1
    sev="HIGH"
  fi
  local rel="${file#$ROOT/}"
  local comma=","
  [ $first -eq 1 ] && comma="" && first=0
  printf '%s{"file":"%s","line":%s,"pattern":"%s","note":"%s","severity":"%s"%s}\n' \
    "$comma" "$rel" "$line" "$pattern" "$(printf '%s' "$note" | sed 's/"/\\"/g')" "$sev" "$endpoint_json" >> "$OUT"
  echo "::error file=$rel,line=$line::N+1 ($sev)$endpoint_annot: $note"
}

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep required" >&2
  exit 1
fi

# -------- TypeScript / JavaScript --------
while IFS=: read -r file line _; do
  ctx=$(awk -v L="$line" 'NR>=L-6 && NR<=L{print}' "$file" 2>/dev/null || true)
  if echo "$ctx" | grep -Eq '(for\s*\(|forEach\s*\(|\.map\s*\(|while\s*\(|for\s+of\s+|for\s+in\s+)'; then
    emit "$file" "$line" "await-in-loop-ts" \
      "await on ORM inside iteration; likely N+1. Batch via findMany/whereIn/include."
  fi
done < <(rg -n --no-heading -tts -tjs \
    -e '\bawait\s+[\w.]+\.(findOne|findFirst|findUnique|findMany|find|get|aggregate|count|create|update|delete|save)\s*\(' \
    "$ROOT" 2>/dev/null || true)

# -------- Python — SQLAlchemy / Django / Tortoise --------
while IFS=: read -r file line _; do
  ctx=$(awk -v L="$line" 'NR>=L-6 && NR<=L{print}' "$file" 2>/dev/null || true)
  if echo "$ctx" | grep -Eq '^\s*(for\s+\w+\s+in|while\s+|\[\s*.+\s+for\s+.+\s+in|\{\s*.+\s+for\s+.+\s+in)'; then
    emit "$file" "$line" "orm-call-in-loop-py" \
      "ORM call inside a Python loop; likely N+1. Use joinedload/select_related/prefetch_related."
  fi
done < <(rg -n --no-heading -tpy \
    -e '\.(query|filter|filter_by|get|first|one|one_or_none|all|scalar|scalars|execute)\s*\(' \
    -e '\.objects\.(get|filter|all|create)\s*\(' \
    "$ROOT" 2>/dev/null || true)

# -------- Dart / Drift / Isar --------
while IFS=: read -r file line _; do
  ctx=$(awk -v L="$line" 'NR>=L-6 && NR<=L{print}' "$file" 2>/dev/null || true)
  if echo "$ctx" | grep -Eq '(for\s*\(|\.forEach\s*\(|\.map\s*\(|await\s+for)'; then
    emit "$file" "$line" "await-in-loop-dart" \
      "await on DB call inside iteration; likely N+1. Use join / joinAll."
  fi
done < <(rg -n --no-heading -tdart \
    -e '\bawait\s+\w+\.(select|getSingle|getSingleOrNull|get|findAll|findOne)\s*\(' \
    "$ROOT" 2>/dev/null || true)

# -------- Go — GORM / sqlx / database/sql --------
while IFS=: read -r file line _; do
  ctx=$(awk -v L="$line" 'NR>=L-6 && NR<=L{print}' "$file" 2>/dev/null || true)
  if echo "$ctx" | grep -Eq '^\s*for\s|^\s*for\s+_?,?\s*\w+\s*(:?=)\s*range'; then
    emit "$file" "$line" "db-call-in-loop-go" \
      "DB call inside a Go loop; likely N+1. Use IN(...) / Preload / joins / batching."
  fi
done < <(rg -n --no-heading -tgo \
    -e '\b[\w.]+\.(First|Find|Take|Last|FirstOrCreate|Preload|Where)\s*\(' \
    -e '\b[\w.]+\.(Query|QueryRow|QueryRowx|Get|Select|Exec|GetContext|SelectContext|QueryContext)\s*\(' \
    "$ROOT" 2>/dev/null || true)

echo ']}' >> "$OUT"

count=$(grep -c '"file"' "$OUT" 2>/dev/null || echo 0)
endpoint_count=$(grep -c '"endpoint"' "$OUT" 2>/dev/null || echo 0)
echo "N+1 heuristic: $count finding(s) ($endpoint_count on API endpoints) — see nplus1.json"

if [ "$count" -gt 0 ]; then
  echo "::error::N+1 heuristic tripped. Batch queries, add explicit include/join, or restructure. Endpoint-scoped findings are P0."
  exit 1
fi
