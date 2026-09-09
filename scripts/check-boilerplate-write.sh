#!/bin/bash
# check-boilerplate-write.sh — PreToolUse hook on Write.
#
# Heuristic gate: blocks a *fresh* write to a file that looks like test or
# boilerplate scaffolding, and redirects to the code-writer subagent. This
# is the fuzziest of the three hooks — "boilerplate" is a filename pattern
# match, not a hard measurement like line count — so it's the one most
# worth tuning or disabling per-repo.
#
# Only gates new files: if the path already exists, this is more likely an
# edit to real logic than fresh scaffolding, so it passes through untouched.

set -euo pipefail

if [[ "${HAIKU_SHUNT_BOILERPLATE_ENABLED:-true}" == "false" ]]; then
  exit 0
fi

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

PATTERN="${HAIKU_SHUNT_BOILERPLATE_PATTERN:-(_test\\.|_spec\\.|\\.test\\.|\\.spec\\.|/tests?/|/__tests__/)}"

[[ -z "$FILE_PATH" ]] && exit 0
[[ -f "$FILE_PATH" ]] && exit 0

if [[ "$FILE_PATH" =~ $PATTERN ]]; then
  cat <<EOF >&2
Blocked: $FILE_PATH looks like new test/boilerplate scaffolding.
Delegate this to the code-writer subagent with a reference file instead:
  Use the Task tool with subagent_type "code-writer", passing a spec and a
  reference file whose pattern the new file should match.
If this file genuinely needs hand-written logic, set
HAIKU_SHUNT_BOILERPLATE_ENABLED=false in your settings env to disable this
hook, or narrow HAIKU_SHUNT_BOILERPLATE_PATTERN to your repo's conventions.
EOF
  exit 2
fi

exit 0
