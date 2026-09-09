#!/bin/bash
# check-write-tier.sh — PreToolUse hook on Write.
#
# Routes a *fresh* Write to the cheapest worker that can actually do it well,
# by asking one question about the target: is its content determined by a
# template, or does it have to be derived from reading other code?
#
#   templated scaffolding  → code-writer (haiku)   — barrel/index files,
#                            .d.ts, config stubs, fixtures, mocks
#   derived content        → code-author (sonnet)  — tests, docs, anything
#                            whose content comes from reading the source
#   anything else          → passes through untouched
#
# Only gates new files: if the path already exists, this is more likely an
# edit to real logic than fresh scaffolding, so it passes through.
#
# This is the fuzziest hook in the plugin — the tier is a filename-pattern
# match plus a size check, not a hard measurement — so it's the one most
# worth tuning per-repo. Both patterns and the size threshold are env-tunable
# (see README), and the block message states the routing rule rather than
# dictating an agent, so Claude can override on retry when the path lies.

set -euo pipefail

# HAIKU_SHUNT_BOILERPLATE_ENABLED is the pre-0.2 name, still honored.
ENABLED="${HAIKU_SHUNT_WRITE_ENABLED:-${HAIKU_SHUNT_BOILERPLATE_ENABLED:-true}}"
[[ "$ENABLED" == "false" ]] && exit 0

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Templated scaffolding — fully determined by a reference file, no decisions.
TEMPLATE_PATTERN="${HAIKU_SHUNT_TEMPLATE_PATTERN:-((^|/)index\\.(ts|tsx|js|jsx|mjs|cjs)$|\\.d\\.ts$|(^|/)fixtures?/|(^|/)__fixtures__/|(^|/)__mocks__/|\\.(config|conf)\\.(ts|js|json|mjs|cjs|ya?ml)$)}"

# Derived content — has to be written by reading the code it describes/tests.
DERIVED_PATTERN="${HAIKU_SHUNT_DERIVED_PATTERN:-(_test\\.|_spec\\.|\\.test\\.|\\.spec\\.|(^|/)tests?/|(^|/)__tests__/|\\.mdx?$|(^|/)docs?/|(^|/)(README|CHANGELOG|CONTRIBUTING))}"

# A "template" this long isn't a template. Past this many lines of content,
# a template-pattern match is routed to the sonnet worker instead.
TEMPLATE_MAX_LINES="${HAIKU_SHUNT_TEMPLATE_MAX_LINES:-120}"

[[ -z "$FILE_PATH" ]] && exit 0
[[ -f "$FILE_PATH" ]] && exit 0

LINE_COUNT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' | wc -l | tr -d ' ')

TIER=""
if [[ "$FILE_PATH" =~ $TEMPLATE_PATTERN ]]; then
  if [[ "$LINE_COUNT" -gt "$TEMPLATE_MAX_LINES" ]]; then
    TIER="derived-by-size"
  else
    TIER="template"
  fi
elif [[ "$FILE_PATH" =~ $DERIVED_PATTERN ]]; then
  TIER="derived"
fi

[[ -z "$TIER" ]] && exit 0

case "$TIER" in
  template)
    cat <<EOF >&2
Blocked: $FILE_PATH ($LINE_COUNT lines) looks like templated scaffolding.
Routing rule: content fully determined by a reference file, no decisions
required → delegate to the code-writer subagent (haiku).
  Use the Task tool with subagent_type "code-writer", passing a spec and a
  reference file whose pattern the new file should match.
If writing this file actually requires reading and understanding other code
— which branches to cover, what a module does, logic against a spec — that
is code-author work (sonnet); use subagent_type "code-author" instead.
EOF
    ;;
  derived|derived-by-size)
    REASON="its content has to be derived from other code (tests, docs, a module against a spec)"
    [[ "$TIER" == "derived-by-size" ]] && REASON="it is $LINE_COUNT lines — past the $TEMPLATE_MAX_LINES-line template threshold, so it is not templated scaffolding"
    cat <<EOF >&2
Blocked: $FILE_PATH is a new file where $REASON.
Routing rule: bounded decisions that require reading the source first →
delegate to the code-author subagent (sonnet).
  Use the Task tool with subagent_type "code-author", telling it what to
  write and which file(s) to derive it from. It reads before it writes, so
  those reads stay out of this session's context.
If this file is pure boilerplate matching an existing reference file, use
subagent_type "code-writer" (haiku) instead — it's cheaper.
If it genuinely needs hand-written logic or an architectural decision, set
HAIKU_SHUNT_WRITE_ENABLED=false in your settings env to disable this hook,
or narrow HAIKU_SHUNT_DERIVED_PATTERN to your repo's conventions.
EOF
    ;;
esac

exit 2
