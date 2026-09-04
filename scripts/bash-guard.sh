#!/usr/bin/env bash
# shellcheck disable=SC2016  # Rule messages are literal documentation text: the
# backticks and ${...} inside them are prose ABOUT shell syntax, not code.
#
# Deterministic guardrails for the Claude Code Bash tool.
#
# Reads a PreToolUse hook payload on stdin. When the proposed command matches a
# known-wrong pattern, returns a permission decision that the model reads and
# retries against. Enforcement lives here rather than in CLAUDE.md because
# prose is advisory: it loses to reflex.
#
#   rule <regex> <message>  -> deny. The command is wrong; correct and retry.
#   ask  <regex> <message>  -> prompt Robin. Legitimate sometimes, never silent.
#
# Rules are tuned for PRECISION against ~250k historical commands. A guard that
# cries wolf gets switched off, so a rule that cannot cleanly separate the
# mistake from a legitimate idiom is narrowed until it can.
#
# To add a rule, append a call in check_command and a case to
# bash-guard.test.sh. State the correct form in the message -- that message is
# the entire feedback signal the model receives.
#
# See ~/decisions/2026-09-04-agent-guardrails-hooks-over-prose.md
set -euo pipefail

# Command position: start of string, or just after a separator that begins a new
# command. Deliberately NOT a plain word boundary -- anchoring here means a tool
# name merely *mentioned* inside a quoted string ("grep -r is banned") does not
# trip a rule, which is what makes it possible to write documentation about
# these patterns without fighting the guard. The cost is that `/bin/grep -r` and
# `if which foo` are missed; precision is worth more than that coverage.
readonly BOUNDARY='(^|[;|&(]|\$\()[[:space:]]*'
# Common runner prefixes, so `npx eslint` is caught as readily as bare `eslint`.
readonly RUNNER='((npx|uvx|pnpm|yarn|bunx)[[:space:]]+(exec[[:space:]]+)?|python3?[[:space:]]+-m[[:space:]]+)?'
# Zero or more whitespace-separated argument tokens belonging to ONE command.
# A token cannot contain a command separator, so a flag appearing after a `|`
# or `;` is never attributed to the earlier command.
readonly TOKENS='([[:space:]]+[^;|&[:space:]]+)*'

denials=()
prompts=()

matches() {
  grep -Eq "$1" <<< "$subject"
}

rule() {
  if matches "$1"; then
    denials+=("$2")
  fi
}

ask() {
  if matches "$1"; then
    prompts+=("$2")
  fi
}

# The command authors or invokes a real script for another interpreter or
# machine, so tool choices that are wrong *here* may be right *there*.
#
# A bash-only VARIABLE counts as that evidence too, and it had to: writing a
# script containing `${BASH_SOURCE[0]}` tripped the zero-index rule, which then
# advised `[1]` instead. That advice is wrong twice over -- the text is bash,
# where index 0 is correct, and in zsh `BASH_SOURCE` does not exist at ANY
# index, so there is nothing the rule could usefully say. None of these names
# exist in zsh, so their presence means the subject is bash source.
#
# BASH_REMATCH is deliberately NOT in that list. zsh fills `$match` instead,
# so using it here is a real mistake with a rule of its own, and treating it
# as evidence of bash would switch off the very rule that catches it.
#
# Found by the guard blocking its own author mid-edit, which is the only kind
# of false positive that reliably gets reported.
targets_real_bash() {
  matches '#!(/usr/bin/env[[:space:]]+bash|/bin/bash)' \
    || matches "${BOUNDARY}bash[[:space:]]+(-[cs]|<)" \
    || matches 'BASH_(SOURCE|VERSINFO|LINENO|ARGV|ARGC|SUBSHELL)'
}

