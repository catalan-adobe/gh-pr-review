# Owner Approach Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a maintainer-style approach pass before the code review in `gh-pr-review`. A Rethink verdict stops
the run and posts request-changes.

**Architecture:** The script stays one Bash file. It gains a second `pi --print` call, the owner pass, before the
existing one. It also gains a shared verdict parser and writes PR context files to the session directory. The post
block
learns one new rule: Rethink picks request-changes.

**Tech Stack:** Bash (`set -euo pipefail`), `gh`, `jq`, `pi`. Lint: `shellcheck`, `shfmt`. Tests: plain Bash
stub scripts in `tests/`.

**Spec:** `docs/superpowers/specs/2026-11-23-owner-approach-pass-design.md`

## Global Constraints

- Every script starts with `set -euo pipefail`. `shellcheck gh-pr-review` and `shfmt -d gh-pr-review` are clean.
- Prompt text goes in quoted heredocs (zero expansion). Dynamic values go through `printf` or unquoted heredocs
  with SHAs only, as the script does today.
- The verdict line format is exactly `**Approach:** Sound | Questionable | Rethink`.
- A missing or unparseable approach verdict never blocks: the code review runs.
- `--decision` overrides every computed decision. On your own PR, the decision is always comment.
- The two prompt examples must not resemble of1-labs#331 (no job types, no Figma, no runners).

## Review Focus

- The approach text contains the words "ready to merge" (quoting the PR). The decision must still come from the
  code review's final "Ready to merge?" line. Test in Task 1.
- The model writes the verdict in bold, lowercase, or with a trailing period (`**Approach:** **rethink**.`). It
  must still parse. Test in Task 1.
- The model quotes the verdict format earlier in its text and gives a real verdict at the end. The last line
  wins. Test in Task 1.
- The PR has no comments or reviews. `pr-discussion.md` must still exist and say so. Check in Task 2.
- The owner `pi` call fails (non-zero exit). The run must stop with the session dir path, like the code review
  does today. Check in Task 3.

---

### Task 1: Shared verdict parser and Rethink decision

**Files:**
- Modify: `gh-pr-review` (post block, around the `VERDICT=$(…grep -i 'ready to merge'…)` line)
- Modify: `tests/post-decision.sh`
- Create: `tests/verdict.sh`
- Modify: `.github/workflows/ci.yml` (run `tests/*.sh`)

**Interfaces:**
- Produces: `last_verdict <label> <text>`. It prints the lowercased value after the last line that contains
  `<label>` (case-insensitive), with `*_`.` stripped and spaces trimmed. Empty output when no line matches.
  Defined above the `── post` marker, in a block that starts with `# ── verdicts` so tests can `sed` it out.
- Produces: the post block reads `APPROACH_VERDICT` (empty, `sound`, `questionable`, `rethink`). When `DECISION`
  is empty and `APPROACH_VERDICT` is `rethink`, the decision is `request-changes`. Otherwise the existing
  "ready to merge" rule applies.

- [ ] **Step 1: Write `tests/verdict.sh`.** It extracts `last_verdict` with
  `sed -n '/^# ── verdicts/,/^# ── post/p'` and checks:

```bash
check "plain"        'Approach'        '**Approach:** Rethink'                                  rethink
check "bold+period"  'Approach'        '**Approach:** **questionable**.'                         questionable
check "last wins"    'Approach'        $'**Approach:** Sound | Questionable | Rethink\n**Approach:** Sound' sound
check "missing"      'Approach'        'no verdict here'                                        ''
check "merge label"  'ready to merge'  '**Ready to merge?** Yes with fixes'                     'yes with fixes'
```

- [ ] **Step 2: Add cases to `tests/post-decision.sh`.** `check` gains an `APPROACH_VERDICT` argument (default
  empty for existing cases):

