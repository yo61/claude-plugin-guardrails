#!/usr/bin/env bash
# shellcheck disable=SC2016  # Test cases are literal command strings fed to the
# guard on stdin. The ${...} inside them must reach the guard unexpanded.
#
# Test suite for bash-guard.sh. Run: bash ~/.claude/hooks/bash-guard.test.sh
#
# Every rule needs cases in BOTH directions. The allow-cases are the important
# half: a guard that cries wolf gets switched off, which is worse than no guard.
set -uo pipefail
GUARD="${GUARD:-$HOME/.claude/hooks/bash-guard.sh}"
# Resolve to an ABSOLUTE path up front. One case below runs the guard from a
# temp cwd, and the prek hook passes a relative path (`./scripts/bash-guard.sh`)
# while CI passes an absolute one -- so a relative GUARD broke the local hook
# while CI stayed green.
GUARD=$(cd "$(dirname "$GUARD")" && printf '%s/%s' "$PWD" "$(basename "$GUARD")")
pass=0
fail=0

# How many distinct pieces of guidance a command produces. Rules are evaluated
# per clause now, so one violation repeated across clauses would otherwise
# report itself once per clause -- the same paragraph twice is noise, and noise
# is what gets a guard switched off.
reasons() {
  local out
  out=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$GUARD")
  [[ -n $out ]] || {
    echo 0
    return
  }
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$out" | grep -c '^- '
}

verdict() {
  local out decision
  out=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$GUARD")
  if [[ -z $out ]]; then
    echo ALLOW
    return
  fi
  decision=$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$out")
  case $decision in
    deny) echo BLOCK ;;
    ask) echo ASK ;;
    *) echo "UNKNOWN:$decision" ;;
  esac
}

expect() { # expect <BLOCK|ASK|ALLOW> <command>
  local want=$1 cmd=$2 got
  got=$(verdict "$cmd")
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL want=%-5s got=%-5s : %s\n' "$want" "$got" "$cmd"
  fi
}

echo "--- recursive grep -> rg ---"
expect BLOCK 'grep -r "foo" .'
expect BLOCK 'grep -rn "foo" src/'
expect BLOCK 'grep -n -r "foo" src/'
expect BLOCK 'grep --recursive "foo" .'
expect BLOCK 'cd /tmp && grep -ril "foo" .'
expect ALLOW 'grep "foo" file.txt'
expect ALLOW 'ps aux | grep -i chrome'
expect ALLOW 'cat f | grep -n x | sort -r'
expect ALLOW 'git grep -rn "needle" master -- path/'
expect ALLOW 'pgrep -f something'
expect ALLOW 'echo "never use grep -r here"'

echo "--- rg -r is --replace, not --recursive ---"
expect BLOCK 'rg -rn "foo" src/'
expect BLOCK 'rg -ril "foo" .'
expect BLOCK 'rg -rn --no-heading "x" apps/'
expect ALLOW 'rg -n "pattern" src/'
expect ALLOW 'rg -n --no-ignore --hidden "pattern" dir/'
expect ALLOW 'rg --replace=NEW "old" file'
expect ALLOW "rg -o 'id=(\\d+)' -r '\$1' file"
expect ALLOW "rg -g '!node_modules' -n 'x'"
expect ALLOW 'rg -A 5 -B 3 -n "x" src/'
expect ALLOW 'rg -li "error" logs/'

echo "--- secret disclosure via \${VAR:-fallback} ---"
expect BLOCK 'echo "TOKEN: ${GITHUB_TOKEN:+set}${GITHUB_TOKEN:-UNSET}"'
expect BLOCK 'echo "${TF_HTTP_PASSWORD:-unset}"'
expect BLOCK 'echo "${STRIPE_SECRET_KEY:-none}"'
expect BLOCK 'echo "${MY_API_KEY:-missing}"'
expect ALLOW 'echo "TOKEN: $([ -n "$GITHUB_TOKEN" ] && echo SET || echo UNSET)"'
expect ALLOW 'echo "${GITHUB_TOKEN:+SET}"'
expect ALLOW 'echo "len=${#GITHUB_TOKEN}"'
expect ALLOW 'echo "${EDITOR:-vim}"'
expect ALLOW 'echo "${HOME:-/root}"'
expect ALLOW 'echo "${MONKEY_COUNT:-0}"'

