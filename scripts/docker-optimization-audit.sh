#!/usr/bin/env bash
# docker-optimization-audit.sh
#
# Best-practice checks on every Dockerfile in the repo. Complements hadolint;
# focuses on image-size + optimization rules hadolint doesn't enforce strictly.
#
# CRITICAL (must fix):
#   1. No multi-stage build AND base is not slim/alpine/distroless — final image will be huge.
#   2. ADD used for local files (should be COPY).
#   3. RUN apt-get without --no-install-recommends OR without cache cleanup.
#   4. Multiple RUN apt-get / apk / dnf calls that could be combined (layer bloat).
#   5. CMD in shell form (loses PID-1 signal handling).
#   6. Secret-shaped ARG or ENV (API_KEY, TOKEN, PASSWORD, SECRET as build-time args).
#   7. COPY of the whole repo (`COPY . .`) before dep-install step (breaks layer cache).
#
# HIGH:
#   8. Missing .dockerignore (bloats build context).
#   9. WORKDIR not set.
#  10. No EXPOSE declared.
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
fail=0

flag() {
  local file="$1" line="${2:-1}" msg="$3" sev="${4:-HIGH}"
  echo "::error file=$file,line=$line::docker-opt ($sev): $msg"
  [ "$sev" = "CRITICAL" ] || [ "$sev" = "HIGH" ] && fail=1 || true
}

warn() {
  local file="$1" line="${2:-1}" msg="$3"
  echo "::warning file=$file,line=$line::docker-opt: $msg"
}

dockerfiles=$(find "$ROOT" -type f \( -name 'Dockerfile' -o -name 'Dockerfile.*' -o -name '*.Dockerfile' \) \
  -not -path '*/node_modules/*' -not -path '*/vendor/*' -not -path '*/.git/*' -not -path '*/.wasaa-ci/*' 2>/dev/null || true)

if [ -z "$dockerfiles" ]; then
  echo "docker-opt: no Dockerfiles found — skipping."
  exit 0
fi

# ---- 8. .dockerignore presence (repo-level, not per-Dockerfile) --------------
if [ ! -f "$ROOT/.dockerignore" ]; then
  flag "$ROOT/.dockerignore" 1 ".dockerignore missing. Add one to avoid shipping node_modules/, .git/, coverage/, .env* into the build context." HIGH
else
  # Recommend minimum entries
  for pat in '.git' 'node_modules' '.env' 'coverage' 'dist' 'build' '.venv'; do
    if ! grep -Fqx "$pat" "$ROOT/.dockerignore" 2>/dev/null && ! grep -Fq "$pat/" "$ROOT/.dockerignore" 2>/dev/null; then
      warn "$ROOT/.dockerignore" 1 "$pat not in .dockerignore — recommended for smaller builds."
    fi
  done
fi