```bash
check "rethink"               '**Approach:** Rethink'                      bob me '' rethink      --request-changes
check "questionable + yes"    '**Ready to merge?** Yes'                    bob me '' questionable --approve
check "rethink + explicit"    'x'                                          bob me comment rethink --comment
check "rethink own PR"        'x'                                          me  me '' rethink      --comment
check "approach quotes merge" $'quote: ready to merge yes\n**Ready to merge?** No' bob me '' sound --request-changes
```

- [ ] **Step 3: Run both tests.** `bash tests/verdict.sh; bash tests/post-decision.sh`. Expected: the new cases
  fail (no `last_verdict` yet, Rethink rule missing).
- [ ] **Step 4: Implement.** Add the `# ── verdicts` block with `last_verdict`. In the post block, change the
  `VERDICT=` line to `VERDICT=$(last_verdict 'ready to merge' "$REVIEW")`. Add the Rethink rule before the
  `case "$VERDICT"`. When the Rethink rule fires, print `Approach: <verdict> → <decision>`.
- [ ] **Step 5: Run tests and lint.** `for t in tests/*.sh; do bash "$t" || exit 1; done && shellcheck gh-pr-review tests/*.sh && shfmt -d gh-pr-review tests/*.sh`.
  Expected: all `ok`, no lint output.
- [ ] **Step 6: CI.** Add a `tests` step to `ci.yml`: `for t in tests/*.sh; do bash "$t"; done`. Extend the
  shellcheck and shfmt steps to `tests/*.sh`.
- [ ] **Step 7: Commit.** `git commit -m "Share verdict parsing and request changes on a Rethink approach"`

### Task 2: PR context files

**Files:**
- Modify: `gh-pr-review` (after `clone + checkout`, before `build review prompt`)

**Interfaces:**
- Produces: `$SESSION_DIR/context/pr-body.md` (title as `# <title>`, then the body) and
  `$SESSION_DIR/context/pr-discussion.md`. One entry per comment or review, oldest first, as
  `## <author> · <state or "comment"> · <ISO date>` then the body. Empty review bodies are skipped. With no
  entries the file contains `(no comments or reviews)`.
- Produces: `CONTEXT_DIR` variable.

- [ ] **Step 1: Implement.** Fetch with
  `gh pr view "$PR_NUM" --repo "$GH_HOST_NAME/$OWNER/$REPO" --json comments,reviews`. Build the markdown with one
  `jq -r` filter. It merges `.comments` and `.reviews` and maps `submittedAt // createdAt`. It sorts by date and
  drops empty bodies. Write the body file with `printf`.
