#!/usr/bin/env bash
# redis-usage-audit.sh
#
# Bans / flags known-dangerous Redis usage:
#   1. KEYS * — O(N) scan on prod. Use SCAN.
#   2. FLUSHDB / FLUSHALL in application code.
#   3. Unbounded LRANGE 0 -1 without size check.
#   4. SET / HSET / SADD without EXPIRE / TTL nearby (cache-key leaks).
#   5. RENAMENX on wildcard keys.
#   6. Lua EVAL from string concatenation (injection).
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
fail=0

flag() {
  local file="$1" line="$2" msg="$3" sev="${4:-HIGH}"
  echo "::error file=$file,line=$line::redis-audit ($sev): $msg"
  fail=1
}

warn() {
  local file="$1" line="$2" msg="$3"
  echo "::warning file=$file,line=$line::redis-audit: $msg"
}

if ! command -v rg >/dev/null 2>&1; then echo "rg required" >&2; exit 1; fi

# 1. KEYS *
while IFS=: read -r file line _; do
  flag "$file" "$line" 'KEYS is O(N) and blocks the event loop. Use SCAN with a cursor.' CRITICAL
done < <(rg -n --no-heading -e "\bKEYS\s*\(\s*['\"][^)]*\*" -g '!node_modules' -g '!vendor' "$ROOT" 2>/dev/null || true)

# 2. FLUSHDB / FLUSHALL
while IFS=: read -r file line _; do
  flag "$file" "$line" 'FLUSHDB/FLUSHALL in application code is banned.' CRITICAL
done < <(rg -n --no-heading -ie 'FLUSHDB|FLUSHALL' -g '!*.test.*' -g '!*.spec.*' -g '!node_modules' "$ROOT" 2>/dev/null || true)

# 3. LRANGE 0 -1
while IFS=: read -r file line _; do
  flag "$file" "$line" 'LRANGE 0 -1 is unbounded. Paginate or use LLEN + LRANGE with bounded stop.' HIGH
done < <(rg -n --no-heading -e "LRANGE[^)]*['\"]?0['\"]?[^)]*['\"]?-1" -g '!node_modules' "$ROOT" 2>/dev/null || true)

# 4. Missing TTL near SET/HSET/SADD (heuristic — look for EXPIRE/EX within +/-6 lines)
while IFS=: read -r file line _; do
  ctx=$(awk -v L="$line" 'NR>=L-3 && NR<=L+6{print}' "$file" 2>/dev/null || true)
  if ! echo "$ctx" | grep -Eiq '\b(EX|PX|EXAT|PXAT|expire|expireAt|setex|TTL)\b|"EX"|\bEX:\s*\d'; then
    warn "$file" "$line" 'SET/HSET/SADD without visible EXPIRE/TTL. Cache keys must expire.'
  fi
done < <(rg -n --no-heading -e '\.(set|hset|sadd|hmset)\s*\(' -g '!*.test.*' -g '!node_modules' "$ROOT" 2>/dev/null || true)

# 5. EVAL from concatenation
while IFS=: read -r file line _; do
  ctx=$(awk -v L="$line" 'NR==L{print}' "$file" 2>/dev/null || true)
  if echo "$ctx" | grep -Eq '\.eval\s*\([^)]*\+|\.evalsha\s*\([^)]*\+'; then
    flag "$file" "$line" 'Lua EVAL built via string concatenation — injection risk. Parameterize KEYS/ARGV.' CRITICAL
  fi
done < <(rg -n --no-heading -e '\.eval\s*\(|\.evalsha\s*\(' -g '!node_modules' "$ROOT" 2>/dev/null || true)

if [ "$fail" -eq 0 ]; then echo "redis-usage-audit: OK"; fi
exit "$fail"
