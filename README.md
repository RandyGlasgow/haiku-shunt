# haiku-shunt

A Claude Code plugin that deterministically routes bulk file reads and fresh
file writes to cheaper subagents, so large/mechanical work never eats your
main session's context or runs on your expensive model. Reads go to Haiku;
writes are split between a Haiku worker and a Sonnet worker depending on
whether the file is templated or has to be derived from other code.

This is a Claude-only port of the pattern behind [Spotify's Shunt
plugin](https://engineering.atspotify.com/2026/9/portal-by-spotify-cut-my-claude-code-token-usage-by-90),
which routes the same kind of work to Gemini via their internal Portal
platform. This version drops that external dependency: everything here runs
on Claude Code's native `hooks` + `agents` primitives, with Haiku and Sonnet
as the worker models.

## How it works

**Layer 1 — Hooks (the enforcement).** Four `PreToolUse` hooks fire before
Read, Grep, Bash, and Write calls. Three are on by default; the search hook is
behind an opt-in flag.

- `check-file-size.sh` — blocks a `Read` over `HAIKU_SHUNT_MIN_LINES` (350
  lines by default) unless it's already a targeted read (`offset`/`limit`
  set), and tells Claude to delegate to the `bulk-reader` subagent instead.
- `check-bash-read.sh` — same idea for `cat`/`head`/`tail`/`less`/`more`
  dumps of large files run through Bash, so files can't dodge the Read hook
  by going through the shell. Piped commands pass through untouched.
- `check-write-tier.sh` — blocks a **fresh** `Write` and routes it to a
  worker by tier: templated scaffolding to `code-writer` (Haiku), derived
  content to `code-author` (Sonnet). Anything matching neither passes
  through. This one's a filename-pattern heuristic rather than a hard
  measurement, so it's the one most worth tuning — see Choosing a tier and
  Configuration below.
- `check-search-density.sh` — **off by default.** When
  `HAIKU_SHUNT_DENSE_SEARCH` names one or more dense-search capabilities, it
  blocks a search that would return every matching *line* across a tree and
  redirects to the dense alternatives that flag enabled. See Token-dense
  search below.

All four exit `2` on a block, which sends the message on stderr back to
Claude as tool feedback. Claude sees the reason and (in practice) retries the
way the message suggests — through a subagent for reads and writes, through a
denser query for searches.

**Layer 2 — Subagents (the workers).** Three custom subagents, each pinned
to the cheapest model that can actually do its job, so the expensive model
never touches this work:

- `bulk-reader` (`model: haiku`) — read-only (`Read, Grep, Glob`), answers a
  question about one or more files in terse structured bullets. No prose, no
  line-number guessing.
- `code-writer` (`model: haiku`) — `Read, Write`, generates templated
  scaffolding matching a required reference file's conventions exactly.
  Refuses to guess at patterns if no reference file is given, and bounces the
  task to `code-author` if writing it well would need real understanding.
- `code-author` (`model: sonnet`) — `Read, Write, Grep, Glob`, writes files
  whose content must be derived from other code. Reads the implementation
  before writing, makes bounded decisions itself, and escalates unbounded
  ones back to the caller instead of guessing.

Because these are ordinary Claude Code subagents, they run in their own
context window — the caller only sees the final answer, not the intermediate
reads. That's the actual mechanism Spotify's version was reconstructing with
external scripts and a Portal CLI call.

## Choosing a tier

The axis that decides which worker gets a job is **how much of the output is
determined by the input**:

| Tier | Output is… | Examples | Model |
|---|---|---|---|
| Templated | fully determined by a reference file — zero decisions | barrel/`index` files, `.d.ts` mirroring a schema, config stubs, fixtures, mocks | `code-writer` (Haiku 4.5) |
| Derived | bounded decisions, but only after reading the source | tests that cover real branches, docs written from code, a module against a fixed interface, a mechanical migration | `code-author` (Sonnet 5) |
| Neither | unbounded decisions, architectural seams, "is this a bug" | everything else | stays in your main session |

The earlier version of this plugin sent *all* test files to Haiku. That was
the wrong cut: a test that earns its keep requires reading the implementation
and deciding what to cover, which is derivation, not mimicry. Haiku only
genuinely wins where a template already determines the answer.

### Why this is where the money is

