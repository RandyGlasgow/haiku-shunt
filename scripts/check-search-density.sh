#!/bin/bash
# check-search-density.sh — PreToolUse hook on Grep and Bash.
#
# Opt-in feature flag. When on, blocks the token-fat shape of a search — one
# that returns every matching *line* across a whole tree — and names the
# token-dense alternatives this repo actually has.
#
#   HAIKU_SHUNT_DENSE_SEARCH=ast,rg,fzf
#
# The flag is a comma-separated list of dense-search capabilities, not a
# boolean. Unset or empty turns the hook off entirely; each token both turns
# it on and adds that tool to the redirect menu, so the suggestions are always
# things the repo is known to have. Nothing is ever probed for on the
# filesystem — a capability is present because the config says so, which keeps
# the hook's behavior a property of the repo rather than of whichever machine
# happens to be running it, and keeps the per-search cost at one string test
# when the flag is off.
#
# Known tokens (unknown ones are ignored, and named in the block message so a
# typo doesn't silently drop a suggestion):
#
#   ast | ast-grep      ast-grep -p '<pattern>'      structural
#   sg                  sg -p '<pattern>'            structural (ast-grep alias)
#   semgrep             semgrep -e '<pattern>'       structural
#   comby               comby '<match>' '' <path>    structural
#   ctags               ctags -x <path>              symbol index
#   tree-sitter | ts    tree-sitter query            structural
#   git | git-grep      git grep -l                  locate, index-aware
#   rg | ripgrep        rg -l / rg -c                locate
#   fzf                 fzf -f '<query>'             fuzzy path narrowing
#   all                 every token above
#
# Unlike the read hooks, this one can't measure what it's blocking — a search's
# cost isn't known until it runs. It gates on the *shape* of the query instead,
# so it's deliberately narrow: only searches that ask for content across a tree
# with no cap are blocked. Anything already narrowed passes through untouched.

set -euo pipefail

# ---- the flag gates everything below, including the capability parse ----
FLAG="${HAIKU_SHUNT_DENSE_SEARCH:-}"
[[ -z "$FLAG" || "$FLAG" == "false" || "$FLAG" == "off" ]] && exit 0

# A capped search is a targeted search. This is the cap that counts as one.
MAX_MATCHES="${HAIKU_SHUNT_SEARCH_MAX_MATCHES:-40}"

# Override the binary the `ast` token suggests, for a repo that wraps it.
AST_BIN="${HAIKU_SHUNT_AST_TOOL:-ast-grep}"

# ---- parse the capability list ----
HAS_STRUCTURAL=false
STRUCTURAL=()   # menu lines, structural queries first
LOCATE=()       # menu lines, paths/counts only
FUZZY=()        # menu lines, path narrowing
UNKNOWN=()

add_structural() { STRUCTURAL+=("$1"); HAS_STRUCTURAL=true; }

IFS=',' read -r -a TOKENS <<< "$(echo "$FLAG" | tr '[:upper:]' '[:lower:]')"
for raw in "${TOKENS[@]}"; do
  tok="${raw//[[:space:]]/}"
  [[ -z "$tok" ]] && continue
  case "$tok" in
    all|true)
      add_structural "$AST_BIN -p '<pattern>' <path>|structural — matches syntax, not text"
      add_structural "semgrep -e '<pattern>' <path>|structural, multi-language"
      add_structural "comby '<match>' '' <path>|structural rewrite/match"
      add_structural "tree-sitter query <query> <path>|structural, per-grammar"
      LOCATE+=("ctags -x <path>|symbol index — defs without bodies")
      LOCATE+=("git grep -l '<pattern>'|which files match, index-aware")
      LOCATE+=("rg -l '<pattern>' <path>|which files match")
      LOCATE+=("rg -c '<pattern>' <path>|how many, per file")
      FUZZY+=("fzf -f '<query>'|narrow a path list, non-interactive")
      ;;
    ast|ast-grep|astgrep)
      add_structural "$AST_BIN -p '<pattern>' <path>|structural — matches syntax, not text" ;;
    sg)
      add_structural "sg -p '<pattern>' <path>|structural (ast-grep)" ;;
    semgrep)
      add_structural "semgrep -e '<pattern>' <path>|structural, multi-language" ;;
    comby)
      add_structural "comby '<match>' '' <path>|structural rewrite/match" ;;
    tree-sitter|treesitter|ts)
      add_structural "tree-sitter query <query> <path>|structural, per-grammar" ;;
    ctags|universal-ctags)
      LOCATE+=("ctags -x <path>|symbol index — defs without bodies") ;;
    git|git-grep|gitgrep)
      LOCATE+=("git grep -l '<pattern>'|which files match, index-aware") ;;
    rg|ripgrep)
      LOCATE+=("rg -l '<pattern>' <path>|which files match")
      LOCATE+=("rg -c '<pattern>' <path>|how many, per file") ;;
    fzf)
      FUZZY+=("fzf -f '<query>'|narrow a path list, non-interactive") ;;
    *)
      UNKNOWN+=("$tok") ;;
  esac
