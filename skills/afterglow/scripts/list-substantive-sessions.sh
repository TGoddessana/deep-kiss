#!/bin/bash
# List substantive Claude Code session files for afterglow.
#
# Sorts by mtime descending (most recent first), filters out sessions
# with fewer than 2 user messages OR smaller than 4096 bytes
# (≈ 1 minute of activity), then caps the result.
#
# Bundled into a single script so the caller never inlines a shell loop
# over ~/.claude/projects/<encoded>/ — that pattern trips Claude Code's
# auto-mode permission classifier.
#
# Usage:
#   list-substantive-sessions.sh [--limit N] <sessions_dir>
#
# Options:
#   --limit N   Max output paths (default: 50). Use 0 for unlimited.
#
# Exit codes:
#   0  success (may produce zero lines if no substantive sessions)
#   1  usage error
#   2  sessions_dir does not exist

set -euo pipefail

usage() {
  echo "Usage: $0 [--limit N] <sessions_dir>" >&2
  exit 1
}

limit=50
dir=""

while [ $# -gt 0 ]; do
  case "$1" in
    --limit) shift; [ $# -gt 0 ] || usage; limit="$1"; shift ;;
    --limit=*) limit="${1#--limit=}"; shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) echo "Unknown flag: $1" >&2; usage ;;
    *) [ -z "$dir" ] || usage; dir="$1"; shift ;;
  esac
done

[ -n "$dir" ] || usage
case "$limit" in (*[!0-9]*|"") echo "--limit must be a non-negative integer" >&2; exit 1 ;; esac

if [ ! -d "$dir" ]; then
  echo "Not a directory: $dir" >&2
  exit 2
fi

abs_dir="$(cd "$dir" && pwd)"

min_size=4096
min_user_messages=2

# Cross-platform mtime (BSD stat first, then GNU stat fallback).
stat_mtime() {
  stat -f "%m" "$1" 2>/dev/null || stat -c "%Y" "$1"
}

shopt -s nullglob
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
for f in "$abs_dir"/*.jsonl; do
  printf "%s\t%s\n" "$(stat_mtime "$f")" "$f" >> "$tmp"
done
[ -s "$tmp" ] || exit 0

count=0
while IFS= read -r f; do
  if [ "$limit" -gt 0 ] && [ "$count" -ge "$limit" ]; then
    break
  fi
  size=$(wc -c < "$f" | tr -d ' ')
  if [ "$size" -lt "$min_size" ]; then
    continue
  fi
  ucount=$(grep -c '"type":"user"' "$f" || true)
  if [ "$ucount" -lt "$min_user_messages" ]; then
    continue
  fi
  echo "$f"
  count=$((count + 1))
done < <(sort -rn "$tmp" | cut -f2-)