| | Context | Input $/MTok | Output $/MTok | Thinking control |
|---|---|---|---|---|
| Haiku 4.5 | 200K | $1 | $5 | `budget_tokens` only; no effort levels |
| Sonnet 5 | 1M | $2 | $10 | adaptive + `low`→`max` effort |
| Opus 5 | 1M | $5 | $25 | adaptive + effort |

Two consequences worth knowing:

- **Writing is output-token-heavy, and output is where the price spread is.**
  The read hooks save input tokens ($5 → $1), but their real value is context
  preservation. The write hook hits the $25/MTok side of the bill, so it's
  where the actual dollar savings live.
- **Sonnet 5 is only 2× Haiku's price for 5× the context**, plus adaptive
  thinking and effort control that Haiku 4.5 doesn't have at all. The gap
  between the two tiers is much smaller than the gap in what they can do, so
  reaching for Sonnet on derived content is cheap insurance against a
  confident, well-formatted test file that asserts nothing.

### Where the heuristic breaks

The hook only sees a file path and the content blob — it cannot actually tell
whether a write requires reading other code. Two things keep that honest:

- Content size is a second signal. A file matching the *template* pattern but
  longer than `HAIKU_SHUNT_TEMPLATE_MAX_LINES` is re-routed to Sonnet, on the
  theory that a 300-line "template" isn't one.
- The block message states the **routing rule**, not just an agent name, and
  names the other worker as an option. Claude picks the subagent on retry, so
  a path that lies about its contents can still be routed correctly.

## Token-dense search

A recursive `grep`/`rg` that prints matching lines is one of the fattest things
a session can do: the answer to "where is `handleAuth` defined" costs a few
hundred lines of surrounding code, most of which is comments, imports, and
call sites you didn't want. The dense version of the same question is two
steps — locate, then read — and the locate step returns paths or symbols
instead of text.

Set the flag to the tools your repo actually has:

```json
{ "env": { "HAIKU_SHUNT_DENSE_SEARCH": "ast,rg,fzf" } }
```

That turns the hook on *and* builds its redirect menu. A blocked search comes
back with only the alternatives you enabled, densest first:

```
Blocked: 'rg handleAuth src/' prints every matching line across the tree.

Routing rule: locate first, read second. Get the shape of the answer
in symbols, paths or counts, then read only the files that matter.

Dense alternatives enabled for this repo:
  ast-grep -p '<pattern>' <path>       structural — matches syntax, not text
  rg -l '<pattern>' <path>             which files match
  rg -c '<pattern>' <path>             how many, per file
  fzf -f '<query>'                     narrow a path list, non-interactive
```

### Tokens

| Token | Suggests | Kind |
|---|---|---|
| `ast`, `ast-grep` | `ast-grep -p '<pattern>'` | structural |
| `sg` | `sg -p '<pattern>'` | structural |
| `semgrep` | `semgrep -e '<pattern>'` | structural |
| `comby` | `comby '<match>' '' <path>` | structural |
| `tree-sitter`, `ts` | `tree-sitter query` | structural |
| `ctags` | `ctags -x <path>` | symbol index |
| `git`, `git-grep` | `git grep -l` | locate, index-aware |
| `rg`, `ripgrep` | `rg -l` / `rg -c` | locate |
| `fzf` | `fzf -f '<query>'` | fuzzy path narrowing |
| `all` | everything above | — |

Unknown tokens are ignored and named in the block message, so a typo can't
silently drop a suggestion. A flag made up *entirely* of unknown tokens
disables the hook rather than enforcing against an empty menu.

### Why a list and not a boolean

The hook never probes the filesystem for a binary. If `ast-grep` isn't in the
flag, the hook won't suggest it — even on a machine that has it installed.
That's deliberate: the same repo config then behaves identically on every
machine and in CI, and a suggestion is never made for a tool the session
would fail to run. It also keeps the off-path cost at a single string test,
before any JSON parsing.

### What it blocks

Only the uncapped, tree-wide, content-returning shape. Everything already
narrowed passes through:

| Passes through | Blocked |
|---|---|
| `Grep` with default or `files_with_matches`/`count` output mode | `Grep` with `output_mode: "content"` and no `head_limit` |
| `Grep` with `head_limit` ≤ `HAIKU_SHUNT_SEARCH_MAX_MATCHES` | …and `-A`/`-B`/`-C` context makes it worse, not better |
| `Grep` whose `path` is a single file | |
| `rg -l`, `rg -c`, `grep -rl`, `--files-with-matches`, `-o` | `rg <pattern> <dir>`, `grep -rn <pattern> <dir>` |
| `-m`/`--max-count` at or under the cap | `-m 9999` |
| anything with a pipe (`rg foo src/ \| head`) | |
| a non-recursive `grep` over a named file | |

