#!/usr/bin/env bash
# Test suite for git-rebase-gate.sh.
# Run: bash ~/.claude/hooks/git-rebase-gate.test.sh
#
# Uses a real local "remote" (a bare repo) so origin/main genuinely exists and
# can genuinely move ahead. The fetch inside the hook then succeeds against a
# file:// URL, exercising the fresh path rather than only the offline fallback.
set -uo pipefail
GATE="${GATE:-$HOME/.claude/hooks/git-rebase-gate.sh}"
pass=0
fail=0

TMP=$(mktemp -d)
REMOTE=$TMP/remote.git
REPO=$TMP/repo
git init -q --bare "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" remote add origin "$REMOTE"
echo base > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -qm "feat: base"
git -C "$REPO" push -q -u origin main
git -C "$REPO" remote set-head origin main > /dev/null 2>&1

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

verdict() {
  local out
  out=$(jq -n --arg c "$1" --arg d "$2" \
    '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | "$GATE")
  if [[ -z $out ]]; then echo allow; else echo deny; fi
}

expect() { # expect <allow|deny> <label> <command> [cwd]
  local want=$1 label=$2 cmd=$3 cwd=${4:-$REPO} got
  got=$(verdict "$cmd" "$cwd")
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL want=%-5s got=%-5s : %s\n' "$want" "$got" "$label"
  fi
}

echo "--- up to date with origin/main ---"
git -C "$REPO" checkout -q -b feat/x
echo work > "$REPO/g.txt"
git -C "$REPO" add g.txt
git -C "$REPO" commit -qm "feat: work"
expect allow "branch ahead of main, not behind" 'git push -u origin feat/x'
expect allow "pushing main itself" 'git push origin main'

echo "--- main moves ahead: branch is now stale ---"
# Advance origin/main behind the branch's back, via a second clone.
OTHER=$TMP/other
git clone -q "$REMOTE" "$OTHER"
git -C "$OTHER" config user.email t@t
git -C "$OTHER" config user.name t
echo more >> "$OTHER/f.txt"
git -C "$OTHER" add f.txt
git -C "$OTHER" commit -qm "feat: upstream move"
git -C "$OTHER" push -q origin main

expect deny "stale branch" 'git push -u origin feat/x'
expect deny "stale, with redirection" 'git push 2>&1 | tail'
expect deny "stale, cd form" "cd $REPO && git push" "$HOME"
expect deny "stale, git -C form" "git -C $REPO push" "$HOME"

echo "--- nothing lands: never gated even when stale ---"
expect allow "delete a branch" 'git push origin --delete old'
expect allow "tags only" 'git push --tags'
expect allow "dry run" 'git push --dry-run'

echo "--- unrelated commands ---"
expect allow "git status" 'git status'
expect allow "git fetch" 'git fetch origin'
expect allow "ls" 'ls -la'
expect allow "outside a repo" 'git push' /tmp

echo "--- after rebasing, allowed again ---"
git -C "$REPO" fetch -q origin
git -C "$REPO" rebase -q origin/main > /dev/null 2>&1
expect allow "rebased branch" 'git push --force-with-lease'

echo "--- per-repo opt-out ---"
git -C "$REPO" reset -q --hard "HEAD~1" > /dev/null 2>&1 || true
touch "$REPO/.git/git-rebase-gate-off"
expect allow "opted out" 'git push -u origin feat/x'
rm -f "$REPO/.git/git-rebase-gate-off"

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