done

# Every token was junk — the repo meant to configure something and didn't.
# Enforcing on a menu of nothing would just block searches with no way out.
if [[ "${#STRUCTURAL[@]}" -eq 0 && "${#LOCATE[@]}" -eq 0 && "${#FUZZY[@]}" -eq 0 ]]; then
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Print the enabled menu, densest answer first. Each group is guarded on its
# own length: bash 3.2 (still /bin/bash on macOS) treats expanding an empty
# array under `set -u` as an unbound variable.
dense_menu() {
  local entry
  for entry in "$@"; do
    printf '  %-36s %s\n' "${entry%%|*}" "${entry#*|}"
  done
}

# Collect the enabled menu, densest answer first. Each group is expanded under
# its own length guard: bash 3.2 (still /bin/bash on macOS) treats expanding an
# empty array under `set -u` as an unbound variable.
menu_entries() {
  [[ "${#STRUCTURAL[@]}" -gt 0 ]] && printf '%s\n' "${STRUCTURAL[@]}"
  [[ "${#LOCATE[@]}"     -gt 0 ]] && printf '%s\n' "${LOCATE[@]}"
  [[ "${#FUZZY[@]}"      -gt 0 ]] && printf '%s\n' "${FUZZY[@]}"
  return 0
}

menu_footer() {
  if [[ "$HAS_STRUCTURAL" == "false" ]]; then
    cat <<'EOF'

No structural search is enabled. If this repo has ast-grep, semgrep, comby or
tree-sitter, add it to HAIKU_SHUNT_DENSE_SEARCH — an AST query beats a text
one on both precision and tokens.
EOF
  fi
  if [[ "${#UNKNOWN[@]}" -gt 0 ]]; then
    echo
    echo "Ignored unknown HAIKU_SHUNT_DENSE_SEARCH token(s): ${UNKNOWN[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Grep tool: the fat shape is output_mode "content" with no head_limit. Every
# other mode already returns paths or counts, and is dense by construction.
# ---------------------------------------------------------------------------
if [[ "$TOOL_NAME" == "Grep" ]]; then
  OUTPUT_MODE=$(echo "$INPUT" | jq -r '.tool_input.output_mode // empty')
  HEAD_LIMIT=$(echo "$INPUT" | jq -r '.tool_input.head_limit // empty')
  SEARCH_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // empty')
  PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
  CONTEXT=$(echo "$INPUT" | jq -r '.tool_input["-C"] // .tool_input["-A"] // .tool_input["-B"] // empty')

  # Default mode is files_with_matches; only an explicit content ask is fat.
  [[ "$OUTPUT_MODE" == "content" ]] || exit 0

  # An explicit, in-budget cap is already a targeted read.
  if [[ -n "$HEAD_LIMIT" && "$HEAD_LIMIT" -le "$MAX_MATCHES" ]]; then
    exit 0
  fi

  # Searching inside one known file is targeted no matter the mode.
  [[ -n "$SEARCH_PATH" && -f "$SEARCH_PATH" ]] && exit 0

  TARGET="${SEARCH_PATH:-.}"
  {
    if [[ -n "$CONTEXT" ]]; then
      echo "Blocked: Grep for '$PATTERN' in $TARGET returns every matching line,"
      echo "with $CONTEXT lines of context around each, and no head_limit."
    else
      echo "Blocked: Grep for '$PATTERN' in $TARGET returns every matching line,"
      echo "with no head_limit."
    fi
    echo
    echo "Routing rule: locate first, read second. Get the shape of the answer"
    echo "in symbols, paths or counts, then read only the files that matter."
    echo
    echo "Dense alternatives enabled for this repo:"
    IFS=$'\n' read -r -d '' -a MENU < <(menu_entries; printf '\0')
    MENU+=("Grep output_mode \"files_with_matches\"|which files match")
    MENU+=("Grep output_mode \"count\"|how many, per file")
    dense_menu "${MENU[@]}"
    echo
    echo "Then Read the few files that came back, with offset/limit. If you"
    echo "genuinely need the lines themselves, retry with head_limit <= $MAX_MATCHES."
    menu_footer
  } >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Bash: same rule for shell searches, so a fat search can't dodge the Grep
# hook by going through the shell. Mirrors check-bash-read.sh's conventions —
# a pipe means the output is already being narrowed, so it passes through.
# ---------------------------------------------------------------------------
[[ "$TOOL_NAME" == "Bash" ]] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$COMMAND" ]] && exit 0
[[ "$COMMAND" == *"|"* ]] && exit 0

read -r -a WORDS <<< "$COMMAND"
TOOL="${WORDS[0]:-}"

case "$TOOL" in
  grep|egrep|fgrep|rg|ag|ack) ;;
  *) exit 0 ;;