The pipe and single-file carve-outs match `check-bash-read.sh` — a pipe means
the output is already being narrowed, and a named file means the search is
targeted.

### The honest limitation

The read hooks measure what they block: a file's line count is a fact known
before the read. This hook can't — a search's cost isn't knowable until it
runs, and a tree-wide `rg` that happens to return two lines is perfectly
cheap. So it gates on the *shape* of the query rather than its size, which
means it will sometimes block a search that would have been fine. The
carve-outs above are deliberately generous for that reason, and every block
message ends with the cap that makes the original query legal.

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

Then run `/haiku-shunt:init` once to check `jq` is installed and the hook
scripts are executable — both silently break the hooks if missing.

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
| `HAIKU_SHUNT_WRITE_ENABLED` | `true` | Set to `false` to disable the write-tier hook entirely. (`HAIKU_SHUNT_BOILERPLATE_ENABLED` is the pre-0.2 name and is still honored.) |
| `HAIKU_SHUNT_TEMPLATE_PATTERN` | see below | Paths matching this route to `code-writer` (Haiku). |
| `HAIKU_SHUNT_DERIVED_PATTERN` | see below | Paths matching this — and not the template pattern — route to `code-author` (Sonnet). |
| `HAIKU_SHUNT_TEMPLATE_MAX_LINES` | `120` | A template-pattern match with more content than this is re-routed to Sonnet instead. |
| `HAIKU_SHUNT_DENSE_SEARCH` | unset (off) | Comma-separated dense-search capabilities. Unset, empty, `false` or `off` disables the search hook entirely. See Token-dense search. |
| `HAIKU_SHUNT_SEARCH_MAX_MATCHES` | `40` | A search capped at or under this many matches counts as targeted and passes through. |
| `HAIKU_SHUNT_AST_TOOL` | `ast-grep` | Binary the `ast` token suggests, for a repo that wraps it. Does *not* enable the hook on its own. |

The template pattern is checked first, so a path matching both (e.g.
`tests/fixtures/users.json`) is treated as templated.

A complete `.claude/settings.json` you can paste and trim:

```json
{
  "env": {
    "HAIKU_SHUNT_MIN_LINES": "500",
    "HAIKU_SHUNT_WRITE_ENABLED": "true",
    "HAIKU_SHUNT_TEMPLATE_MAX_LINES": "120",
    "HAIKU_SHUNT_TEMPLATE_PATTERN": "((^|/)index\\.(ts|tsx|js|jsx|mjs|cjs)$|\\.d\\.ts$|(^|/)fixtures?/|(^|/)__fixtures__/|(^|/)__mocks__/|\\.(config|conf)\\.(ts|js|json|mjs|cjs|ya?ml)$)",
    "HAIKU_SHUNT_DERIVED_PATTERN": "(_test\\.|_spec\\.|\\.test\\.|\\.spec\\.|(^|/)tests?/|(^|/)__tests__/|\\.mdx?$|(^|/)docs?/|(^|/)(README|CHANGELOG|CONTRIBUTING))",
    "HAIKU_SHUNT_DENSE_SEARCH": "ast,rg,fzf",
    "HAIKU_SHUNT_SEARCH_MAX_MATCHES": "40"
  }
}
```

## What this doesn't do

Same limits Spotify called out for the original, and for the same reasons:

- **No delegated edits.** The bulk-reader's summary doesn't guarantee exact
  line numbers, so Claude still reads a targeted section directly before
  editing. The hooks already allow `offset`/`limit` reads through for this.
- **No delegated reasoning.** Haiku is fine for "what does this do" and
  "fill in this template." Sonnet extends that to work with bounded decisions
  and a cheap correctness check. Neither is a substitute for your main model
  on debugging, architectural decisions, or safety-critical code — don't route
  those here. `code-author` is instructed to escalate rather than guess when a
  task turns out to need one of them.
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
│   ├── code-writer.md
│   └── code-author.md
├── hooks/
│   └── hooks.json
├── skills/
│   └── init/
│       └── SKILL.md
├── scripts/
│   ├── check-file-size.sh
│   ├── check-bash-read.sh
│   ├── check-search-density.sh
│   └── check-write-tier.sh
└── README.md
```
