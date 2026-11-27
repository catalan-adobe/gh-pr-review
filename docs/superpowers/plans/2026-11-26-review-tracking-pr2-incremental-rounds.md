# Review Tracking PR 2, Incremental Rounds: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From round 2, the reviewer checks every earlier finding by ID (fixed, open, declined), reviews what changed
since the last round in full, and raises new findings in unchanged code only when they are Critical. Everything else
there goes to a non-blocking Later list. The posted review starts with a progress line. Open blocking findings can
then reach zero, and the loop check of PR 1 reads open counts instead of found counts.

**Architecture:** Same script and libraries as PR 1. New: `lib/delta.sh` picks how to show what changed, the code
review prompt gains a "Previous round" section, and `build_record` learns statuses. The owner pass carries its
previous verdict forward.

**Tech Stack:** Bash (`set -euo pipefail`), `gh`, `git`, `jq`, `pi`. Lint: `shellcheck`, `shfmt`. Tests: plain Bash
scripts in `tests/`, with stubs for `gh` and `pi`, and real `git` on local repos for the delta.

**Spec:** `docs/superpowers/specs/2026-11-26-review-tracking-design.md`, phase 3 ("What round 2 and later get", "The
posted body, round 2 and later"). Needs PR 1 (records, `PREVIOUS_RECORD`, the loop check).

**Check** (every task ends with it):
`for t in tests/*.sh; do bash "$t" || exit 1; done && shellcheck gh-pr-review lib/*.sh tests/*.sh && shfmt -d gh-pr-review lib/*.sh tests/*.sh`.
Expected: all `ok`, no lint output.

## Global Constraints

- All PR 1 constraints hold.
- Finding IDs belong to the script. The model repeats the IDs it was given and leaves new findings without one. The
  script numbers new findings (`F<n>`) and Later items (`L<n>`), continuing from the previous record.
- Every previous open finding ends up in the new record, even when the model forgets it: it is carried as `open`
  with `"unverified": true`. Nothing disappears silently.
- The numbers in the progress line come from the record, never from the model's text.
- A round without a usable previous record (none, or `source: backfill` with no IDs) is a full round with rule 3
  off, as today. The record says `"mode": "full"`.
- Until PR 3, the checkout is the fresh depth-50 clone. When the previous head is not there and cannot be fetched,
  the round is full. It never fails because of that.
- Test fixtures are synthetic, as in PR 1. Tests never use the network: git tests point `https://h/o/r.git` at a
  local bare repo with `url.<path>.insteadOf` set through `GIT_CONFIG_COUNT`.

## Review Focus

- The model reports a previous ID twice, an ID that never existed, or a status outside the list. Duplicates keep the
  first entry, unknown IDs become new findings, bad statuses become `open` with `"unverified": true`. Test in
  Task 3.
- A finding marked `fixed` in an earlier round comes back as `open`: it is `regressed`, and counts as blocking.
  Test in Task 3.
- The model says "Ready to merge? Yes" while the record has open blocking findings. The record wins: the decision is
  comment, and the record says `"ready_overridden": true`. Test in Task 3.
- The author rebased between rounds: the previous head is not an ancestor of the new head. The prompt gets a
  `range-diff`, not a `diff` that includes the base branch's changes. Test in Task 1.
- The previous head is gone (force-push) and fetching it by SHA fails. The round is full, and the run says why.
  Test in Task 1.
- The owner pass says "Unchanged" but its verdict line differs from the previous one. The verdict line wins, as
  always. Test in Task 4.
- The progress line and the PR 1 loop line never both appear. Test in Task 5.

---

### Task 1: What changed since the last round

**Files:**
- Create: `lib/delta.sh`, `tests/delta.sh`

**Interfaces:**
- Produces: `pick_delta <repo-dir> <prev-head> <prev-base> <head> <base>`, which prints JSON
  `{"mode": "incremental" | "rebased" | "full", "reason": "…", "commands": ["…"]}`:
  - `incremental`: the previous head exists and is an ancestor of the head. Commands:
    `git diff --stat <prev-head>..<head>` and `git diff <prev-head>..<head>`.
  - `rebased`: both previous SHAs exist, and the previous head is not an ancestor. Commands:
    `git range-diff <prev-base>..<prev-head> <base>..<head>`.
  - `full`: anything else, with the reason ("no previous round", "previous head not found after fetch", …).
- Before giving up on a missing SHA, it tries `git fetch --depth 50 origin <sha>` once, with `GIT_AUTH` and hooks
  off. GitHub serves commits that are still reachable from some ref, including `refs/pull/*`.
- Produces: `changed_files <repo-dir> <delta-json>`, the paths the delta touched, used by the prompt to tell the
  reviewer which code counts as "touched".

- [ ] **Step 1: Write `tests/delta.sh`** with real git: a bare "remote" with a PR branch. Cases: a plain new commit
  (incremental), a rebase onto a moved base (rebased), a force-push to unrelated history with the old head deleted
  from the remote (full, with the reason), no previous record (full), and a shallow clone where the previous head is
  older than the depth but still fetchable (incremental after the fetch).
- [ ] **Step 2: Run it.** Expected: it fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Check.**
- [ ] **Step 5: Commit.** `git commit -m "Pick how to show what changed since the last round"`

### Task 2: The code review prompt for round 2 and later

**Files:**
- Modify: `gh-pr-review` (`build_prompt`; the run section writes the previous-round context files)
- Modify: `tests/flow.sh`

**Interfaces:**
- Consumes: `PREVIOUS_RECORD`, `pick_delta`, `changed_files`, `discussion.json`.
- Produces: `$CONTEXT_DIR/previous-review.md`, the previous round's posted body without markers.
  `$CONTEXT_DIR/previous-findings.md`, one line per open, new or regressed finding of the previous record:
  `F3 · critical · skills/x.md:106 · <title>`.
- Produces: in `build_prompt`, when the mode is not `full`, a `## Previous round` section after the PR discussion
  section, in a quoted heredoc with the paths and commands printed in. It says:
  1. Read `previous-findings.md` and `previous-review.md`. Check each listed finding against the current code.
     Report it as `fixed`, `open` or `declined`. Declined only when the discussion gives a reason you accept; quote
     it. A fix attempt that did not work stays `open`; say what is still wrong.
  2. Review what changed in full, at every severity (the delta commands follow). A problem the new commits
     introduced is new, with `"in_delta": true`.
  3. In code the delta did not touch (anything outside `changed_files`), raise a new finding only if it is
     Critical, and say why earlier rounds missed it. Put Important and Minor issues there under Later.
- Produces: the findings block schema for round 2 and later: an array of `{id, status, severity, file, line,
  title, in_delta, later}`. `id` is the given ID for an earlier finding and `null` for a new one. `later: true`
  marks a Later item.
- Produces: the Markdown output format for round 2 and later: Issues (open, regressed and new findings by
  severity), then `<details><summary>Fixed since round K (n)</summary>`, then `<details><summary>Later (n)</summary>`.
  Strengths, Recommendations and the Assessment stay.
- With `mode: full` and a previous record with IDs (`--full`, or a delta that fell back): rule 1 applies, rules 2
  and 3 do not, and the whole PR is reviewed.

- [ ] **Step 1: Flow tests.** A stub history with a previous marker record (F1 to F3, one fixed in an earlier round).
  Check that the code prompt: has the Previous round section with all three rules and the `diff` commands
  (incremental), has `range-diff` (rebased), has rule 1 only (full with IDs), and has no Previous round section on
  round 1.
- [ ] **Step 2: Run them.** Expected: they fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Check.**
- [ ] **Step 5: Commit.** `git commit -m "Give round 2 and later the previous findings and what changed"`

### Task 3: Records with statuses

**Files:**
- Modify: `lib/records.jq`, `lib/records.sh` (`build_record`)
- Modify: `tests/records.sh`

**Interfaces:**
- Produces: `build_record` with statuses. From the model's array and the previous record:
  - An entry with a known ID keeps it. Its status is the model's, except that `open` on an ID whose last status was
    `fixed` becomes `regressed`.
  - Entries without an ID become `F<n>` (or `L<n>` with `later: true`), continuing from the previous record.
  - Every previous `open`, `new` or `regressed` ID missing from the reply is carried as `open` with
    `"unverified": true`.
  - Duplicates keep the first entry. Unknown IDs become new findings. A bad status becomes `open` with
    `"unverified": true`.
  - `counts`: `open_blocking` (critical and important that are open, new or regressed, without Later), `new`,
    `fixed`, `declined`, `regressed`, `later`, `unverified`.
  - `ready_overridden: true` and decision `comment` when the model's ready is yes or yes-with-fixes and
    `open_blocking > 0`.
- The loop rules need no change: they already read `counts.open_blocking`.

- [ ] **Step 1: Tests.** Each rule above, one case each, plus a full round 3 built on a round 2 record that has
  every status.
- [ ] **Step 2: Run them.** Expected: they fail.
- [ ] **Step 3: Implement.** The post block reads `ready_overridden` and uses comment.
- [ ] **Step 4: Check.**
- [ ] **Step 5: Commit.** `git commit -m "Track each finding's status across rounds"`

### Task 4: The owner pass carries its verdict

**Files:**
- Modify: `gh-pr-review` (`build_owner_prompt`)
- Modify: `tests/flow.sh`

**Interfaces:**
- Produces: `$CONTEXT_DIR/previous-approach.md`, the `### Approach` section of the previous round's body (up to the
  next `### ` heading), when there is one.
