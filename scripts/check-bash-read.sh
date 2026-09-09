#!/bin/bash
# check-bash-read.sh — PreToolUse hook on Bash.
#
# Deterministic gate: catches Claude reading a large file via cat/head/tail/
# less/more instead of the Read tool, so files can't dodge check-file-size.sh
# just by going through Bash. Same threshold, same redirect.
#
# Piped commands (cat file | grep ...) always pass through — a pipe usually
# means the output is already being narrowed. head/tail with an explicit
# line count within the threshold also pass through, since that's already a
# targeted read regardless of how big the underlying file is.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
THRESHOLD="${HAIKU_SHUNT_MIN_LINES:-350}"

[[ -z "$COMMAND" ]] && exit 0
[[ "$COMMAND" == *"|"* ]] && exit 0

read -r -a WORDS <<< "$COMMAND"
TOOL="${WORDS[0]:-}"

case "$TOOL" in
  cat|less|more|head|tail) ;;
  *) exit 0 ;;
esac

WORD_COUNT="${#WORDS[@]}"
[[ "$WORD_COUNT" -lt 2 ]] && exit 0
FILE_PATH="${WORDS[$((WORD_COUNT - 1))]}"

[[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]] && exit 0

# head/tail: an explicit, in-budget line count is already a targeted read —
# let it through no matter how big the file is. No explicit count means the
# tool's own default (usually 10 lines), which is always targeted too.
if [[ "$TOOL" == "head" || "$TOOL" == "tail" ]]; then
  REQUESTED=""
  for ((i = 1; i < WORD_COUNT - 1; i++)); do
    w="${WORDS[$i]}"
    if [[ "$w" == "-n" && $((i + 1)) -lt $((WORD_COUNT - 1)) ]]; then
      REQUESTED="${WORDS[$((i + 1))]}"
    elif [[ "$w" =~ ^-([0-9]+)$ ]]; then
      REQUESTED="${BASH_REMATCH[1]}"
    elif [[ "$w" =~ ^--lines=([0-9]+)$ ]]; then
      REQUESTED="${BASH_REMATCH[1]}"
    fi
  done
  if [[ -z "$REQUESTED" || "$REQUESTED" -le "$THRESHOLD" ]]; then
    exit 0
  fi
fi

LINE_COUNT=$(wc -l < "$FILE_PATH" | tr -d ' ')

if [[ "$LINE_COUNT" -gt "$THRESHOLD" ]]; then
  cat <<EOF >&2
Blocked: '$COMMAND' dumps $FILE_PATH ($LINE_COUNT lines, threshold: $THRESHOLD).
Delegate this to the bulk-reader subagent instead:
  Use the Task tool with subagent_type "bulk-reader" and ask it your
  question about this file.
For a targeted look, use head/tail with an explicit line count at or under
the threshold, or pipe through grep/awk for a narrower slice.
EOF
  exit 2
fi

exit 0