echo "--- which -> command -v ---"
expect BLOCK 'which python3'
expect BLOCK 'ls && which fd'
expect ALLOW 'command -v python3'
expect ALLOW 'echo "which one did you mean"'

echo "--- rm -rf -> trash (disposable trees exempt) ---"
expect BLOCK 'rm -rf ~/important-project'
expect BLOCK 'rm -rf ./src/generated'
expect ALLOW 'rm -rf /tmp/scratch-thing'
expect ALLOW 'rm -rf node_modules && pnpm install'
expect ALLOW 'rm -rf .venv'
expect ALLOW 'rm -rf .lastlight/pr-review'
expect ALLOW 'rm -rf node_modules .venv'
# A disposable argument must not exempt the WHOLE command. This was a hole in
# the shipped v0.1.0: the exemption tested the command string, so one
# disposable path allowed `rm -rf` to delete a protected tree beside it.
expect BLOCK 'rm -rf .lastlight ~/important-project'
expect BLOCK 'rm -rf node_modules ~/important-project'
expect BLOCK 'rm -rf /tmp/scratch ~/important-project'
expect BLOCK 'rm -rf .venv ~/src/realwork'
# ...nor may a LATER disposable rm exempt an earlier protected one. The target
# extraction must see every invocation: a greedy match bound to the last `rm`
# only, so the first one's targets were never examined.
expect BLOCK 'rm -rf ~/important-project; rm -rf .venv'
expect BLOCK 'rm -rf ~/important-project && rm -rf node_modules'
expect BLOCK 'rm -rf ~/important-project | tee log; rm -rf /tmp/x'
expect BLOCK '(cd /tmp && rm -rf ~/important-project); rm -rf .venv'
expect ALLOW 'rm -rf node_modules; rm -rf .venv'
expect ALLOW 'rm -rf node_modules && rm -rf /tmp/scratch'
# Redirections are not paths. These were false-blocked, with the guard advising
# `trash /dev/null` -- and suppressing errors on an rm is a very common idiom.
expect ALLOW 'rm -rf .venv 2>/dev/null'
expect ALLOW 'rm -rf node_modules > /dev/null'
expect ALLOW 'rm -rf node_modules >> log 2>&1'
expect ALLOW 'rm -rf /tmp/scratch 2> err.log'
expect BLOCK 'rm -rf ~/important-project 2>/dev/null'
# A non-recursive rm must not poison the check for an rm -rf beside it. Each of
# these is allowed alone; the pair was denied because README.md was collected as
# a target of a command the rule does not even govern.
expect ALLOW 'rm -f README.md'
expect ALLOW 'rm -f README.md; rm -rf node_modules'
expect ALLOW 'rm file.txt && rm -rf .venv'
# ...but a recursive one still counts, wherever it sits in the chain.
expect BLOCK 'rm -f README.md; rm -rf ~/important-project'
expect BLOCK 'rm -rf ~/important-project; rm -f scratch.txt'
# `--` ends option parsing: a dash-prefixed token after it is a PATH, not a
# flag. Discarding it as a flag left an all-disposable target list and allowed a
# real deletion — the same bypass class, via argument syntax.
expect BLOCK 'rm -rf -- -importantfile node_modules'
expect BLOCK 'rm -rf -- -importantfile; rm -rf node_modules'
expect BLOCK 'rm -rf -- ~/important-project'
expect ALLOW 'rm -rf -- node_modules'
expect ALLOW 'rm -rf -- node_modules .venv'
# A traversing path escapes the disposable tree it appears to name, and cannot
# be judged by substring match at all. Not exempted, on principle.
expect BLOCK 'rm -rf .lastlight/../important-project'
expect BLOCK 'rm -rf node_modules/../../src'
expect BLOCK 'rm -rf /tmp/../Users/robin/code'
expect ALLOW 'rm -rf node_modules/.cache'
# Keywords must be WHOLE path segments. Unanchored, a real directory whose name
# merely contained one was exempted and silently deleted.
expect BLOCK 'rm -rf ~/node_modules-of-my-2019-hackathon'
expect BLOCK 'rm -rf ~/my-scratchpad-of-real-work'
expect BLOCK 'rm -rf project.venv-backup-DO-NOT-DELETE'
expect BLOCK 'rm -rf ~/builder'
expect BLOCK 'rm -rf ~/distribution'
# ...and the genuine ones, including multi-segment entries, still pass.
expect ALLOW 'rm -rf ./node_modules'
expect ALLOW 'rm -rf ~/proj/node_modules'
expect ALLOW 'rm -rf /private/tmp/x'
expect ALLOW 'rm -rf /tmp'
# OS scratch mounts are ABSOLUTE. A project's own tmp/ holds real work --
# uploads, sessions, work in progress -- and must not inherit the exemption
# meant for the machine's temp filesystem.
expect BLOCK 'rm -rf ~/myproject/tmp'
expect BLOCK 'rm -rf tmp'
expect BLOCK 'rm -rf ./tmp'
expect BLOCK 'rm -rf src/tmp/cache'
expect ALLOW 'rm -rf /var/folders/ab/cd'
expect ALLOW 'rm -rf target/debug'
expect ALLOW 'rm -rf target/release'
expect ALLOW 'rm -rf dist'
expect ALLOW 'rm -rf __pycache__'
# Quoting a disposable path must not turn a routine cleanup into a denial --
# the allow-side is what keeps the guard tolerable.
expect ALLOW 'rm -rf "node_modules"'
expect ALLOW "rm -rf 'node_modules'"
expect ALLOW 'rm -rf ".lastlight/pr-review"'
expect ALLOW 'rm -rf "/tmp/scratch"'
# ...and quoting must not become an escape in the other direction.
expect BLOCK 'rm -rf "~/important-project"'
expect BLOCK "rm -rf '~/important-project'"
expect BLOCK 'rm -rf "~/node_modules-of-my-2019-hackathon"'
# A quoted path CONTAINING A SPACE is one token, not several. Splitting it on
# whitespace before resolving quotes left fragments carrying stray quote
# characters, so a perfectly ordinary disposable tree under a directory with a
# space in its name was denied -- a false block on a real cleanup.
expect ALLOW 'rm -rf "/Users/robin/My Project/node_modules"'
expect ALLOW "rm -rf '/Users/robin/My Project/node_modules'"
expect ALLOW 'rm -rf /Users/robin/My\ Project/node_modules'
expect ALLOW 'rm -rf "My Project/node_modules" "/tmp/My Scratch"'
# ...and the same tokenising must not hand out an exemption it should not.
# These are the fragments the broken version produced, reunited: the protected
# path is now ONE token and stays protected.
expect BLOCK 'rm -rf "/Users/robin/My Project"'
expect BLOCK 'rm -rf .venv "/Users/robin/My Project"'
expect BLOCK "rm -rf .venv '/Users/robin/My Project'"
expect BLOCK 'rm -rf /Users/robin/My\ Project'
# No case here for an unterminated quote, deliberately. Swallowing one makes a
# token LONGER, and DISPOSABLE is segment-anchored, so a longer token can only
# match less often -- every plausible tokeniser blocks such a command. The
# assertion could not fail, and a test that cannot fail reports coverage that
# does not exist. The property is stated where it is relied on, in TOKENISE.
# Quoting decides classification. A quoted token is a literal PATH, so it must
# never be read as a redirection or a flag -- doing so dropped it from the
# target list entirely and let a real deletion through beside a disposable one.
expect BLOCK 'rm -rf .venv ">important-project"'
expect BLOCK 'rm -rf .venv "-importantfile"'
expect BLOCK 'rm -rf .venv ">" important-project'
expect BLOCK "rm -rf .venv '-importantfile'"
# A quoted token after a BARE redirect operator is that redirection's file, not
# a target. Handling quotes first both emitted it as a target and left the skip
# flag set, swallowing the next real target.
expect BLOCK 'rm -rf .venv > ".venv" ~/important-project'
expect ALLOW 'rm -rf node_modules > "log.txt"'
# BSD rm (macOS) stops option parsing at the first operand, so a later
# dash-prefixed argument is a literal PATH. Verified against the real rm:
# `rm -rf .venv -importantfile` deleted both.
expect BLOCK 'rm -rf .venv -importantfile'
expect BLOCK 'rm -rf node_modules -important-file'
# ...but dash-arguments BEFORE any operand are still options.
expect ALLOW 'rm -fr --verbose node_modules'
expect ALLOW 'rm -rf --one-file-system node_modules'
# A wildcard must be read as TEXT, never expanded against the guard's own cwd:
# the guard's process never follows a `cd` from the command it is judging.
expect BLOCK 'rm -rf ~/projects/*'