for df in $dockerfiles; do
  rel=$(realpath --relative-to="$ROOT" "$df" 2>/dev/null || echo "$df")

  # ---- 1. Multi-stage OR minimal base -----------------------------------------
  from_count=$(grep -cEi '^\s*FROM\s+' "$df" || echo 0)
  first_base=$(grep -Ei '^\s*FROM\s+' "$df" | head -1 | awk '{print $2}' | tr -d '"' || true)
  final_base=$(grep -Ei '^\s*FROM\s+' "$df" | tail -1 | awk '{print $2}' | tr -d '"' || true)
  is_minimal='no'
  case "$final_base" in
    *-slim*|*-alpine*|*distroless*|scratch|gcr.io/distroless/*|cgr.dev/chainguard/*)
      is_minimal='yes' ;;
  esac
  if [ "$from_count" -le 1 ] && [ "$is_minimal" = "no" ]; then
    flag "$rel" 1 "Single-stage build with a non-minimal base ($final_base). Use multi-stage OR switch to *-slim / *-alpine / distroless / chainguard." CRITICAL
  fi

  # ---- 2. ADD instead of COPY -------------------------------------------------
  awk '/^\s*ADD[[:space:]]+/ && $2 !~ /^https?:/ && $2 !~ /\.tar/ && $2 !~ /\.zip/ { print NR":"$0 }' "$df" | \
    while IFS=: read -r ln _; do
      flag "$rel" "$ln" "ADD used for local files. Use COPY (ADD auto-extracts tarballs and fetches URLs — surprising)." CRITICAL
    done

  # ---- 3. apt-get / apk / dnf hygiene ----------------------------------------
  awk '/^\s*RUN[[:space:]]/,/[^\\]$/ {print NR":"$0}' "$df" | grep -E 'apt-get\s+install' | while IFS=: read -r ln text; do
    if ! echo "$text" | grep -q -- '--no-install-recommends'; then
      flag "$rel" "$ln" "apt-get install without --no-install-recommends (pulls unnecessary deps, bloats image)." CRITICAL
    fi
    # cleanup must happen in the SAME RUN (otherwise cache stays in the layer)
    # look forward within the same RUN block for cleanup
    block=$(awk -v start="$ln" 'NR>=start { print; if ($NF !~ /\\$/) exit }' "$df")
    if ! echo "$block" | grep -Eq 'rm\s+-rf\s+/var/lib/apt/lists|apt-get\s+clean'; then
      flag "$rel" "$ln" "apt-get install without cache cleanup (rm -rf /var/lib/apt/lists/*) in the same RUN. Layer stays bloated." CRITICAL
    fi
  done
  # apk (Alpine)
  grep -nE 'apk\s+add' "$df" | while IFS=: read -r ln text; do
    if ! echo "$text" | grep -Eq -- '--no-cache|--virtual'; then
      flag "$rel" "$ln" "apk add without --no-cache. Cache stays in layer." HIGH
    fi
  done
  # dnf/yum
  grep -nE '(dnf|yum)\s+(install|-y install)' "$df" | while IFS=: read -r ln _; do
    block=$(awk -v start="$ln" 'NR>=start { print; if ($NF !~ /\\$/) exit }' "$df")
    if ! echo "$block" | grep -Eq '(dnf|yum)\s+clean\s+all|rm\s+-rf\s+/var/cache'; then
      flag "$rel" "$ln" "dnf/yum install without clean/rm in the same RUN." HIGH
    fi
  done

  # ---- 4. Multiple RUN apt-get calls that could be combined -------------------
  apt_runs=$(grep -cE '^\s*RUN.*apt-get' "$df" || echo 0)
  if [ "$apt_runs" -gt 2 ]; then
    flag "$rel" 1 "$apt_runs separate RUN apt-get statements — combine into one RUN to reduce layer count and image size." HIGH
  fi

  # ---- 5. CMD in shell form ---------------------------------------------------
  grep -nE '^\s*CMD\s+[^[]' "$df" | while IFS=: read -r ln _; do
    flag "$rel" "$ln" "CMD in shell form. Use exec form (JSON array) so PID 1 gets signals cleanly." HIGH
  done
  grep -nE '^\s*ENTRYPOINT\s+[^[]' "$df" | while IFS=: read -r ln _; do
    flag "$rel" "$ln" "ENTRYPOINT in shell form. Use exec form (JSON array) for proper signal handling." HIGH
  done

  # ---- 6. Secret-shaped ARG / ENV ---------------------------------------------
  grep -nEi '^\s*(ARG|ENV)\s+[A-Z0-9_]*(API_KEY|SECRET|PASSWORD|PASSWD|TOKEN|PRIVATE_KEY)' "$df" | while IFS=: read -r ln text; do
    flag "$rel" "$ln" "Secret-shaped ARG/ENV in Dockerfile — build args bake into image history. Use BuildKit --secret." CRITICAL
  done

  # ---- 7. COPY . . before dep-install ----------------------------------------
  # Find lines where COPY . . or COPY . /app happens BEFORE a package install RUN
  copy_all_lines=$(grep -nE '^\s*COPY\s+\.\s+' "$df" | cut -d: -f1 || true)
  for cln in $copy_all_lines; do
    # look forward for a package install
    tail_block=$(awk -v start="$cln" 'NR>start' "$df")
    if echo "$tail_block" | grep -Eiq 'RUN\s+(npm|pnpm|yarn|pip|poetry|uv|go\s+mod\s+download|go\s+build|composer|bundle|mvn|gradle)\s'; then
      flag "$rel" "$cln" "COPY . . happens before dependency install. Copy manifests (package*.json, requirements*.txt, go.mod, go.sum, pubspec.yaml) FIRST, install, THEN copy source — preserves layer cache." HIGH
    fi
  done

  # ---- 9. WORKDIR set --------------------------------------------------------
  if ! grep -Eq '^\s*WORKDIR\s+' "$df"; then
    flag "$rel" 1 "No WORKDIR declared. Explicit WORKDIR avoids surprises with relative paths." HIGH
  fi

  # ---- 10. EXPOSE declared ---------------------------------------------------
  if ! grep -Eq '^\s*EXPOSE\s+' "$df"; then
    warn "$rel" 1 "No EXPOSE declared. Document the listen port even though it's non-binding."
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "docker-opt: OK"
fi
exit "$fail"
