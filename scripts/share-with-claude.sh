#!/usr/bin/env bash
# share-with-claude.sh <path-to-report-dir-or-artifact-zip>
#
# Emits the Claude-ready prompt block to stdout — for the times you want to
# pipe it directly into `pbcopy`, `xclip`, or `claude` CLI without opening
# report.md manually.
#
# Usage:
#   ./share-with-claude.sh ./wasaa-ci-report-fast/
#   ./share-with-claude.sh wasaa-ci-report-full.zip
#   ./share-with-claude.sh ./wasaa-ci-report-fast/ | pbcopy    # macOS
#   ./share-with-claude.sh ./wasaa-ci-report-fast/ | claude    # pipe into Claude Code
set -euo pipefail

src="${1:-}"
if [ -z "$src" ]; then
  echo "usage: $0 <report-dir-or-zip>" >&2
  exit 2
fi

tmp=""
cleanup() { [ -n "$tmp" ] && rm -rf "$tmp"; }
trap cleanup EXIT

if [ -f "$src" ] && [[ "$src" == *.zip ]]; then
  tmp=$(mktemp -d)
  unzip -qq "$src" -d "$tmp"
  dir="$tmp"
elif [ -d "$src" ]; then
  dir="$src"
else
  echo "not found: $src" >&2; exit 1
fi

if [ ! -f "$dir/report.md" ]; then
  echo "no report.md inside $dir" >&2; exit 1
fi

# Extract just the "Share with Claude" fenced block.
awk '
  /^### .*Share with Claude/ { found=1 }
  found && /^```text$/ { inblock=1; next }
  inblock && /^```$/ { inblock=0; done=1; next }
  inblock { print }
  END { exit (done ? 0 : 3) }
' "$dir/report.md" || {
  code=$?
  if [ "$code" = "3" ]; then
    echo "share-with-claude: no findings block in report.md (clean run?)" >&2
    exit 0
  fi
  exit "$code"
}