# The decisive glob case, and it needs its own cwd to mean anything.
#
# Running this from the repo root proves nothing: `*` would expand to
# README.md, scripts/ ... none disposable, so the command blocks whether or not
# the guard globs. Mutation-testing showed exactly that -- removing `set -f`
# left the suite green. Run it instead from a directory whose ONLY entry is
# `node_modules`: with globbing the target becomes a disposable path and the
# command is wrongly allowed; without it, `*` stays literal and is refused.
glob_cwd_case() {
  local dir out got
  dir=$(mktemp -d)
  mkdir -p "$dir/node_modules"
  out=$(cd "$dir" && jq -n '{tool_name:"Bash",tool_input:{command:"rm -rf *"}}' | "$GUARD")
  [[ -z $out ]] && got=ALLOW || got=BLOCK
  rm -rf "$dir"
  if [[ $got == BLOCK ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL want=BLOCK got=ALLOW : rm -rf * globbed against the guard cwd\n'
  fi
}
glob_cwd_case
expect ALLOW 'trash ~/important-project'
expect ALLOW 'rm -f single-file.txt'

echo "--- find -name -> fd ---"
expect BLOCK 'find . -name "*.py"'
expect BLOCK 'find src -name "*.ts" | head'
expect ALLOW 'fd -e py .'
expect ALLOW 'find . -name "*.tmp" -delete'
expect ALLOW 'find . -name "*.log" -exec gzip {} +'

echo "--- legacy toolchains ---"
expect BLOCK 'pip install requests'
expect BLOCK 'python3 -m pip install requests'
expect BLOCK 'black src/'
expect BLOCK 'flake8 src/'
expect BLOCK 'npx eslint .'
expect BLOCK 'prettier --write .'
expect BLOCK 'pre-commit run --all-files'
expect ALLOW 'uv pip install requests'
expect ALLOW 'ruff check src/'
expect ALLOW 'oxlint .'
expect ALLOW 'prek run --all-files'
expect ALLOW 'cat .prettierrc'

echo "--- zsh portability (Bash tool runs zsh 5.9) ---"
expect BLOCK 'mapfile -t arr < file'
expect BLOCK 'readarray -t arr < file'
expect BLOCK 'shopt -s nullglob'
expect BLOCK 'n=v; echo ${!n}'
expect BLOCK 'a=(x y); echo ${a[0]}'
expect BLOCK 'echo ${v,,}'
expect BLOCK 'echo ${v^^}'
expect BLOCK 'local -n ref=target'
expect BLOCK 'read -a parts <<< "a b"'
expect BLOCK '[[ $x =~ y ]] && echo ${BASH_REMATCH[1]}'
expect ALLOW 'a=(x y); echo ${a[1]}'
expect ALLOW 'a=(x y); echo "${a[@]}"'
expect ALLOW 'declare -A m; m[k]=v'
expect ALLOW 'echo -e "a\tb"'
expect ALLOW 'printf -v z "%s" hi'

echo "--- authoring/running real bash: bashisms are correct there ---"
expect ALLOW 'cat > s.sh <<EOF
#!/usr/bin/env bash
mapfile -t arr < file
find . -name "*.py"
EOF'
expect ALLOW "bash -c 'mapfile -t arr < file'"

echo "--- git push to main/master: prompt, never silent ---"
expect ASK 'git push origin main'
expect ASK 'git push -q -u origin main'
expect ASK 'git push origin master:master'
expect ASK 'git merge --ff-only upstream/main && git push origin main'
expect ALLOW 'git push -u origin feat/import-remaining-mu-plugins'
expect ALLOW 'git push origin main-is-not-the-target-here'

# A bash-only variable name is evidence the subject is bash source, so the
# zsh rules step aside. Without this the guard blocked its own author for
# writing ${BASH_SOURCE[0]} into a script, and advised an index that is equally
# empty in zsh -- the variable does not exist there at all.
expect ALLOW 'printf %s "${BASH_SOURCE[0]}"'
expect ALLOW 'cat >> f.sh <<EOF\nif [[ ${BASH_SOURCE[0]} == \$0 ]]; then main; fi\nEOF'
expect ALLOW 'grep -n BASH_SOURCE script.sh'
# BASH_REMATCH is NOT evidence of bash: zsh fills $match instead, so it stays a
# mistake here and keeps its own rule.
# ...but a real zsh zero-index mistake still blocks.
expect BLOCK 'echo "${arr[0]}"'
expect BLOCK 'printf %s "${parts[0]}"'

# A SEPARATOR INSIDE QUOTES is part of the filename, not a break between two
# commands. Splitting there tore the argument in two: the tail no longer looked
# like an `rm` invocation and was dropped unexamined, and the head tokenised to
# a bare disposable name, so the exemption allowed deleting a real path.
expect BLOCK 'rm -rf "node_modules;important-project"'
expect BLOCK 'rm -rf "node_modules|important-project"'
expect BLOCK 'rm -rf "node_modules&important-project"'
expect BLOCK "rm -rf '.venv;important-project'"
expect BLOCK 'rm -rf .venv "node_modules;important-project"'
# ...but a path genuinely under the machine's temp filesystem stays disposable
# however it is named -- the separator changes the filename, not the location.
expect ALLOW 'rm -rf "/tmp/scratch;important-project"'
expect BLOCK 'rm -rf node_modules\;important-project'
# ...while an UNQUOTED separator still ends the invocation, so each one is
# judged on its own targets.
expect ALLOW 'rm -rf node_modules; rm -rf .venv'
expect BLOCK 'rm -rf node_modules; rm -rf ~/important-project'

# A REDIRECT OPERATOR is not a command separator, however much `&` it contains.
# Splitting there severed the command and the protected target vanished with
# the fragment, instead of reaching the unknown-target fail-safe.
expect BLOCK 'rm -rf .venv 2>&1 ~/important-project'
expect BLOCK 'rm -rf .venv &>/dev/null ~/important-project'
expect BLOCK 'rm -rf .venv &>>log ~/important-project'
expect BLOCK 'rm -rf .venv <&3 ~/important-project'
expect BLOCK 'rm -rf .venv 1>&2 ~/important-project'
expect BLOCK 'rm -rf node_modules >|clobber ~/important-project'
# ...and those same operators must not be mistaken for paths, or an ordinary
# cleanup gets denied as a non-disposable target.
expect ALLOW 'rm -rf node_modules 2>&1'
expect ALLOW 'rm -rf node_modules &>/dev/null'
expect ALLOW 'rm -rf .venv 1>&2'
expect ALLOW 'rm -rf .venv >& log'
# A genuine `&&` still ends the invocation.
expect BLOCK 'rm -rf node_modules && rm -rf ~/important-project'
expect ALLOW 'rm -rf node_modules && rm -rf .venv'

# A BASH_ name is evidence of bash only as a VARIABLE REFERENCE. Matching the
# bare name anywhere let an incidental mention switch off every zsh rule for
# the rest of the command, so a real mistake beside it went unreported.
expect BLOCK 'grep -n BASH_SOURCE script.sh; echo "${arr[0]}"'
expect BLOCK 'echo BASH_VERSINFO && printf %s "${parts[0]}"'

# A COMMAND SPANNING LINES is still one command. awk splits its input on
# newlines by default, so a record ended before the quote tracking could see
# it: an ordinary wrapped `rm` lost its second line, which no longer began with
# `rm ` and was dropped unexamined. The exemption then saw only the disposable
# target and the protected one was deleted.
expect BLOCK $'rm -rf .venv \\\n  ~/important-project'
expect BLOCK $'rm -rf node_modules \\\n  \\\n  ~/important-project'
# A backslash-newline is a continuation and joins the lines, so this is ONE
# invocation with two disposable targets, not two invocations.
expect ALLOW $'rm -rf node_modules \\\n  .venv'
# A bare newline ends the invocation, exactly as a `;` would.
expect BLOCK $'rm -rf .venv\nrm -rf ~/important-project'
expect ALLOW $'rm -rf .venv\nrm -rf node_modules'
# A newline INSIDE quotes belongs to the filename. Splitting the record there
# left an unterminated quote whose fragment tokenised to a bare disposable
# name -- the same bypass as the quoted `;`.
expect BLOCK $'rm -rf ".venv\n~/important-project"'
expect BLOCK $'rm -rf \'.venv\n~/important-project\''

# One directory with a newline in its NAME is not two directories. Judging the
# name line by line let a single odd path be read as several disposable ones.
expect BLOCK $'rm -rf "node_modules\nnode_modules"'
expect BLOCK $'rm -rf ".venv\n.venv"'
expect BLOCK $'rm -rf "/tmp/a\n/tmp/b"'

# `>|` overrides noclobber and is a redirection in both its forms. Spelled
# after the plain `>` alternative it never matched whole, so the SPACED form
# fell through to the prefix test -- which continues WITHOUT consuming the
# operator's file, collecting it as a target and denying a clean cleanup.
expect ALLOW 'rm -rf node_modules >| log'
expect ALLOW 'rm -rf .venv >| /dev/null'
expect BLOCK 'rm -rf node_modules >| log ~/important-project'

# A SINGLE-QUOTED bash variable is a literal, not a reference: no shell expands
# it, so a command that merely searches for the spelling is not bash source and
# must not switch off the zsh rules for the mistake sitting beside it.
expect BLOCK "grep -n '\${BASH_SOURCE[0]}' script.sh; echo \"\${arr[0]}\""
expect BLOCK "printf %s '\${BASH_SOURCE[0]}'; echo \"\${parts[0]}\""
# ...while a double-quoted one DOES expand, so it remains evidence.
expect ALLOW 'printf %s "${BASH_SOURCE[0]}"'

# EVIDENCE IS SCOPED TO ITS CLAUSE. A genuine bash variable reference says that
# clause is bash source; it says nothing about the statement joined beside it.
# Applying it command-wide let one incidental reference switch off every rule
# for everything else on the line.
expect BLOCK "echo \"\${BASH_SOURCE[0]}\"; echo \"\${arr[0]}\""
expect BLOCK "echo \"\${BASH_SOURCE[0]}\"; pip install requests"
expect BLOCK "echo \"\${BASH_SOURCE[0]}\" && find . -name '*.py'"
expect BLOCK "echo \"\${BASH_SOURCE[0]}\"; pre-commit run --all-files"
# ...and the clause holding the reference is still exempt.
expect ALLOW "echo \"\${BASH_SOURCE[0]}\""
expect ALLOW "printf %s \"\${BASH_SOURCE[0]}\" > f.sh"
# A shebang or an explicit `bash -c` remains a statement about the WHOLE text:
# unmistakable, deliberate, and unlikely to appear beside an unrelated zsh
# statement -- unlike a bare variable reference.
expect ALLOW $'#!/usr/bin/env bash\nmapfile -t x < f'
expect ALLOW $'#!/usr/bin/env bash\nmapfile -t x < f; pip install requests'

echo "--- one violation, said once ---"
# Built from parts so this file does not itself trip the rule it is testing.
DUP=$(printf '%s install a; %s install b' pip pip)
ok_msg() {
  local what=$1 got=$2 want=$3
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$what" "$want" "$got"
  fi
}
ok_msg "the same violation in two clauses reports once" "$(reasons "$DUP")" "1"
ok_msg "two different violations both report" \
  "$(reasons "$(printf '%s install a; which foo' pip)")" "2"

# The name has to END where the list says. Without a trailing boundary any
# identifier merely STARTING with one of these counted -- an invented
# `${BASH_SOURCE_ROOT}` marked its clause as bash source and skipped every rule
# in it, including the zero-index bug sitting right beside it.
expect BLOCK "echo \"\${BASH_SOURCE_ROOT}\" \"\${arr[0]}\""
# Same clause as the violation, deliberately: with evidence scoped per
# clause, a violation in a NEIGHBOURING clause is caught either way and so
# proves nothing about the name boundary.
expect BLOCK "pip install \"\${BASH_LINENOX}\""
expect BLOCK "black \"\${BASH_ARGVV}\""
# ...while the real spellings still qualify, however they are written.
expect ALLOW "printf %s \"\${BASH_SOURCE[0]}\""
expect ALLOW 'printf %s "$BASH_SOURCE"'
expect ALLOW 'printf %s "${BASH_VERSINFO}"'

# An `rm` inside a command substitution is still an `rm`. The segmenter does
# not split on `$(`, so the segment did not begin with `rm `, no targets were
# collected, and the unjudgeable fail-safe denied a clean cleanup.
expect ALLOW 'x=$(rm -rf node_modules)'
expect ALLOW 'LOG=$(rm -rf node_modules 2>&1)'
expect ALLOW 'echo "$(rm -rf .venv)"'
expect BLOCK 'x=$(rm -rf ~/important-project)'
expect BLOCK 'LOG=$(rm -rf .venv ~/important-project)'

# A bash variable reference excuses the ZSH rules for its clause -- zsh array
# indexing does not apply to text meant for bash -- and nothing else. The
# tool-choice preferences are about the program being run, not about whether an
# argument mentions a bash variable.
expect BLOCK "pip install \"\${BASH_SOURCE[0]}\""
expect BLOCK "eslint \"\${BASH_SOURCE[0]}\""
expect BLOCK "black \"\${BASH_SOURCE[0]}\""
expect BLOCK "find \"\${BASH_SOURCE[0]}\" -name '*.py'"
expect BLOCK "pre-commit run --all-files \"\${BASH_SOURCE[0]}\""
# ...while the zsh rules stay excused in that same clause.
expect ALLOW "mapfile -t x < \"\${BASH_SOURCE[0]}\""
expect ALLOW "printf %s \"\${parts[0]}\" \"\${BASH_SOURCE[0]}\""

# EVERY command substitution, not just the outermost. Stripping only the first
# `$(` left a nested deletion invisible: the segment yielded no targets, so a
# disposable cleanup elsewhere in the command made every collected target
# disposable and suppressed the rule -- while the nested deletion still ran.
expect BLOCK 'echo "$(echo $(rm -rf ~/important-project))"'
expect BLOCK 'echo "$(echo $(rm -rf ~/important-project))"; rm -rf node_modules'
expect BLOCK 'x=$(echo "$(echo $(rm -rf ~/important-project))")'
expect BLOCK 'rm -rf node_modules; echo "$(echo $(rm -rf ~/important-project))"'
# ...and nesting a disposable one changes nothing.
expect ALLOW 'echo "$(echo $(rm -rf node_modules))"; rm -rf .venv'
expect ALLOW 'echo "$(echo $(rm -rf /tmp/scratch))"'

# PROCESS substitution runs its command as well, so an `rm` hidden in one is
# still an `rm`. Scanning only `$(` left it contributing no target at all, and
# any disposable cleanup elsewhere then made the whole command look disposable
# -- while the hidden deletion ran unrecoverably.
expect BLOCK 'diff <(rm -rf ~/important-project) /dev/null; rm -rf node_modules'
expect BLOCK 'tee >(rm -rf ~/important-project) < /dev/null; rm -rf .venv'
expect BLOCK 'diff <(rm -rf ~/important-project) /dev/null'
expect BLOCK 'diff <(echo $(rm -rf ~/important-project)) /dev/null; rm -rf node_modules'
# ...and a disposable target inside one is still disposable.
expect ALLOW 'diff <(rm -rf node_modules) /dev/null; rm -rf .venv'
expect ALLOW 'tee >(rm -rf /tmp/scratch) < /dev/null'

# A substitution body is a COMMAND LIST. Emitted whole, a body whose first word
# is not `rm` contributed no target at all -- and because the disposable check
# is scored across the whole command, one ordinary cleanup beside it supplied a
# passing target and the hidden deletion was never examined.
expect BLOCK 'rm -rf node_modules; echo "$(true; rm -rf ~/important-project)"'
expect BLOCK 'rm -rf node_modules; echo "$(cd /tmp && rm -rf ~/important-project)"'
expect BLOCK 'rm -rf .venv; echo "$(false || rm -rf ~/important-project)"'
expect BLOCK 'rm -rf node_modules; diff <(true; rm -rf ~/important-project) /dev/null'
expect BLOCK 'echo "$(true; rm -rf ~/important-project)"'
# ...and a compound body whose deletions are all disposable stays allowed.
expect ALLOW 'rm -rf node_modules; echo "$(true; rm -rf .venv)"'
expect ALLOW 'echo "$(cd /tmp && rm -rf /tmp/scratch)"'

# An ESCAPED dollar prints literally, even inside double quotes, so it names
# the spelling without referencing anything. Treating it as evidence excused
# every rule in the clause -- including the zero-index bug beside it.
expect BLOCK "echo \"\\\${BASH_SOURCE[0]}\" \"\${arr[0]}\""
expect BLOCK "printf %s \"\\\${BASH_LINENO[0]}\"; pip install requests"
# ...and escaped OUTSIDE quotes too, which is a separate branch of the scanner:
# mutating only the in-quotes one left this uncovered.
expect BLOCK "echo \\\$BASH_SOURCE \"\${arr[0]}\""
# ...while an unescaped one still is a reference.
expect ALLOW "printf %s \"\${BASH_SOURCE[0]}\""

# A substitution inside SINGLE quotes is text. Scanning the raw segment for an
# opener treated the literal as executable, so a string mentioning a protected
# deletion false-blocked the ordinary cleanup standing next to it.
expect ALLOW "echo '\$(rm -rf ~/important-project)'; rm -rf node_modules"
expect ALLOW "grep -F '\$(rm -rf ~/important-project)' file.txt"
# ...and inside DOUBLE quotes it really is a substitution.
expect BLOCK "echo \"\$(rm -rf ~/important-project)\"; rm -rf node_modules"
# An apostrophe inside double quotes is an apostrophe, not a quote opener --
# mistaking it swallows the rest of the command and hides what follows.
expect ALLOW "echo \"it's \$(rm -rf node_modules)\"; rm -rf .venv"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
