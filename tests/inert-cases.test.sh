#!/usr/bin/env bash
# shellcheck disable=SC2016  # The cases below are DATA. Single quotes are what
# keeps them inert, which is the property under test: expanding one here would
# run the very thing this check exists to catch.
#
# Tests for inert-cases.sh, which is the only thing standing between a
# double-quoted test case and the shell executing it. It shipped blind to
# anything past the first line of a multi-line case and reported those files
# clean, so it is checked in both directions here: it must flag what the shell
# would run, and stay quiet on what it would not.
#
# Cases are written to a temp file rather than inlined, so nothing in THIS file
# is live either.

set -euo pipefail

CHECK="${CHECK:-tests/inert-cases.sh}"
CHECK=$(cd "$(dirname "$CHECK")" && printf '%s/%s' "$PWD" "$(basename "$CHECK")")

BT='`'
pass=0
fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# expect_flag <want: yes|no> <label> <case text>
expect_flag() {
  local want=$1 label=$2 body=$3 got=no file
  file="$tmp/case.sh"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$file"
  bash "$CHECK" "$file" > /dev/null 2>&1 || got=yes
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL want_flag=%s got=%s : %s\n' "$want" "$got" "$label"
  fi
}

echo "--- live syntax the shell would run ---"
expect_flag yes "backtick, first line" "expect BLOCK \"echo ${BT}echo x${BT}\""
expect_flag yes "substitution, first line" 'expect BLOCK "echo $(echo x)"'
expect_flag yes "backtick, second line" "expect BLOCK \"echo hi
${BT}echo x${BT}\""
expect_flag yes "substitution, second line" 'expect BLOCK "echo hi
$(echo x)"'
expect_flag yes "backtick, third line" "expect BLOCK \"a
b
${BT}echo x${BT}\""
expect_flag yes "unterminated case with a backtick" "expect BLOCK \"echo ${BT}echo x${BT}"

echo "--- data the shell would not run ---"
expect_flag no "escaped backtick" "expect BLOCK \"echo \\${BT}echo x\\${BT}\""
expect_flag no "escaped substitution" 'expect BLOCK "echo \$(echo x)"'
expect_flag no "single-quoted case" "expect BLOCK 'echo ${BT}echo x${BT}'"
expect_flag no "single-quoted, multi-line" "expect BLOCK 'echo hi
${BT}echo x${BT}'"
expect_flag no "escaped on a later line" "expect BLOCK \"echo hi
\\${BT}echo x\\${BT}\""
expect_flag no "backtick through a variable" 'expect BLOCK "echo ${BT}echo x${BT}"'
expect_flag no "inert multi-line, as the suite writes them" 'expect BLOCK "rm -rf node_modules # tidy
rm -rf ~/important-project"'
expect_flag no "not an expect line" "# echo ${BT}echo x${BT}"
expect_flag no "no cases at all" 'echo hello'

printf '\npassed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