# Scratch, temp and regenerable trees. `trash` is the wrong tool for these:
# slow on large trees, and it fills the Trash with rubbish.
# SEGMENT-ANCHORED, not substring. Bare keywords matched anywhere in the
# argument, so `~/node_modules-of-my-2019-hackathon`,
# `~/my-scratchpad-of-real-work` and `project.venv-backup-DO-NOT-DELETE` were
# all treated as disposable and silently deleted with no Trash recovery. Each
# name must now be a COMPLETE path segment: preceded by a `/` or the start of
# the argument, and followed by a `/` or the end.
# Entries may span several segments (`target/debug`); the anchors below still
# require whole-segment boundaries at each end.
readonly DISPOSABLE_NAMES='(scratchpad|node_modules|\.venv|\.pytest_cache|__pycache__|\.next|dist|build|target/debug|target/release|\.lastlight)'

# OS scratch mounts are ABSOLUTE, and must stay that way. `tmp` was originally
# reachable only through the slash-wrapped literals `/tmp/`, `/private/tmp/`
# and `/var/folders/` -- deliberately the machine's temp filesystems. Folding it
# into the segment-anchored bucket above silently widened it to ANY directory
# named `tmp` anywhere, so a project's own `tmp/` -- uploads, sessions, work in
# progress -- became exempt from the trash rule and could be deleted with no
# recovery. Anchored at the start of the path, these match only the real thing.
readonly DISPOSABLE_ABS='^(/private)?/tmp(/|$)|^/var/folders(/|$)'

readonly DISPOSABLE="(^|/)${DISPOSABLE_NAMES}(/|\$)|${DISPOSABLE_ABS}"

# Split a command into its separate invocations, one per line.
#
# `tr ';|&' '\n'` did this until a review showed it splitting INSIDE a quoted
# argument. `rm -rf "node_modules;important-project"` names one directory whose
# name contains a semicolon; torn in two, the tail fragment no longer starts
# with `rm ` and was dropped unexamined, while the head fragment tokenised to
# the bare word `node_modules` -- which IS disposable. The exemption then saw an
# all-disposable target list and allowed an unrecoverable deletion of a real
# path. The same bypass worked with `|` and `&`.
#
# So separators are recognised only OUTSIDE quotes. Quoting is preserved
# verbatim here rather than resolved: the tokeniser below still needs to see it
# to tell a redirection from a filename that merely starts with `>`. This is
# the same quote scan TOKENISE performs, kept separate because the two want
# opposite things from a quote -- one copies it through, the other strips it.
readonly SEGMENT='
BEGIN { SQ = sprintf("%c", 39); DQ = sprintf("%c", 34); BS = sprintf("%c", 92) }
{
  out = ""; n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (c == BS) {
      out = out c
      if (++i <= n) { out = out substr($0, i, 1) }
      continue
    }
    if (c == SQ) {
      out = out c
      while (++i <= n) { c = substr($0, i, 1); out = out c; if (c == SQ) break }
      continue
    }
    if (c == DQ) {
      out = out c
      while (++i <= n) {
        c = substr($0, i, 1)
        if (c == BS && i < n) { out = out c substr($0, ++i, 1); continue }
        out = out c
        if (c == DQ) break
      }
      continue
    }
    if (c == ";" || c == "|" || c == "&") { out = out "\n"; continue }
    out = out c
  }
  print out
}'

