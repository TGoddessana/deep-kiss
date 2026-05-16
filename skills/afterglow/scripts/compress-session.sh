#!/bin/bash
# L2 compression for Claude Code session JSONL → afterglow harvester input.
#
# Drops JSONL structural fields, thinking blocks, tool_result content.
# Keeps user text (≤500 chars), assistant text (≤300 chars), tool names.
# Typical compression on substantive sessions: 40–50× (e.g. 900KB → ~17KB).
#
# Slash-command normalization (signal/noise cleanup for the analyst):
#   - <local-command-caveat>…</local-command-caveat>  → dropped (system meta).
#   - <command-name>/X</command-name>…<command-args>Y</command-args>
#       → "[User-cmd]: /X Y"  (one line; args optional)
#   - Injected SKILL.md body (text block starting with
#     "Base directory for this skill: …/skills/<name>" and ending with
#     "ARGUMENTS: <args>")
#       → "[SkillBody: <name>]\n[User-args]: <args>"
#       (SkillBody is auto-injected, NOT user-typed; do not let the analyst
#        treat phrases inside it as user signal.)
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
      if startswith("<local-command-caveat>") then
        ""
      elif startswith("<command-") then
        ((try capture("<command-name>(?<cmd>[^<]+)</command-name>") catch {cmd:""}) | .cmd) as $cmd
        | ((try capture("<command-args>(?<args>[^<]*)</command-args>") catch {args:""}) | .args) as $args
        | if ($cmd | length) == 0 then
            "[User-cmd]: " + .[0:200]
          elif ($args | length) == 0 then
            "[User-cmd]: " + $cmd
          else
            "[User-cmd]: " + $cmd + " " + $args
          end
      else
        "[User]: " + .[0:500]
      end
    else
      map(select(.type=="text")) |
      map(
        if (.text | startswith("Base directory for this skill:")) then
          ((try (.text | capture("Base directory for this skill:\\s*[^\\n]*/(?<name>[^/\\n]+)")) catch {name:"unknown"}) | .name) as $name
          | ((try (.text | capture("ARGUMENTS:\\s*(?<args>[^\\n]*)")) catch {args:""}) | .args) as $args
          | "[SkillBody: " + $name + "]\n[User-args]: " + ($args[0:500])
        else
          "[User]: " + (.text[0:500])
        end
      ) |
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