- Produces: in `build_owner_prompt`, for round 2 and later with a previous approach, a `## Your previous verdict`
  section: the file path and the delta's `--stat`. It says: keep the verdict unless what changed, or the discussion
  since, changes it. If nothing changes it, reply only:

```
### Approach

Unchanged since round K: <one sentence>.

**Approach:** <the same verdict>
```

- The verdict line is parsed as today. A changed verdict line wins over the word "Unchanged".

- [ ] **Step 1: Flow tests.** The owner prompt has the section on round 2 with a previous approach, and not on
  round 1 or after a Rethink-only previous round. A stub owner reply in the short form posts as is, and its verdict
  parses.
- [ ] **Step 2: Run them.** Expected: they fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Check.**
- [ ] **Step 5: Commit.** `git commit -m "Carry the approach verdict across rounds"`

### Task 5: The progress line and `--full`

**Files:**
- Modify: `gh-pr-review` (`assemble_review` gets the progress line; a `--full` flag)
- Modify: `lib/records.sh` (`progress_line`)
- Modify: `tests/flow.sh`, `tests/records.sh`
- Modify: `README.md` (round 2 and later, `--full`, an example progress line)

**Interfaces:**
- Produces: `progress_line <record> <previous-record> <loop-json>`:

```
### Round 3 · since round 2
4 fixed · 2 still open · 3 new (1 in the new commits) · open blocking: 5 (was 6) · loop: converging
```

  Zero counts are left out. `unverified` findings add "· 1 not re-checked". A full round adds "· full review
  (<reason>)".
