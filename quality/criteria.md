# Quality criteria

Evaluate a change against these before calling it complete. **Blocking**
criteria must pass; **warning** criteria are flagged and judged in context.

Most entries came from something that actually went wrong here — the `Source`
line names the commit or file that records it. Items marked *(automated)* are
enforced by `prek` and listed only so the set is complete.

Update after each evaluation: date a criterion that caught something, promote
one triggered 3+ times to an automated check, and flag never-triggered
criteria for pruning after 10+ evaluations. Propose new criteria rather than
adding them silently.

---

## Category: Guard verdicts (`scripts/bash-guard.sh`, `scripts/git-rebase-gate.sh`)

## Criteria:

    - The verdict comes from parsed structure, not from matching the raw
      command text. A regex over the whole command cannot tell a governed
      invocation from a mention of one; ask the parsed invocations. Three
      separate fixes landed because a pattern stood in for a parse:
      `ask the parsed invocations whether an rm is governed, not a pattern`,
      `decide governance from resolved tokens, not raw text`,
      `scope bash evidence to its clause, not the whole command`.
    - Text is not syntax. Anything inside single quotes, a comment, a heredoc
      body, a `$'...'` escape, an escaped `$`, or an unterminated quote is
      DATA and must not be read as shell structure. This is the single largest
      source of false positives here — eight fixes, e.g.
      `single-quoted text is not syntax`,
      `read a heredoc body as prose, not as shell syntax`,
      `a single-quoted BASH_ name is a literal, not a reference`.
    - Every nesting layer is walked, not just the outermost. Command
      substitution `$(...)` and backticks, process substitution, brace groups,
      subshells and compound-command wrapping each hide a command position.
      A change that handles one layer must say why the others are covered.
      Ten fixes came from stopping too early, e.g.
      `scan every command substitution, not only the outermost`,
      `peel every group layer, not one`,
      `walk backtick substitution, the other POSIX form`.
    - A governed command is governed in every spelling. Flag order, combined
      vs separate short flags, long forms, and spaced operators are all the
      same command: `govern a recursive rm in every spelling, not just -rf`,
      "recognise `>|` as a redirection in its spaced form".
    - A new or widened rule ships with cases in BOTH directions — the thing it
      should catch, and the near-miss it must still allow. A guard that cries
      wolf gets disabled, which costs more than the rule gains.

## Severity: blocking

## Source: the `fix:` history since v0.1.0, which is almost entirely these four
shapes; `README.md` "Known false positive".

## Last triggered: never.

---

## Category: Guard test suite (`tests/*.sh`)

## Criteria:

    - A test case is TEXT and must stay inert. A case written in double quotes
      containing a backtick or `$(` is command substitution: the suite then
      RUNS the deletion it meant to describe. Three such cases were written by
      accident and were harmless only because the fixture path did not exist
      on that machine. *(automated: `inert-cases`)*
    - Neither linter covers the above, so neither may be treated as covering
      it. `shellcheck` reports a live backtick as SC2006 — a style note — and
      `shfmt` then rewrites it to `$(...)`, equally live and no longer
      flagged. Between them they can launder an executing case into a quietly
      executing one.
    - A check that reads the suite follows a case across every line it spans.
      Reading only the line that opens a case missed a live backtick on a
      continuation line.
    - The suite under test is the file being committed, not the installed
      copy. The harness defaults `GUARD`/`GATE` to the hook under
      `~/.claude/hooks`, so an invocation without an explicit `env GUARD=...`
      validates a different file: a broken script in the tree would pass, and
      a broken installed copy would fail a clean commit. CI and
      `.pre-commit-config.yaml` must both set it explicitly.
      *(automated: `guard-tests`, `rebase-gate-tests`)*
    - A documented case count in the README matches the suite.

## Severity: blocking

## Source: `tests/inert-cases.sh` header; the `env GUARD=` note in
`.pre-commit-config.yaml`; `docs: test the repo copy, and correct the case
count`.

## Last triggered: never.

---

## Category: Shell style

## Criteria:

    - `set -euo pipefail` at the top of every script.
    - `shfmt -i 2 -bn -ci -sr` — the four flags are the project standard and
      must be byte-identical in CI, `prek` and the editor. `-i2` is NOT valid:
      Go's flag parser reads it as a flag named `i2` and shfmt exits without
      formatting, silently, so files appear formatted on save while nothing
      ran. *(automated: `shfmt`)*
    - `shellcheck` clean; any `disable` carries a justification comment
      naming why. *(automated: `shellcheck`)*
    - `command -v`, never `which`.
    - Lines ≤ 100 characters, including config files.

## Severity: blocking

## Source: global `CLAUDE.md`; the `-i2` trap is recorded in
`.pre-commit-config.yaml`.

## Last triggered: 2026-09-11 — the 100-char criterion caught a `type-enum`
array written on one line (109 chars) in `commitlint.config.mjs` by an
automated repair commit. Restored to the multi-line house form in PR #7.

---

## Category: Dependency routing and releases

## Criteria:

    - Three files must agree, and nothing fails loudly when they don't:
      `.github/dependabot.yaml` decides which commit type is emitted,
      `commitlint.config.mjs` decides which types are legal, and
      `release-please-config.json` decides which types are visible and
      releasable. Changing one means checking the other two.
    - A visible `deps -> Dependencies` changelog section exists **iff** some
      ecosystem in this repo can emit `deps`. In release-please, listing and
      releasing are one switch: a non-hidden section is releasable and any
      releasable non-`feat` commit bumps the patch version.
    - An ecosystem whose updates cannot change what a user installs —
      pre-commit hooks, GitHub Actions, docs-site tooling, dev dependency
      groups — uses `chore(deps)`, which is hidden and does not release.
    - A CHANGELOG entry describes a change to the product, not the process
      that landed it. "make #N mergeable" is never a valid entry.
    - The published GitHub Release notes and the `CHANGELOG.md` section for a
      version say the same thing. Release notes are baked at merge time, so a
      correction after the release PR merges fixes only the file.

## Severity: blocking

## Source: `~/decisions/2026-09-11-ship-only-dependency-releases.md`, which
extends `yo61/jobhound decisions/2026-08-13-dependency-updates-and-releases.md`.

## Last triggered: 2026-09-11, three times in one day. The three-file criterion
caught the chain broken at both ends — Dependabot emitted `deps` while
`type-enum` rejected it (PR #5 red) and no changelog section existed for it.
The changelog-entry criterion caught v0.2.2 proposing two identical
`make #5 mergeable` entries. The release-notes criterion caught the fix landing
in the release PR description but not in `CHANGELOG.md`, repaired by PR #8.

---

## Category: Commits and PRs

## Criteria:

    - Conventional Commits, imperative mood, subject ≤ 72 chars, one logical
      change per commit. *(automated: `commitlint`)*
    - Bot commits are validated like any other. An exemption for
      Dependabot-signed commits hides the subject form release-please parses.
    - A PR body describes what the code does now — not discarded approaches,
      prior iterations, or alternatives.
    - A comment is true of the tree it lands in. Two commits in one PR left
      `commitlint.config.mjs` asserting that Dependabot emits `deps:` while
      its sibling set the prefix to `chore` — accurate when written, false on
      arrival.

## Severity: blocking

## Source: global `CLAUDE.md`;
`~/decisions/2026-08-11-commitlint-ci-version-skew.md` for the bot-validation
rule.

## Last triggered: 2026-09-11 — the comment-truth criterion caught the
contradictory pair described above; corrected in PR #7.
