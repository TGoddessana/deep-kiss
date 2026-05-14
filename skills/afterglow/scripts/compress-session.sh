#!/bin/bash
# L2 compression for Claude Code session JSONL → afterglow harvester input.
#
# Drops JSONL structural fields, thinking blocks, tool_result content.
# Keeps user text (≤500 chars), assistant text (≤300 chars), tool names.
# Typical compression on substantive sessions: 40–50× (e.g. 900KB → ~17KB).
#
# Usage:
#   compress-session.sh <session.jsonl>            # stdout
#   compress-session.sh <session.jsonl> <outfile>  # write to file

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <session.jsonl> [outfile]" >&2
  exit 1
fi

src="$1"
if [ ! -f "$src" ]; then
  echo "Not a file: $src" >&2
  exit 1
fi

filter='
  select(.type=="user" or .type=="assistant") |
  if .type=="user" then
    (.message.content // "") |
    if type=="string" then
      "[User]: " + .[0:500]
    else
      map(select(.type=="text")) |
      map("[User]: " + (.text[0:500])) |
      join("\n")
    end
  else
    (.message.content // []) |
    map(
      if .type=="text" then "[Assistant]: " + (.text[0:300])
      elif .type=="tool_use" then "[Tool: " + .name + "]"
      else empty
      end
    ) |
    join("\n")
  end |
  select(. != "")
'

if [ $# -eq 2 ]; then
  jq -r "$filter" "$src" > "$2"
else
  jq -r "$filter" "$src"
fi
