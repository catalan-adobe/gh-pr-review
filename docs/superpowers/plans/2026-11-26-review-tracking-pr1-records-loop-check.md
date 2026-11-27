# Review Tracking PR 1, Round Records and the Loop Check: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every posted review leaves a round record (a hidden marker on GitHub and `round.json` on disk).
`gh pr-review rounds <PR>` prints a PR's round history with a loop label per round. Before a round, the run checks
the loop: it stops a loop that does not converge (exit 3), refuses a round on an unchanged head (exit 5), and warns
on the posted review when a loop starts to go wrong. `--check` reports without running.

**Architecture:** The entry script stays Bash and gains a subcommand dispatch. New code lives in `lib/*.sh`
(functions only, no side effects when sourced), `lib/records.jq` and `lib/loop.jq`. The loop check runs before the
clone, on records read from the PR's reviews: markers when present, backfill otherwise.

**Tech Stack:** Bash (`set -euo pipefail`), `gh`, `git`, `jq`, `pi`. Lint: `shellcheck`, `shfmt`. Tests: plain Bash
scripts in `tests/`, with stubs for `gh`, `git` and `pi`.

**Spec:** `docs/superpowers/specs/2026-11-26-review-tracking-design.md`: phase 1, and "The loop check" from phase 3.
See "Order of work" there. PR 2 (incremental rounds) and PR 3 (local worktrees) have their own plans.

**Check** (every task ends with it):
`for t in tests/*.sh; do bash "$t" || exit 1; done && shellcheck gh-pr-review lib/*.sh tests/*.sh && shfmt -d gh-pr-review lib/*.sh tests/*.sh`.
Expected: all `ok`, no lint output.

## Global Constraints

- Every script starts with `set -euo pipefail`. `shellcheck` and `shfmt -d` are clean.
- `lib/*.sh` files only define functions and constants. Sourcing one runs nothing. Tests source them directly.
- Prompt text goes in quoted heredocs. Dynamic values go through `printf`, or unquoted heredocs with SHAs only.
- A records failure never blocks a post: a bad findings block falls back to parsing, and a parse failure leaves a
  record with `"source": "parsed"` and empty findings.
- The posted Markdown is today's Markdown, minus the findings block, plus one marker line, plus one loop line when
  the loop check warns. Nothing else changes.
- The loop check runs before the clone and before any pi call. `--check`, a stop and "no new commits" never clone.
- The loop thresholds are jq arguments with the spec's defaults (3 rounds, 0.7, 3 blocking, 800 lines, 25 files).
  The config file arrives in PR 3.
- Test fixtures are synthetic. This repo is public, and many real reviews come from internal repos. Fixtures copy
  the formats (bullets, numbered items, a Rethink-only review, a review from before the approach pass), never the
  text. Blocking counts per round are fine: the spec already lists them.
- Tests never use the network.

## Review Focus

- A finding title contains `--`, `-->` or `<!--` (real titles quote `--extend`). The marker must still be one valid
  HTML comment, and decode to the same title. Test in Task 2.
- The model writes the findings block in the middle of the reply, twice, or as plain ` ```json ` with no `findings`
  tag. The last ` ```json findings ` block wins. A plain `json` block is left in the body and the run falls back to
  parsing. Test in Task 2.
