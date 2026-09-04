#!/usr/bin/env bash
# Refuse to push a branch that is not rebased onto the latest default branch.
#
# A branch based on a stale main produces a PR whose diff and CI results are
# against code nobody is merging into. Worse, it invites a merge commit or a
# late rebase, and a late rebase rewrites the SHA that CI and any review already
# ran against.
#
# Two conditions, both enforced:
#   1. The local view of the default branch is FRESH -- this fetches before
#      judging, so "rebased onto latest main" means latest on the remote, not
#      latest as of whenever you last pulled.
#   2. The branch is a DESCENDANT of that default branch.
#
# NOT gated (nothing to be stale against, or no new commit lands):
#   - pushing the default branch itself
#   - ref deletions, tag-only pushes, --dry-run
#   - repos with no matching remote default branch
#
# NETWORK POLICY: the fetch is best-effort with a short timeout. If it fails,
# the ancestry check still runs against the last-known remote ref and the
# message says freshness was unverified. Being offline degrades the guarantee
# from "latest" to "last known" rather than blocking work outright -- but a
# branch behind the ref we DO have is still refused, because that is knowable
# without the network.
#
# Opt out for a repo: touch "$(git rev-parse --git-dir)/git-rebase-gate-off"
set -euo pipefail

readonly FETCH_TIMEOUT=15

allow() { exit 0; }

deny() {
  jq -n --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# `sed -E`: BSD sed's BRE has no `\|` alternation, so an alternation written in
# BRE silently matches nothing on macOS.
resolve_target() {
  local cmd=$1 fallback=$2 p
  p=$(sed -E -n 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:];&|)]*).*/\1/p' <<< "$cmd" | head -1)
  if [[ -z $p ]]; then
    p=$(sed -E -n 's/.*(^|[^[:alnum:]_-])(cd|pushd)[[:space:]]+([^;&|)]*).*/\3/p' <<< "$cmd" | head -1 | sed 's/[[:space:]]*$//')
  fi
  p=${p%\"}
  p=${p#\"}
  p=${p%\'}
  p=${p#\'}
  p=${p/#\~/$HOME}
  if [[ -n $p && -d $p ]]; then printf '%s' "$p"; else printf '%s' "$fallback"; fi
}

# The remote's default branch, as `origin/main`. Prefers the recorded
# origin/HEAD; falls back to the conventional names.
default_ref() {
  local target=$1 ref
  ref=$(git -C "$target" symbolic-ref --quiet refs/remotes/origin/HEAD 2> /dev/null) || true
  if [[ -n $ref ]]; then
    printf '%s' "${ref#refs/remotes/}"
    return
  fi
  for c in origin/main origin/master; do
    if git -C "$target" rev-parse --verify --quiet "$c" > /dev/null 2>&1; then
      printf '%s' "$c"
      return
    fi
  done
}

main() {
  command -v jq > /dev/null 2>&1 || allow

  local payload cmd cwd
  payload=$(cat)
  cmd=$(jq -r '.tool_input.command // empty' <<< "$payload" 2> /dev/null) || allow
  cwd=$(jq -r '.cwd // empty' <<< "$payload" 2> /dev/null)
  [[ -n $cmd ]] || allow

  # FAST PATH: this runs on every Bash call, so git and the network sit behind it.
  grep -Eq '(^|[;|&(])[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$|\))' <<< "$cmd" || allow

  local args
  args=$(sed -E -n 's/.*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push[[:space:]]*([^;&|]*).*/\2/p' <<< "$cmd" | head -1)
  # Nothing new lands, so there is nothing to be stale.
  grep -Eq '(^|[[:space:]])(--delete|-d|--dry-run|--tags)([[:space:]]|$)' <<< "$args" && allow

  local target gitdir
  target=$(resolve_target "$cmd" "$cwd")
  [[ -n $target && -d $target ]] || allow
  gitdir=$(git -C "$target" rev-parse --git-dir 2> /dev/null) || allow
  [[ $gitdir = /* ]] || gitdir="$target/$gitdir"
  [[ -e "$gitdir/git-rebase-gate-off" ]] && allow

  local base branch
  base=$(default_ref "$target")
  [[ -n $base ]] || allow
  branch=$(git -C "$target" branch --show-current 2> /dev/null) || allow
  [[ -n $branch ]] || allow
  # Pushing the default branch itself has nothing to rebase onto.
  [[ "origin/$branch" == "$base" ]] && allow

  local fresh=1
  timeout "$FETCH_TIMEOUT" git -C "$target" fetch --quiet origin "${base#origin/}" > /dev/null 2>&1 || fresh=0

  if git -C "$target" merge-base --is-ancestor "$base" HEAD 2> /dev/null; then
    allow
  fi

  local behind
  behind=$(git -C "$target" rev-list --count "HEAD..$base" 2> /dev/null || echo "?")
  deny "$(
    cat << MSG
Blocked by git-rebase-gate.sh:

This branch is NOT rebased onto ${base} -- it is behind by ${behind} commit(s).

Pushing now produces a PR whose diff and CI run against code that is not what
will be merged, and forces a later rebase that rewrites the SHA any review and
any green check already ran against.

  git fetch origin
  git rebase ${base}
  # resolve any conflicts, re-run the checks, then push

If the branch is already pushed, the rebase needs a force-push:
  git push --force-with-lease
$([[ $fresh -eq 0 ]] && printf '\n%s\n' "NOTE: could not reach the remote, so ${base} may itself be stale. The check above ran against the last-known ref.")
Not gated: ref deletions, tag-only pushes, --dry-run, and pushing ${base#origin/} itself.

Opt out for this repo: touch "\$(git rev-parse --git-dir)/git-rebase-gate-off"
MSG
  )"
}

main "$@"
