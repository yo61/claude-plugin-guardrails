#!/usr/bin/env bash
# shellcheck disable=SC2016  # The awk program below is literal source, not a
# shell expression: its $0 and $( are awk's and must not expand here.
#
# A test case is TEXT. This checks that the suite never lets one become syntax.
#
# The cases in bash-guard.test.sh are dangerous commands, handed to the guard as
# strings so it can judge them. Written inside DOUBLE quotes, a backtick or a
# `$(` in one is not data -- it is command substitution, and the suite runs the
# deletion it meant to describe. Three such cases were written by accident while
# adding backtick coverage; each was harmless only because the fixture path does
# not exist on the machine that ran it, which is not a property to rely on.
#
# The two linters do not cover this. shellcheck reports a live backtick as SC2006
# -- a STYLE note about legacy syntax -- and shfmt then rewrites it to `$(...)`,
# which is equally live and no longer flagged. Between them they can launder a
# case that executes into one that executes quietly.
#
# Single-quoted cases are inert and need nothing. A case that must contain single
# quotes spells the backtick through `$BT`, which expands after the shell has
# finished looking for commands to run.

set -euo pipefail

readonly SUITE="${1:-tests/bash-guard.test.sh}"

# Walk each double-quoted case body, honouring backslash escapes, and report a
# backtick or `$(` that the shell would act on. A `\$(` or a `\`` is data.
readonly SCAN='
BEGIN { BT = sprintf("%c", 96); DQ = sprintf("%c", 34); BS = sprintf("%c", 92) }
$0 ~ /^[[:space:]]*expect[[:space:]]+[A-Z]+[[:space:]]+/ {
  line = $0
  sub(/^[[:space:]]*expect[[:space:]]+[A-Z]+[[:space:]]+/, "", line)
  if (substr(line, 1, 1) != DQ) next
  n = length(line); found = ""
  for (i = 2; i <= n; i++) {
    c = substr(line, i, 1)
    if (c == BS) { i++; continue }
    if (c == DQ) break
    if (c == BT) found = found (found ? "," : "") "backtick"
    if (c == "$" && substr(line, i + 1, 1) == "(") found = found (found ? "," : "") "$("
  }
  if (found) printf "%s:%d: live %s in a double-quoted case: %s\n", FILENAME, FNR, found, $0
}'

main() {
  pre_flight_check

  local hits
  hits=$(awk "$SCAN" "$SUITE")

  if [[ -n $hits ]]; then
    echoerr "$hits"
    echoerr
    echoerr "A case must be text, not syntax. Use a single-quoted case, or spell"
    echoerr "a backtick as \${BT} and a substitution as \\\$( inside double quotes."
    return 1
  fi

  printf 'inert: every case in %s is passed as text\n' "$SUITE"
}

pre_flight_check() {
  command -v awk > /dev/null 2>&1 || {
    echoerr "awk not found"
    exit 1
  }
  [[ -r $SUITE ]] || {
    echoerr "cannot read $SUITE"
    exit 1
  }
}

echoerr() { printf '%s\n' "$@" >&2; }

main "$@"