# A quote-aware tokeniser for ONE command segment, one token per output line.
#
# The first character of each line is the verdict on QUOTING -- `q` if any part
# of the token was quoted or backslash-escaped, `u` if it was a bare word --
# and the rest of the line is the token with its quoting resolved away.
#
# Both halves are needed, which is why neither `xargs` nor shell word-splitting
# can do this job. Word-splitting sees quotes far too late: it splits on spaces
# first, so `"/Users/me/My Project/node_modules"` arrived as two fragments and
# the exemption it should have granted failed. `xargs` splits correctly but is
# LOSSY -- it resolves quoting and then discards the fact that quoting happened,
# and that discarded bit is the entire difference between a redirection and a
# filename that merely starts with `>`. Dropping it deleted a real file named
# `>important-project`, because the guard skipped it as a redirect operand.
#
# Deliberately NOT `eval` or `set --`: the input is a command this hook is
# refusing to trust. Parsing it must never execute it.
#
# An unterminated quote emits what was accumulated instead of failing. The
# shell would reject such a command outright, and a mangled token is not
# disposable, so the caller blocks -- the safe direction.
readonly TOKENISE='
BEGIN { SQ = sprintf("%c", 39); DQ = sprintf("%c", 34); BS = sprintf("%c", 92) }
{
  tok = ""; started = 0; quoted = 0; n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (c == BS) {
      if (++i <= n) { tok = tok substr($0, i, 1); started = 1; quoted = 1 }
      continue
    }
    if (c == SQ) {
      started = 1; quoted = 1
      while (++i <= n) { c = substr($0, i, 1); if (c == SQ) break; tok = tok c }
      continue
    }
    if (c == DQ) {
      started = 1; quoted = 1
      while (++i <= n) {
        c = substr($0, i, 1)
        if (c == BS && i < n) { tok = tok substr($0, ++i, 1); continue }
        if (c == DQ) break
        tok = tok c
      }
      continue
    }
    if (c == " " || c == "\t") {
      if (started) { print (quoted ? "q" : "u") tok }
      tok = ""; started = 0; quoted = 0
      continue
    }
    tok = tok c; started = 1
  }
  if (started) { print (quoted ? "q" : "u") tok }
}'