- The posted body: markers, then the progress line, then the approach, then the code review. The PR 1 loop line is
  not added when there is a progress line.
- Produces: `--full`, which forces `mode: full` (rule 1 only when the previous record has IDs).

- [ ] **Step 1: Tests.** `progress_line` cases: all counts, zero counts dropped, unverified, full. Flow: a round 2
  posts the progress line and no loop line; `--full` makes a full round whose prompt has rule 1 only.
- [ ] **Step 2: Run them.** Expected: they fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: README.** "Round 2 and later": what the reviewer gets, the Later list, the progress line, `--full`.
- [ ] **Step 5: Check.**
- [ ] **Step 6: Commit.** `git commit -m "Start later rounds with a progress line, and add --full"`

### Task 6: Check PR 2 on real PRs

**Files:**
- Modify: `docs/superpowers/specs/2026-11-26-review-tracking-results.md`

- [ ] **Step 1: Preview rounds.** `gh pr-review <PR> --no-post` on a PR whose last round has a PR 1 marker record,
  after the author pushed (adobe/skills#823 is a candidate, being mine and public). Expected: an incremental mode,
  every previous ID accounted for, plausible statuses, the progress line consistent with `round.json`.
- [ ] **Step 2: Rebase case.** The same on a PR rebased since its last round, if one is at hand. Expected: rebased
  mode, or full with the reason.
- [ ] **Step 3: One posted round.** On one of my own PRs, only after I say yes. Expected: the progress line on
  GitHub, and `rounds` shows the open count.
- [ ] **Step 4: Record results.** Modes, counts, how many findings were unverified, and anything the model got
  wrong. No review text.
- [ ] **Step 5: Commit.** `git commit -m "Record PR 2 checks on real PRs"`