- A Rethink run has no code review. Its record has `"code_review": false`, empty findings, and null counts, never
  zeros. The loop rules skip it: it neither breaks nor extends a run of bad rounds (adobe/skills#813, round 13).
  Test in Tasks 2 and 3.
- Earlier rounds by another reviewer, and old reviews with the `generated` marker but no round marker, both count
  toward K. A `--no-post` run never does. Test in Tasks 4 and 6.
- The loop rules on the twelve calibration series give exactly the labels, warn rounds and stop rounds in the spec's
  table. Test in Task 3.
- A comment after the last round lifts a stop only when its author is a person other than the PR author. The PR
  author's replies, bots (`user.type == "Bot"`, which also covers apps without `[bot]` in the login), and
  gh-pr-review rounds do not. Test in Task 6.
- "No new commits": the PR's `headRefOid` equals the last round's head. It wins over a stop (exit 5, not 3). Test in
  Task 6.
- Without a terminal on stdin, a stop never waits for an answer: it exits 3, as with `-y`. Test in Task 6.
- The loop line in the posted body must not change what `last_verdict` reads for the approach or the "Ready to
  merge?" line. Test in Task 6.

---

### Task 1: `lib/` and subcommand dispatch

**Files:**
- Create: `lib/common.sh`, `lib/verdicts.sh`
- Modify: `gh-pr-review` (top: find `lib/`, source it, dispatch; move `last_verdict`, target parsing and the
  `--user` token export into `lib/`)
- Modify: `tests/verdict.sh`, `tests/post-decision.sh` (source `lib/verdicts.sh` instead of `sed`-cutting the block)
- Modify: `.github/workflows/ci.yml` (lint `lib/*.sh`)

**Interfaces:**
- Produces: `LIB_DIR`, found from `$0` through symlinks (`gh extension install .` makes a symlink), with a
  `readlink` loop rather than `readlink -f`.
- Produces: `last_verdict <label> <text>` in `lib/verdicts.sh`, unchanged.
- Produces: `resolve_target <URL | number>`, which sets `GH_HOST_NAME`, `OWNER`, `REPO`, `PR_NUM` or fails with
  today's messages. `use_gh_user <login>`, which exports `GH_TOKEN` and `GITHUB_TOKEN` as today. Both in
  `lib/common.sh`.
- Produces: dispatch. When the first argument is `rounds`, the script shifts it off, calls `cmd_rounds "$@"` and
  exits. `status`, `show`, `shepherd`, `dash` and `gc` are reserved: they print "not yet available" and exit 1.
  Anything else is a review, as today.

- [ ] **Step 1: Move code.** Move `last_verdict` to `lib/verdicts.sh`, and the target parsing and token export to
  `lib/common.sh`. Source `lib/*.sh` at the top of `gh-pr-review`.
- [ ] **Step 2: Tests.** `tests/verdict.sh` and `tests/post-decision.sh` source `lib/verdicts.sh`. The post block
  is still cut from `gh-pr-review` with `sed`.
- [ ] **Step 3: Dispatch.** Add it before argument parsing. Add the subcommands to `--help`.
- [ ] **Step 4: Check.** Then `gh pr-review status` prints "not yet available".
- [ ] **Step 5: CI.** Add `lib/*.sh` to the shellcheck and shfmt steps.
- [ ] **Step 6: Commit.** `git commit -m "Move shared helpers to lib/ and dispatch subcommands"`

### Task 2: The records library

**Files:**
- Create: `lib/records.sh`, `lib/records.jq`
- Create: `tests/records.sh`, `tests/fixtures/reviews/{bullets,numbered,rethink-only,pre-approach,dashes}.md`

**Interfaces:**
- Produces: `cut_findings_block <review-file> <body-out> <findings-out>`. It copies the review to `<body-out>`
  without the last ` ```json findings ` block, and writes that block's content to `<findings-out>`. With no such
  block: `<body-out>` is the whole review and `<findings-out>` is empty.
- Produces: `parse_findings <markdown-file>`, which prints a JSON array. Findings are the items under each heading
  that contains Critical, Important or Minor, up to the next heading. An item is a line that starts with `- **` or
  `<n>. **`. `file` and `line` come from the first `path:line` in the item's first line (in backticks or `[...]`).
  `line` is the first number of a range such as `106–111`. `title` is the text after ` — `, without the closing
  `**`, cut to 100 characters. When there is no ` — `, it is the first 100 characters without Markdown.
- Produces: `build_record`, which reads named jq arguments (PR, round, mode, reviewer, model, SHAs, approach,
  ready, decision, posted time, `code_review`), the findings JSON (from the block or from `parse_findings`), and the
  previous record (or `null`). It prints `round.json` in the spec's schema. It numbers findings `F<n>`, continuing
  after the highest number in the previous record. PR 1 sets every status to `new` and leaves `later` empty.
  `counts.open_blocking` is the number of critical and important findings. With `code_review: false`, findings are
  empty and every count is null.
- Produces: `normalize_ready <text>`: `yes`, `yes-with-fixes` (any qualified yes), `no`, or `unknown`.
- Produces: `marker_line <record-file> <body-length>`, which prints
  `<!-- gh-pr-review:round <json> -->`. The JSON is the compact record with titles cut to 100 characters, and every
  `--` written as `-\u002d`. If the body length plus the marker would pass 60,000 characters, it drops titles, then
  `later`, then `findings` (counts stay).
- Produces: `marker_record <body>`, which prints the record JSON from the last marker line, or nothing.
- Produces: `backfill_record <review-json> <previous-record-or-null>`, which builds a record from an old review's
  body with `"source": "backfill"`: `last_verdict` for the approach and "Ready to merge?" lines, and
  `parse_findings`. A body with an Approach section and no `Ready to merge?` line is a Rethink: `code_review: false`.

- [ ] **Step 1: Write fixtures.** Five synthetic reviews: `- **` bullets with `file:106–111` ranges; numbered items
  (`1. **`); a Rethink-only review (an Approach section and nothing else); a review from before the approach pass
  (no Approach section); and a review whose titles contain `--extend`, `-->` and `<!--`.
- [ ] **Step 2: Write `tests/records.sh`.** It sources `lib/verdicts.sh` and `lib/records.sh`, and checks:
  - `parse_findings` on each fixture: the count per severity, the `file`, `line` and `title` of one item.
  - `cut_findings_block`: no block, one block at the end, a block in the middle, two blocks (the last wins), and a
    plain ` ```json ` block (left in the body).
  - `build_record`: IDs continue from a previous record that has F1 to F7; `open_blocking`; a Rethink gives null
    counts.
  - `normalize_ready` on `Yes`, `Yes with fixes`, `Yes, with fixes`, `Yes (with fixes)`, `No — see Critical`, and an
    empty string.
  - `marker_line` and `marker_record`: a round trip on the dashes fixture gives the same titles. The line holds
    exactly one `<!--` and one `-->`. A 59,000-character body makes the marker drop titles.
  - `backfill_record` on the Rethink-only and pre-approach fixtures.
- [ ] **Step 3: Run it.** `bash tests/records.sh`. Expected: everything fails (no library yet).
- [ ] **Step 4: Implement** `lib/records.sh` and `lib/records.jq`. Keep the jq in the `.jq` file, loaded with
  `jq -L "$LIB_DIR" 'include "records"; …'`, so later PRs reuse it.
- [ ] **Step 5: Check.**
- [ ] **Step 6: Commit.** `git commit -m "Add round records: findings parser, record builder and marker"`

### Task 3: The loop rules

**Files:**
- Create: `lib/loop.jq`, `lib/loop.sh`, `tests/loop.sh`

**Interfaces:**
- Produces, in `lib/loop.jq` (input: the array of records, oldest first; `$p`: the parameters, merged over the
  defaults `{min_rounds: 3, converge_ratio: 0.7, nit_max_blocking: 3, too_big_lines: 800, too_big_files: 25,
  stuck_rounds: 3}`):
  - `loop_labels($p)`: one label per record: `rethink` for a record without a code review, else `ready`, `early`,
    `converging`, `nit-loop` or `churning`, by the spec's rules, in the spec's order. B(K−2) counts code-review
    rounds only.
  - `loop_flags($p; $size)`: `approach-stuck` when the approach was questionable or rethink in each of the last
    `stuck_rounds` records; `too-big` when `$size.lines > too_big_lines` or `$size.files > too_big_files`.
  - `loop_decide($p; $size; $head; $lifted)`: `{next_round, labels, label, flags, series, decision, reason,
    suggestion}`. `series` is the blocking count per record, `null` for Rethink. `decision`, in this order:
    `nothing-new` when `$head` equals the last record's head; `stop` when the last two code-review labels are both
    `nit-loop` or `churning` and `$lifted` is false; `warn` when the last code-review label is one of them;
    otherwise `run`. `suggestion` comes from the spec's table (approach-stuck, then too-big, then the label).
- Produces, in `lib/loop.sh`: `loop_decide_json <records-json> <size-json> <head> <lifted>`, which calls jq with
  `-L "$LIB_DIR"`. `loop_text <decision-json>`, which prints the diagnosis for a person:

```
Loop check for round 5: stop
  label     churning (rounds 3 and 4)
  blocking  9 12 8 10
  flags     approach-stuck too-big
  suggested Settle the approach before the next round: answer the approach questions, or rethink
  override  --force-round
```

- Produces: `loop_line <decision-json>`, the one line for the posted body:
  `**Loop:** Churning · blocking 9, 12, 8 · <suggestion>`.

- [ ] **Step 1: Write `tests/loop.sh`.** Build synthetic records (counts and approach only) for the twelve series
  in the spec's calibration table, with a Rethink record where the table has `-`. For each, check the labels by
  round, the first warn round and the stop round against the table. Also check: the flags, `nothing-new` winning
  over `stop`, `$lifted` turning a stop into a warn, an empty history (`run`, next round 1), and the suggestion for
  each row of the spec's table.
- [ ] **Step 2: Run it.** Expected: it fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Check.**
- [ ] **Step 5: Commit.** `git commit -m "Add the loop rules: labels, flags and the next-round decision"`

### Task 4: Records in the review run

**Files:**
- Modify: `gh-pr-review` (`write_pr_context` keeps the raw JSON; `build_prompt` asks for the findings block; the run
  section builds the record; the post block appends the marker and writes `round.json`)
- Modify: `tests/flow.sh`, `tests/pr-context.sh`
- Modify: `README.md` (Artifacts: `round.json`; one paragraph on the hidden marker)

**Interfaces:**
- Consumes: Task 2's functions.
- Produces: `$CONTEXT_DIR/discussion.json`, the raw `comments,reviews` JSON that `write_pr_context` already fetches.
- Produces: `ROUND`: 1 plus the number of reviews in `discussion.json` whose body contains
  `<!-- gh-pr-review generated -->`. `PREVIOUS_RECORD`: `marker_record` of the latest of those, or `null`. (Task 6
  moves both to the records that the loop check reads.)
- Produces: `$SESSION_DIR/round.json`, written after the review is assembled. A posted run adds `posted_at` and the
  decision. A `--no-post` run writes it with `"preview": true`.
- Produces: the posted body. The findings block is cut out, and the `marker_line` goes right after
  `<!-- gh-pr-review generated -->`.
- Produces: `HEAD_OID`, from `headRefOid`, added to the PR metadata query.

- [ ] **Step 1: Prompt.** Add to the end of `build_prompt`'s output format, in the quoted heredoc: after the
  Assessment, one fenced block tagged `json findings` with an array of `{severity, file, line, title}`, one entry per
  Critical, Important and Minor finding, `[]` when none. Tell the model to keep the Markdown findings as they are:
  the block is extra, for tooling, and is removed before posting.
- [ ] **Step 2: Flow tests.** Add to `tests/flow.sh`:
  - The stub code review ends with a findings block. The posted body has no `json findings` and has one
    `gh-pr-review:round` marker. `round.json` has the findings and `"source": "model"`.
  - A code review without a block: the record has `"source": "parsed"` and the post goes ahead.
  - Rethink: the record has `"code_review": false`, and the marker is posted.
  - The stub discussion has two earlier generated reviews, one with a round marker (round 2, findings F1 to F3):
    the new record has `"round": 3`, and its first finding is `F4`.
  - `--no-post`: `round.json` has `"preview": true`, and nothing is posted.
  - The code prompt asks for the `json findings` block.
- [ ] **Step 3: Run them.** Expected: the new cases fail.
- [ ] **Step 4: Implement.** In `write_pr_context`, write `discussion.json`. After the code review, run
  `cut_findings_block` on `review.md` into `review-body.md` and `findings.json`. Use `findings.json` if jq accepts it
  as an array, else `parse_findings review-body.md`. Assemble the posted review from `review-body.md`. Build the
  record. In the post block, insert the marker line and write `round.json`. The display shows the body without the
  block.
- [ ] **Step 5: README.** Under Artifacts, add `round.json`. Add a short "Round history" paragraph: what the hidden
  marker holds, and that it never holds `--instructions` text.
- [ ] **Step 6: Check.**
- [ ] **Step 7: Commit.** `git commit -m "Record each review round on the PR and in round.json"`

### Task 5: `gh pr-review rounds <PR>`

**Files:**
- Create: `lib/rounds.sh`, `tests/rounds.sh`
- Modify: `README.md` (Usage: `rounds`)

**Interfaces:**
- Consumes: `resolve_target`, `use_gh_user`, `marker_record`, `backfill_record`, `loop_decide_json`.
- Produces: `fetch_round_records <host> <owner> <repo> <N>`, which prints the records array, oldest first. It reads
  the PR's reviews (REST, paginated, with `commit_id` and `submitted_at`) and keeps those with the `generated`
  marker. For each, it uses the marker record, or else `backfill_record` with the previous record. A backfill
  record's head is the review's `commit_id`.
- Produces: `cmd_rounds <PR> [--json] [-u <login>]`. It also reads the commit dates and the PR size, and prints one
  row per round, then the decision for the next round:

```
ROUND  DATE         COMMIT   +COMMITS  APPROACH      READY  CRIT  IMP  MINOR  LABEL       SOURCE
1      11-24 15:03  48963e5  1         questionable  no     2     7    1      early       backfill
…
next round: stop · churning · approach-stuck too-big · Settle the approach before the next round: …
```

  `+COMMITS` is the number of commits dated after the previous round and up to this one. A Rethink row shows `–` in
  the count columns and `rethink` as its label. `--json` prints `{records, decision}` instead.

- [ ] **Step 1: Write `tests/rounds.sh`** with a stub `gh` that returns three reviews: one plain comment (ignored),
  one backfill review, one with a round marker. It also returns four commits and the PR size. Check the rows,
  `+COMMITS`, the sources, the labels, a Rethink row, the last line, and the `--json` output.
- [ ] **Step 2: Run it.** Expected: it fails.
- [ ] **Step 3: Implement** `fetch_round_records` and `cmd_rounds`.
- [ ] **Step 4: README.** Add `gh pr-review rounds <PR>` under Usage, with two sample rows and the last line.
- [ ] **Step 5: Check.**
- [ ] **Step 6: Commit.** `git commit -m "Add gh pr-review rounds to print a PR's review history"`

### Task 6: The loop check in the review run

**Files:**
- Modify: `gh-pr-review` (flags `--check`, `--json`, `--force-round`; the loop check between the PR metadata and the
  clone; the loop line in the posted body; `loop` and `forced` in the record)
- Modify: `lib/loop.sh` (`lifted_since`)
- Modify: `tests/flow.sh`, `tests/loop.sh`
- Modify: `README.md` (the loop check, `--check`, `--force-round`, exit codes)

**Interfaces:**
- Consumes: `fetch_round_records`, `loop_decide_json`, `loop_text`, `loop_line`.
- Produces: `lifted_since <host> <owner> <repo> <N> <time> <pr-author>`: prints `true` when an issue comment, a
  review, or an inline review comment created after `<time>` has a `user.type` other than `Bot`, a login other than
  `<pr-author>`, and no `gh-pr-review generated` marker. Otherwise `false`.
- Produces: `RECORDS` and `LOOP` (the decision JSON), computed right after the PR metadata. `ROUND` becomes
  `LOOP.next_round`, and `PREVIOUS_RECORD` the last record. Task 4's count from `discussion.json` goes away.
- Produces: the flow:
  - `--check`: print `loop_text` (or the JSON with `--json`), then exit 0 for `run` and `warn`, 3 for `stop`, 5 for
    `nothing-new`. No clone, no pi.
  - `nothing-new` without `--force-round`: print "No new commits since round K (<sha>)." and exit 5.
  - `stop` without `--force-round`: print `loop_text` to stderr. With a terminal on stdin and without `-y`, ask
    "Run round K anyway? [y/N]"; `y` goes on as forced. Otherwise exit 3.
  - `warn`: print one line, run, and put `loop_line` at the top of the posted body, after the markers.
  - `--force-round`: run whatever the decision; the record gets `"forced": true`.
  - The record gets `"loop": {"label", "flags", "decision"}`.
- Exit codes: 0 done, 1 error, 3 stopped by the loop check, 5 no new commits.

- [ ] **Step 1: Flow tests.** Teach the stub `gh` the REST calls (reviews with markers, issue comments, inline
  comments, commits, PR size and `headRefOid`), then add:
  - Four earlier rounds with blocking 9, 12, 8, 10 (rounds 3 and 4 are churning) and `-y`: exit 3, no clone, no
    pi call, the diagnosis on stderr.
  - The same without `-y` and with stdin from `/dev/null`: exit 3, no prompt.
  - The same with `--force-round`: the round runs, and the record has `"forced": true`.
  - The same with a later comment by another person: the round runs, as a warn.
  - The same with a later comment by the PR author, or by a `Bot`: still exit 3.
  - Three earlier rounds with blocking 9, 12, 8 (only round 3 is churning): the round runs, and the posted body
    starts (after the markers) with `**Loop:** Churning`.
    The decision still comes from the "Ready to merge?" line.
  - Head equals the last round's head: exit 5, no clone. With `--force-round`: the round runs.
  - `--check` on each case: the right exit code, no clone, no pi. `--check --json` prints the decision JSON.
  - No earlier rounds: the round runs as round 1, with no loop line.
- [ ] **Step 2: Run them.** Expected: the new cases fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: README.** A "Loop check" section: what it measures, warn and stop, `--check`, `--force-round`, what
  lifts a stop, and the exit codes.
- [ ] **Step 5: Check.**
- [ ] **Step 6: Commit.** `git commit -m "Check the review loop before a round, and stop loops that do not converge"`

### Task 7: Check PR 1 on real PRs

**Files:**
- Create: `docs/superpowers/specs/2026-11-26-review-tracking-results.md`

- [ ] **Step 1: History.** Run `gh pr-review rounds <PR> --json` on the twelve PRs in the spec's calibration table
  (use `-u catalan_adobe` for of1-labs). Expected: the blocking series of the Why and calibration tables, with the
  Rethink round of adobe/skills#813 as `null`, and the labels of the calibration table.
- [ ] **Step 2: Loop check.** `gh pr-review <PR> --check` on the open ones. Expected: adobe/skills#813 stops (exit
  3), suggesting to settle the approach. adobe/skills#823 runs (exit 0). of1-labs#331 runs.
- [ ] **Step 3: Preview run.** `gh pr-review <an open PR> --no-post`. Expected: `round.json` with
  `"source": "model"`. Its findings match the Markdown findings in count and severity. The loop line appears when
  the check warns.
- [ ] **Step 4: Record results.** Counts, labels, sources and mismatches only. No review text: this repo is public.
- [ ] **Step 5: Commit.** `git commit -m "Record PR 1 checks on real review history"`