esac

WORD_COUNT="${#WORDS[@]}"
[[ "$WORD_COUNT" -lt 2 ]] && exit 0

RECURSIVE=false
# rg/ag/ack walk a tree by default; grep only with -r/-R.
[[ "$TOOL" != "grep" && "$TOOL" != "egrep" && "$TOOL" != "fgrep" ]] && RECURSIVE=true

for ((i = 1; i < WORD_COUNT; i++)); do
  w="${WORDS[$i]}"

  case "$w" in
    # Long options that already make the output dense.
    --files-with-matches|--files-without-match|--count|--only-matching|--files)
      exit 0 ;;
    # Explicitly capped. An in-budget cap is a targeted search; a cap larger
    # than the budget is not, so it still gets redirected.
    --max-count=*)
      [[ "${w#--max-count=}" -le "$MAX_MATCHES" ]] && exit 0
      continue ;;
    --max-count)
      NEXT="${WORDS[$((i + 1))]:-}"
      [[ -n "$NEXT" && "$NEXT" -le "$MAX_MATCHES" ]] && exit 0
      continue ;;
    --recursive)
      RECURSIVE=true; continue ;;
    --*)
      continue ;;
    -*)
      # Short-option cluster: -rl, -nri, -m5 all have to be read per-character.
      CLUSTER="${w#-}"
      case "$CLUSTER" in
        m[0-9]*)
          [[ "${CLUSTER#m}" -le "$MAX_MATCHES" ]] && exit 0
          continue ;;
      esac
      if [[ "$CLUSTER" == *m ]]; then
        NEXT="${WORDS[$((i + 1))]:-}"
        [[ -n "$NEXT" && "$NEXT" -le "$MAX_MATCHES" ]] && exit 0
      fi
      [[ "$CLUSTER" == *[lLco]* ]] && exit 0
      [[ "$CLUSTER" == *[rR]* ]] && RECURSIVE=true
      continue ;;
  esac

  # A concrete file argument means this is a targeted search already.
  [[ -f "$w" ]] && exit 0
done

# A non-recursive grep reads what it was handed; nothing to narrow.
[[ "$RECURSIVE" == "true" ]] || exit 0

{
  echo "Blocked: '$COMMAND' prints every matching line across the tree."
  echo
  echo "Routing rule: locate first, read second. Get the shape of the answer"
  echo "in symbols, paths or counts, then read only the files that matter."
  echo
  echo "Dense alternatives enabled for this repo:"
  IFS=$'\n' read -r -d '' -a MENU < <(menu_entries; printf '\0')
  dense_menu "${MENU[@]}"
  echo
  echo "Then read the few files that came back with a targeted Read. If you"
  echo "need the lines themselves, cap it: -m $MAX_MATCHES, or pipe through"
  echo "head/awk for a narrower slice."
  menu_footer
} >&2
exit 2
