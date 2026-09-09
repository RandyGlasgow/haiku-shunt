---
name: init
description: Manual setup check for haiku-shunt. Verifies jq is installed, scripts/*.sh are executable, and reports which HAIKU_SHUNT_* env vars are configured. Only run when the user explicitly invokes /haiku-shunt:init.
disable-model-invocation: true
allowed-tools:
  - Bash(command -v *)
  - Bash(chmod *)
  - Bash(ls *)
  - Bash(cat *)
  - Read
  - Edit
---

# /haiku-shunt:init

The hooks in `hooks/hooks.json` are wired automatically by the plugin system
on install — nothing to do there. What this checks is the two things that
break silently: a missing `jq` (every hook script pipes through it and fails
open/closed unpredictably without it), and lost executable bits (common on
zip downloads, not git clones).

Run these checks, in order, using `$CLAUDE_PLUGIN_ROOT` for the scripts path:

1. **`jq`** — `command -v jq`. If missing, stop and tell the user to install
   it (`brew install jq` / `apt install jq`) before anything else — all four
   hooks depend on it and fail without it.

2. **Executable bits** — `ls -l "$CLAUDE_PLUGIN_ROOT"/scripts/*.sh`. Any
   script missing `x` gets `chmod +x` applied directly, no need to ask.

3. **Config status** — read `.claude/settings.json` (project) and
   `~/.claude/settings.json` (user) if they exist, and report which
   `HAIKU_SHUNT_*` vars are set vs. defaulted. Only `HAIKU_SHUNT_DENSE_SEARCH`
   matters here — it's off by default and needs an explicit tool list to do
   anything. Do not write config unless the user asks; this step is a report.

Finish with a one-line status: ready, or what's still missing. Setting or
changing `HAIKU_SHUNT_DENSE_SEARCH` takes effect on the next hook call and
needs no restart; a session restart is only needed after installing/updating
the plugin itself.
