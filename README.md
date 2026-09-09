# haiku-shunt

A Claude Code plugin that deterministically routes bulk file reads and fresh
boilerplate writes to Haiku subagents, so large/mechanical I/O never eats
your main session's context or runs on your expensive model.

This is a Claude-only port of the pattern behind [Spotify's Shunt
plugin](https://engineering.atspotify.com/2026/9/portal-by-spotify-cut-my-claude-code-token-usage-by-90),
which routes the same kind of work to Gemini via their internal Portal
platform. This version drops that external dependency: everything here runs
on Claude Code's native `hooks` + `agents` primitives, with Haiku as the
worker model.

## How it works

**Layer 1 — Hooks (the enforcement).** Three `PreToolUse` hooks fire before
Read, Bash, and Write calls:

- `check-file-size.sh` — blocks a `Read` over `HAIKU_SHUNT_MIN_LINES` (350
  lines by default) unless it's already a targeted read (`offset`/`limit`
  set), and tells Claude to delegate to the `bulk-reader` subagent instead.
- `check-bash-read.sh` — same idea for `cat`/`head`/`tail`/`less`/`more`
  dumps of large files run through Bash, so files can't dodge the Read hook
  by going through the shell. Piped commands pass through untouched.
- `check-boilerplate-write.sh` — blocks a **fresh** `Write` to a file whose
  path looks like test/boilerplate scaffolding, and redirects to the
  `code-writer` subagent. This one's a filename-pattern heuristic rather
  than a hard measurement, so it's the one most worth tuning — see
  Configuration below.

All three exit `2` on a block, which sends the message on stderr back to
Claude as tool feedback. Claude sees the reason and (in practice) retries
through the suggested subagent instead.

**Layer 2 — Subagents (the workers).** Two custom subagents, both pinned to
`model: haiku` so the expensive model never touches this work:

- `bulk-reader` — read-only (`Read, Grep, Glob`), answers a question about
  one or more files in terse structured bullets. No prose, no line-number
  guessing.
- `code-writer` — `Read, Write`, generates code that matches a required
  reference file's conventions exactly. Refuses to guess at patterns if no
  reference file is given.

Because these are ordinary Claude Code subagents, they run in their own
context window — the caller only sees the final answer, not the intermediate
reads. That's the actual mechanism Spotify's version was reconstructing with
external scripts and a Portal CLI call.

## Install

Copy-paste one of these. They all work as-is — no placeholders to fill in.

**From GitHub (recommended).** This repo is its own marketplace:

```bash
claude plugin marketplace add RandyGlasgow/haiku-shunt
claude plugin install haiku-shunt@haiku-shunt
```

Restart Claude Code, then confirm it loaded:

```bash
claude plugin list
```

**From a local clone,** if you want to edit the hooks and thresholds:

```bash
git clone https://github.com/RandyGlasgow/haiku-shunt.git
claude plugin marketplace add ./haiku-shunt
claude plugin install haiku-shunt@haiku-shunt
```

**For hacking on it,** drop it in your skills directory instead — it
auto-loads on the next session as `haiku-shunt@skills-dir`, and your edits
take effect on restart with no reinstall step:

```bash
git clone https://github.com/RandyGlasgow/haiku-shunt.git ~/.claude/skills/haiku-shunt
```

### Update / uninstall

```bash
claude plugin update haiku-shunt@haiku-shunt        # pull the latest version
claude plugin uninstall haiku-shunt@haiku-shunt     # remove the plugin
claude plugin marketplace remove haiku-shunt        # and forget the marketplace
```

## Configuration

Set these in `.claude/settings.json` (project) or `~/.claude/settings.json`
(user), under `"env"`:

| Variable | Default | Purpose |
|---|---|---|
| `HAIKU_SHUNT_MIN_LINES` | `350` | Line threshold for both the Read and Bash-read hooks. |
| `HAIKU_SHUNT_BOILERPLATE_ENABLED` | `true` | Set to `false` to disable the boilerplate-write hook entirely. |
| `HAIKU_SHUNT_BOILERPLATE_PATTERN` | `(_test\.|_spec\.|\.test\.|\.spec\.|/tests?/|/__tests__/)` | Regex used to decide whether a new file looks like boilerplate. Tune to your repo's conventions. |

A complete `.claude/settings.json` you can paste and trim:

```json
{
  "env": {
    "HAIKU_SHUNT_MIN_LINES": "500",
    "HAIKU_SHUNT_BOILERPLATE_ENABLED": "true",
    "HAIKU_SHUNT_BOILERPLATE_PATTERN": "(_test\\.|_spec\\.|\\.test\\.|\\.spec\\.|/tests?/|/__tests__/)"
  }
}
```

## What this doesn't do

Same limits Spotify called out for the original, and for the same reasons:

- **No delegated edits.** The bulk-reader's summary doesn't guarantee exact
  line numbers, so Claude still reads a targeted section directly before
  editing. The hooks already allow `offset`/`limit` reads through for this.
- **No delegated reasoning.** Haiku is fine for "what does this do" and
  "generate this boilerplate." It's not a substitute for Claude on
  debugging, architectural decisions, or safety-critical code — don't route
  those here.
- **Some latency.** Every delegation is a real subagent spawn. Below the
  line threshold, that overhead costs more than it saves, which is why the
  threshold exists at all rather than delegating everything.
- **Still an Anthropic-hosted call.** Unlike Spotify's version, this doesn't
  externalize cost to a different provider — it just moves the work from
  your main model to a much cheaper one. Real savings, smaller ceiling than
  routing to a separate vendor.

## Repo layout

```
haiku-shunt/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json
├── agents/
│   ├── bulk-reader.md
│   └── code-writer.md
├── hooks/
│   └── hooks.json
├── scripts/
│   ├── check-file-size.sh
│   ├── check-bash-read.sh
│   └── check-boilerplate-write.sh
└── README.md
```