# The paths EVERY `rm` in the command would delete, one per line, flags dropped.
#
# Every invocation, not one: the previous version used a single sed whose
# leading `.*` is greedy, so it bound to the LAST `rm` in a chained command.
# `rm -rf ~/important-project; rm -rf .venv` reported only `.venv`, the
# exemption saw an all-disposable target list, and the protected path was
# deleted with no Trash recovery -- the same hole this function exists to
# close, reached through a second invocation instead of a second argument.
#
# Splitting on separators first means each invocation is considered on its own
# -- and that split is quote-aware, because one that is not can be steered.
rm_targets() {
  local seg line tok quoted skip_next end_of_opts seen_operand
  # `set -f` for the whole scan: the word list below is deliberately unquoted so
  # the shell splits it, but without noglob it would also PATHNAME-EXPAND. A
  # target containing `*` would then be replaced by whatever happens to exist in
  # THIS process's cwd -- which never follows a `cd` earlier in the same command
  # -- so `cd /tmp && rm -rf *` was judged against the repo root. Text parsing
  # must not touch the filesystem.
  set -f
  while IFS= read -r seg; do
    seg=${seg#"${seg%%[![:space:]]*}"} # ltrim
    seg=${seg#(}                       # a leading `(` from a subshell
    seg=${seg#"${seg%%[![:space:]]*}"}
    [[ $seg == rm[[:space:]]* ]] || continue
    # Only invocations the RULE governs, i.e. recursive-force ones. Collecting
    # from every `rm` let a plain file removal poison the check for a legitimate
    # cleanup beside it: `rm -f README.md` and `rm -rf node_modules` are each
    # allowed alone, but together the non-disposable README.md made the pair
    # deny -- a false block built out of two permitted commands.
    [[ $seg =~ (^|[[:space:]])-[a-zA-Z]*(rf|fr|Rf|fR)[a-zA-Z]*([[:space:]]|$) ]] || continue
    skip_next=0
    end_of_opts=0
    seen_operand=0
    # Tokenise quote-aware (see TOKENISE): `q`/`u` prefix, then the token.
    while IFS= read -r line; do
      quoted=${line:0:1}
      tok=${line:1}

      # FIRST, unconditionally: consume the file belonging to a preceding bare
      # redirect operator. This must precede the quote branch -- `> "file"` is a
      # perfectly ordinary redirection, and handling quotes first both emitted
      # that filename as a target AND left skip_next set, so the NEXT real
      # target was swallowed instead.
      if [[ $skip_next -eq 1 ]]; then
        skip_next=0
        continue
      fi

      # `--` ends option parsing: everything after it is a PATH, however it is
      # spelled. Without this, a dash-prefixed target was discarded as a flag --
      # `rm -rf -- -importantfile node_modules` reported only `node_modules`,
      # the exemption saw an all-disposable list, and a real file was deleted
      # with no Trash recovery.
      if [[ $end_of_opts -eq 0 && $tok == -- ]]; then
        end_of_opts=1
        continue
      fi
      [[ $quoted == u ]] && tok=${tok%)} # a trailing `)` from a subshell

      # Redirections are not paths -- but ONLY when the shell would read them
      # as redirections, which is why every branch below is gated on the token
      # having been unquoted. `> log` redirects; `"> log"` is a file named
      # `> log`, and treating the two alike deleted the file. Without this, `rm -rf .venv 2>/dev/null`
      # yielded `/dev/null` as a target, no disposable match, and the guard told
      # the caller to `trash /dev/null` -- a false block on one of the commonest
      # idioms there is. A bare operator takes the NEXT token as its file; a
      # joined form (`2>/dev/null`, `>>log`) carries its own.
      if [[ $quoted == u && $tok =~ ^[0-9]*(\>\>|\>|\<)$ ]]; then
        skip_next=1
        continue
      fi
      [[ $quoted == u && $tok =~ ^[0-9]*(\>|\<) ]] && continue
      # A leading `-` is an OPTION only while rm is still scanning options.
      # BSD rm (macOS -- this hook's actual deployment target) does not permute:
      # once a filename has been seen, a later `-`-prefixed argument is a
      # literal path. Verified by creating a file named `-importantfile` and
      # running the real rm: `rm -rf .venv -importantfile` deleted BOTH. GNU rm
      # would reject it as an invalid option, so treating it as a target is the
      # safe reading on either platform -- a non-disposable target denies, and
      # an invalid option was never going to delete anything anyway.
      [[ $end_of_opts -eq 0 && $seen_operand -eq 0 && $tok == -* ]] && continue
      if [[ -n $tok ]]; then
        seen_operand=1
        printf '%s\n' "$tok"
      fi
    done < <(printf '%s\n' "${seg#rm }" | awk "$TOKENISE")
  done < <(printf '%s\n' "$cmd" | awk "$SEGMENT")
  set +f
}

# True only when EVERY target is disposable.
#
# The earlier version tested the whole COMMAND STRING for a disposable path,
# which meant one disposable argument exempted the entire command:
# `rm -rf .lastlight ~/important-project` was allowed, and permanently deleted
# the project the rule exists to protect. That applied to every entry in the
# list -- node_modules, /tmp, .venv -- so it was a hole in the shipped v0.1.0,
# not something the .lastlight entry introduced. Found by the independent
# review; the probe is in the test suite below.
#
# An `rm` with no parsable target is NOT exempt: unknown means protected.
all_rm_targets_disposable() {
  local target found=0
  while IFS= read -r target; do
    [[ -n $target ]] || continue
    found=1
    # A traversing path cannot be judged by substring match: DISPOSABLE matched
    # `.lastlight/../important-project`, which deletes the project NEXT TO the
    # scratch dir, not the scratch dir. Rather than normalise -- which would
    # mean resolving against a cwd this process does not share with the command
    # -- refuse to exempt anything containing `..`. Fail-safe: an unjudgeable
    # target is a protected one.
    [[ $target == *..* ]] && return 1
    grep -Eq "$DISPOSABLE" <<< "$target" || return 1
  done < <(rm_targets)
  [[ $found -eq 1 ]]
}

check_tool_choice() {
  subject=$cmd

  # `git grep` needs no special case: in `git grep`, the word `grep` sits after
  # a command name rather than at command position, so BOUNDARY skips it. That
  # is the correct outcome -- git grep searches the index or a revision, which
  # rg cannot do.
  rule "${BOUNDARY}(grep|egrep|fgrep)${TOKENS}[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive|--dereference-recursive)([[:space:]]|$)" \
    'Recursive grep is not used here. Use `rg`, which recurses by default: `rg -n "pattern" path/`. Add --no-ignore --hidden to include .gitignored and hidden files. (To search a git revision rather than the working tree, `git grep` is correct and is not blocked.)'

  # Only the CLUSTERED form is blocked. `-rn` parses as --replace=n; a bare
  # `-r <arg>` is a real idiom (`rg -o "id=(\d+)" -r '$1'` extracts a capture
  # group) that appears legitimately in this history, so it stays allowed.
  rule "${BOUNDARY}rg${TOKENS}[[:space:]]+-[a-zA-Z]*r[a-zA-Z]+([[:space:]]|$)" \
    'ripgrep `-r` is --replace (it consumes an argument), NOT --recursive. `rg -rn "x"` parses as --replace=n and silently rewrites every match to "n", producing output that looks like corrupted identifiers. rg recurses by default: drop the r (`rg -n "x"`). For real substitution use a separate argument: `rg -o "pat(...)" -r "$1"`.'

  # `${SECRET:-fallback}` expands to the SECRET ITSELF whenever it is set, so
  # the "is it set?" idiom `echo "${T:+SET}${T:-UNSET}"` prints the credential
  # on exactly the runs where there is one to print. It fails OPEN, in the
  # direction of disclosure. knowledge/shell-and-debugging rules.md R2 records
  # this costing a live Grafana token; it then leaked a GitHub PAT into a
  # transcript on 2026-09-04, which is why it is enforced here rather than
  # written down a second time.
  rule '\$\{[A-Za-z_]*(TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|APIKEY|PRIVATE_KEY|ACCESS_KEY|CREDENTIAL)[A-Za-z_]*:-' \
    'This prints the secret. `${VAR:-fallback}` expands to VAR whenever VAR is set, so an "is it set?" check written this way discloses the value on exactly the runs where there is one. Use a form that structurally cannot print it: `[ -n "$VAR" ] && echo "SET len=${#VAR}" || echo UNSET`. Report presence or length, never the value.'

  # A POSIX builtin, so this is right in scripts too -- no authoring exemption.
  rule "${BOUNDARY}which[[:space:]]+[a-zA-Z0-9_.-]+([[:space:]]|$)" \
    'Use `command -v <cmd>`, not `which`. `which` is an external binary with inconsistent behaviour across systems and a non-POSIX exit status; `command -v` is a POSIX shell builtin, so it is also the correct choice inside scripts and GitHub Actions `run:` blocks.'

  if ! all_rm_targets_disposable; then
    rule "${BOUNDARY}rm[[:space:]]+-[a-zA-Z]*(rf|fr|Rf|fR)[a-zA-Z]*([[:space:]]|$)" \
      'Use `trash <path>`, not `rm -rf` -- it moves to the macOS Trash and stays recoverable. (Scratch, temp and regenerable trees such as /tmp, node_modules and .venv are exempt and not blocked; `trash` is the wrong tool for those.)'
  fi

  if targets_real_bash; then
    return 0
  fi

  # -exec/-delete/-print0 are find idioms worth keeping; fd's -x/-X/-0 differ
  # enough that a blanket rewrite would be wrong.
  if ! matches '[[:space:]]-(exec|execdir|delete|print0|ok)([[:space:]]|$)'; then
    rule "${BOUNDARY}find${TOKENS}[[:space:]]+-name([[:space:]]|$)" \
      'Use `fd` instead of `find -name`: `fd "pattern" path/`. (find stays correct for -exec/-delete and for scripts that must run where fd is not installed -- neither is blocked.)'
  fi

  rule "${BOUNDARY}${RUNNER}(pip|pip3)[[:space:]]+install([[:space:]]|$)" \
    'Use `uv` rather than pip: `uv pip install ...` inside a `uv venv`, or `uv add` for project dependencies.'

  rule "${BOUNDARY}${RUNNER}(black|flake8|pylint)([[:space:]]|$)" \
    'Use `ruff` rather than black/flake8/pylint: `ruff format` and `ruff check`. Faster and stricter.'

  rule "${BOUNDARY}${RUNNER}(eslint|prettier)([[:space:]]|$)" \
    'Use `oxlint` and `oxfmt` rather than eslint/prettier. Faster and stricter.'

  rule "${BOUNDARY}pre-commit[[:space:]]+(run|install|autoupdate)([[:space:]]|$)" \
    'Use `prek` rather than `pre-commit` -- same hooks, Rust implementation, no Python dependency. `prek run`, `prek install`, `prek auto-update --cooldown-days 7`.'
}

check_zsh_portability() {
  subject=$cmd

  if targets_real_bash; then
    return 0
  fi

  rule "${BOUNDARY}(mapfile|readarray)([[:space:]]|$)" \
    'The Bash tool runs zsh, where `mapfile`/`readarray` do not exist (command not found). Use `while IFS= read -r line; do ... done < file`, or run the script under `bash -c`.'

  rule "${BOUNDARY}shopt([[:space:]]|$)" \
    'The Bash tool runs zsh, where `shopt` does not exist (command not found). Use `setopt`/`unsetopt`, or run the script under `bash -c`.'

  rule '\$\{![A-Za-z_]' \
    'The Bash tool runs zsh, where bash indirect expansion `${!var}` is a "bad substitution" error. zsh spells it `${(P)var}`.'

  rule '\$\{[A-Za-z_][A-Za-z0-9_]*\[0\]\}' \
    'The Bash tool runs zsh, where arrays are 1-INDEXED. `${arr[0]}` returns empty instead of the first element -- it fails SILENTLY with a wrong answer, not an error. Use `${arr[1]}`, or `${arr[@]:0:1}` to stay index-agnostic.'

  rule '\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)' \
    'The Bash tool runs zsh, where bash case conversion `${var,,}` / `${var^^}` is a "bad substitution" error. zsh spells it `${(L)var}` / `${(U)var}`.'

  rule "${BOUNDARY}(local|declare|typeset)[[:space:]]+-n[[:space:]]" \
    'The Bash tool runs zsh, which has no namerefs (`local -n`). Pass the value directly, or run the script under `bash -c`.'

  rule "${BOUNDARY}read[[:space:]]+-a[[:space:]]" \
    'The Bash tool runs zsh, where `read -a` differs from bash. zsh uses `read -A arr`.'

  rule 'BASH_REMATCH' \
    'The Bash tool runs zsh, which does not populate BASH_REMATCH. zsh puts regex captures in `$match`.'
}

check_git_safety() {
  subject=$cmd

  # Prompt rather than deny: pushing a fork's main after a --ff-only merge from
  # upstream is routine, and Robin has explicitly authorised such a push before
  # (2026-09-01). A hard block would fight his own overrides; this only ensures
  # it cannot happen without him seeing it.
  ask "${BOUNDARY}git[[:space:]]+push${TOKENS}[[:space:]]+(main|master|[^[:space:]]*:(main|master))([[:space:]]|$)" \
    'This pushes directly to main/master, which CLAUDE.md says to refuse in favour of a feature branch and a PR. Legitimate exceptions exist -- syncing a fork after a --ff-only merge from upstream. Approve only if this is one of them.'
}

check_command() {
  local subject
  check_tool_choice
  check_zsh_portability
  check_git_safety
}

emit() {
  local decision=$1 header=$2
  shift 2
  local reason="${header}"$'\n\n'
  reason+=$(printf -- '- %s\n' "$@")
  jq -n --arg d "$decision" --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
}

main() {
  command -v jq > /dev/null 2>&1 || exit 0

  local payload
  payload=$(cat)
  cmd=$(jq -r '.tool_input.command // empty' <<< "$payload" 2> /dev/null) || exit 0
  [[ -n $cmd ]] || exit 0

  check_command

  if [[ ${#denials[@]} -gt 0 ]]; then
    emit deny 'Blocked by ~/.claude/hooks/bash-guard.sh:' "${denials[@]}"
  elif [[ ${#prompts[@]} -gt 0 ]]; then
    emit ask 'Flagged by ~/.claude/hooks/bash-guard.sh:' "${prompts[@]}"
  fi
}

main "$@"
