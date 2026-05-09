#!/usr/bin/env bash
set -euo pipefail

PLUGIN_JSON=".claude-plugin/plugin.json"
MARKETPLACE_JSON=".claude-plugin/marketplace.json"

usage() {
  echo "Usage: $0 <major|minor|patch>"
  exit 1
}

[[ $# -ne 1 ]] && usage
BUMP_TYPE="$1"

current=$(jq -r '.version' "$PLUGIN_JSON")
IFS='.' read -r major minor patch <<< "$current"

case "$BUMP_TYPE" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) usage ;;
esac

next="${major}.${minor}.${patch}"

tmp=$(mktemp)

jq --arg v "$next" '.version = $v' "$PLUGIN_JSON" > "$tmp" && mv "$tmp" "$PLUGIN_JSON"
jq --arg v "$next" '.plugins[0].version = $v' "$MARKETPLACE_JSON" > "$tmp" && mv "$tmp" "$MARKETPLACE_JSON"

echo "$current → $next"
