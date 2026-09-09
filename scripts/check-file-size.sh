#!/bin/bash
# check-file-size.sh — PreToolUse hook on Read.
#
# Deterministic gate: if the target file is over HAIKU_SHUNT_MIN_LINES
# (default 350) and this isn't already a targeted read (no offset/limit
# given), block it and tell Claude to delegate to the bulk-reader subagent
# instead of reading the whole file into the main session's context.

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // empty')
LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // empty')

THRESHOLD="${HAIKU_SHUNT_MIN_LINES:-350}"

# Targeted reads always pass through — Claude already knows which section
# it needs, so there's nothing to save by delegating.
if [[ -n "$OFFSET" || -n "$LIMIT" ]]; then
  exit 0
fi

if [[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]]; then
  exit 0
fi

LINE_COUNT=$(wc -l < "$FILE_PATH" | tr -d ' ')

if [[ "$LINE_COUNT" -gt "$THRESHOLD" ]]; then
  cat <<EOF >&2
Blocked: $FILE_PATH is $LINE_COUNT lines (threshold: $THRESHOLD).
Delegate this to the bulk-reader subagent instead of reading the whole file:
  Use the Task tool with subagent_type "bulk-reader" and ask it your
  question about this file.
If you only need a specific section, retry Read with an offset/limit instead.
EOF
  exit 2
fi

exit 0
