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
pass=0
fail=0

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

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