- [ ] **Step 2: Check by hand.** Run the context block against of1-labs#331. To do that, stop the script after
  the block, or run `gh pr-review <url> --no-post` up to it. Expected: `pr-discussion.md` lists `catalan_adobe` and `adobe-talos`
  reviews and the `ssandal_adobe` reply, oldest first. Run it against a PR with no comments (of1-labs#468).
  Expected: `(no comments or reviews)`.
- [ ] **Step 3: Lint.** `shellcheck gh-pr-review && shfmt -d gh-pr-review`. Expected: clean.
- [ ] **Step 4: Commit.** `git commit -m "Write PR body and discussion to the session for the reviewer"`

### Task 3: Owner pass, flow, and flag

**Files:**
- Modify: `gh-pr-review` (header usage, arg parsing, new `build_owner_prompt`, `build_prompt`, run section,
  display)
- Modify: `README.md` (options table, "What a review looks like", Artifacts)

**Interfaces:**
- Consumes: `last_verdict` and `APPROACH_VERDICT` handling (Task 1). `CONTEXT_DIR` (Task 2).
- Produces: `--skip-approach` flag (`SKIP_APPROACH=false` default). `run_pi <prompt-file> <out-file>`, which wraps
  the existing `pi "${PI_ARGS[@]}" …` call and exits with the session dir on failure. Files `owner-prompt.md`,
  `approach.md`, `prompt.md`, `review.md`.

- [ ] **Step 1: Footer.** Move the `*Review generated by gh pr-review · model: …*` footer out of the code-review
  prompt. The script appends it once to the posted body. It prints it once on screen.
- [ ] **Step 2: `build_owner_prompt`.** It writes `owner-prompt.md`. The text is the spec's "Owner prompt"
  section, nearly word for word. It holds the role, the six steps and the signal list. It also holds the verdict
  rubric, the evidence rule, the read-only rule and the output template. Steps 1 and 2 get the real `BASE_SHA`
  and `HEAD_SHA` through an unquoted heredoc.
  Step 3 names `$CONTEXT_DIR/pr-body.md` and `pr-discussion.md` by absolute path. Add the two invented examples:
  - Sound: a PR that adds a CSV export next to an existing JSON export through the existing exporter interface.
    About 8 lines. It ends `**Approach:** Sound`.
  - Rethink: a PR that adds a hand-written retry loop and a second HTTP client to one handler. The repo already
    has a shared client with retries, and its `AGENTS.md` requires it. It names the alternative and its cost.
    It ends `**Approach:** Rethink`.
- [ ] **Step 3: `build_prompt` takes the approach notes.** Check that `approach.md` exists and is not empty.
  Then add a `## Maintainer's approach notes` section after "Requirements / Plan". The section holds the file.
  Add: "A maintainer already judged the approach. Do not argue it again. Review the implementation."
- [ ] **Step 4: Flow.** Replace the run section:
  1. If `SKIP_APPROACH` is false: `build_owner_prompt`, print `⏳  Owner pass…`, `run_pi owner-prompt.md
     approach.md`, then `APPROACH_VERDICT=$(last_verdict 'approach' "$(cat approach.md)")`. Print
     `Approach: <verdict or "not found">`.
  2. If `APPROACH_VERDICT` is `rethink`: `REVIEW=$(cat approach.md)` and skip the code review.
  3. Otherwise: `build_prompt`, `run_pi prompt.md review.md`. `REVIEW` is the approach text (if any), a blank
     line, then the review text.
  4. Append the footer to `REVIEW`.
- [ ] **Step 5: Flag and docs.** Add `--skip-approach` in four places. They are the header usage comment, the arg
  parser, the usage line and the README options table. In the README, add an `### Approach` block to "What a
  review looks like". List the new files under Artifacts. Run `se lint README.md` and fix the findings.
- [ ] **Step 6: Lint and tests.** `for t in tests/*.sh; do bash "$t" || exit 1; done && shellcheck gh-pr-review tests/*.sh && shfmt -d gh-pr-review tests/*.sh`.
  Expected: all `ok`, no lint output.
- [ ] **Step 7: Smoke run.** `./gh-pr-review https://github.com/Adobe-AEM-Foundation/of1-labs/pull/468 --no-post`.
  Expected: an Approach section with a verdict line, and the code review below it unless the verdict is Rethink.
  Then run with `--skip-approach`. Expected: no Approach section, one model call.
- [ ] **Step 8: Commit.** `git commit -m "Add an owner approach pass before the code review"`

### Task 4: Test set run

**Files:**
- Create: `docs/superpowers/specs/2026-11-23-owner-approach-pass-results.md`

- [ ] **Step 1: Run the test set**, with `--no-post`, twice each:
  - `https://github.com/Adobe-AEM-Foundation/of1-labs/pull/331`. Expected: Questionable or Rethink. The text names
    feature branches in shared Replica files or the phase translation layer, and a separate type or mode.
  - `…/pull/467`, `…/pull/454`, `…/pull/448`. Expected: Sound, with a short Approach section.
- [ ] **Step 2: Record results.** For each run, record the verdict and the run time. For 331, also record if it
  named the structural problem. Copy the 331 Approach section into the file.
- [ ] **Step 3: Tune at most once.** A control PR that gets Rethink is a failure. So is 331 getting Sound on both
  runs. On a failure, change the
  owner prompt once. Rerun only the failing case and record the change. If it still fails, stop and report. Do
  not tune again.
- [ ] **Step 4: Commit.** `git commit -m "Record owner approach pass test-set results"`
