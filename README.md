# guardrails

Refuses shell commands that are known-wrong here, and hands back the correct
form. A `PreToolUse` hook, so the harness enforces it — it does not depend on
the model reading, remembering or prioritising anything.

No project dependencies. Useful to anyone whose Bash tool runs zsh and who
prefers the modern CLI tools.

## Install

```bash
claude plugin install guardrails@yo61-skills
```

Plugin hooks load at **session start** — installing mid-session registers the
plugin but does not activate it.

To develop against a local checkout instead:

```bash
claude plugin marketplace add ~/code/github.com/yo61/claude-plugin-guardrails
```

## Why a hook and not CLAUDE.md

Measured across ~250k historical Bash commands, against rules that were
*already written down* in CLAUDE.md:

| Rule | Violations |
| --- | --- |
| use `rg`, not `grep -r` | 569 |
| `rg -r` is `--replace`, not `--recursive` | 74 |
| `which` → `command -v` | 182 |
| `find -name` → `fd` | 224 |
| `rm -rf` → `trash` | 680 |
| legacy toolchains | 111 |
| zsh-breaking bashisms | ~40 |

The `rg -r` trap had a full explanatory paragraph in CLAUDE.md and was violated
74 times anyway. Prose is advisory context competing for attention: it works for
judgement calls and loses to reflex. A hook runs outside the model.

## Rules

Tuned for **precision** against that same corpus — a guard that cries wolf gets
switched off. Measured fire rate: ~1%.

| Rule | Notes |
| --- | --- |
| `grep -r` → `rg` | rg recurses by default. `git grep` exempt — it searches a revision, which rg cannot. |
| clustered `rg -rn` | `-r` is `--replace`, so `-rn` parses as `--replace=n` and silently rewrites every match. Bare `-r <arg>` stays allowed: `rg -o 'id=(\d+)' -r '$1'` is a real idiom with 30 legitimate uses in the corpus. |
| `which` → `command -v` | External binary, non-POSIX exit status. No script exemption — `command -v` is POSIX, so it is right there too. |
| `rm -rf` → `trash` | Recoverable. Scratch/temp/regenerable trees exempt (`/tmp`, `node_modules`, `.venv`, `dist/`, …) — `trash` is the wrong tool for those. |
| `find -name` → `fd` | `-exec`/`-delete`/`-print0` and script authoring exempt. |
| pip → uv, black/flake8/pylint → ruff, eslint/prettier → oxlint/oxfmt, pre-commit → prek | Runner prefixes handled, so `npx eslint` is caught too. |
| zsh portability | Blocks `mapfile`, `shopt`, `${!v}`, `${arr[0]}`, `${v,,}`, `local -n`, `read -a`, `BASH_REMATCH`. |
| `git push` to main/master | **Asks**, does not deny — fork-syncs after a `--ff-only` merge are legitimate. |

`${arr[0]}` is the one worth internalising: **zsh arrays are 1-indexed**, so it
returns empty rather than erroring. It fails silently, with a wrong answer.
Verified in the real shell, alongside what does *not* need guarding —
`declare -A`, `echo -e`, `printf -v` and `${a[@]:0:1}` all work fine in zsh 5.9.

Commands that author or run real bash (`bash -c`, a heredoc with a bash shebang)
are exempt from the zsh rules: the syntax is correct there.

## Adding a rule

Append one `rule <regex> <message>` call in `check_command`, plus cases in
`tests/bash-guard.test.sh` in **both** directions. State the correct form in the
message — that message is the entire feedback signal the model receives.

Anchoring uses `BOUNDARY` (command position), not a word boundary, so a tool
named inside a quoted string (`echo "never use grep -r"`) does not trip a rule.

## Known false positive

Authoring bash *content* inline — e.g. writing `${BASH_SOURCE[0]}` through a
`perl -pi` one-liner — reads as zsh array indexing and is blocked. Use the Write
tool for that, which is the better route anyway.

## Tests

```bash
bash tests/bash-guard.test.sh    # 72 cases, both directions
```

Lint: `shellcheck scripts/*.sh` and `shfmt -i 2 -bn -ci -sr -d scripts/*.sh`.

## Marketplace entry

After the first tag, add to `yo61/claude-skills`
`.claude-plugin/marketplace.json`:

```json
{
  "name": "guardrails",
  "source": {
    "source": "url",
    "url": "https://github.com/yo61/claude-plugin-guardrails.git",
    "ref": "v0.1.0"
  }
}
```

## Two findings worth carrying elsewhere

Both came out of building this, and both generalise beyond it:

- **BSD sed has no `\|` alternation** (it is a GNU extension), so a
  `\(cd\|pushd\)` pattern silently matches *nothing* on macOS — no error, no
  exit-code change, just an empty capture. That made an earlier version of a
  sibling hook fall through to "allow": a control that looked installed and
  enforced nothing. Use `sed -E`.
- **`${SECRET:-fallback}` fails in the direction of disclosure.** It expands to
  the secret whenever the secret is set, so `echo "${T:+SET}${T:-UNSET}"` prints
  "UNSET" on every test you run without a credential loaded, and leaks on
  exactly the runs where there is something to leak. You cannot catch it by
  trying it. That is why it is a rule here rather than a note.
