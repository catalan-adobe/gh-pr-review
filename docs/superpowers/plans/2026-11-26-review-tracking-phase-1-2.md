# Review Tracking, Phases 1 and 2: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every posted review leaves a round record (a hidden marker on GitHub and `round.json` on disk), and
`gh pr-review rounds <PR>` prints a PR's round history. Reviews run in a review worktree of my local clone, at
`<clone>.reviews/<head-branch>/<N>`, with all run files in one state folder. `gh pr-review gc` cleans up.

**Architecture:** The entry script stays Bash and gains a subcommand dispatch. New code lives in `lib/*.sh`
(functions only, no side effects when sourced) and `lib/records.jq`. The reviewer (pi) runs with a git sandbox: no
credentials, no hooks, a read-only `git` wrapper first on its `PATH`, and a tripwire on the review worktree.

**Tech Stack:** Bash (`set -euo pipefail`), `gh`, `git`, `jq`, `pi`. Lint: `shellcheck`, `shfmt`. Tests: plain Bash
scripts in `tests/`, with stubs for `gh` and `pi`, and real `git` on local repos.

**Spec:** `docs/superpowers/specs/2026-11-26-review-tracking-design.md` (phases 1, 2 and 6).

Two PRs: Tasks 1 to 5 are phase 1, Tasks 6 to 11 are phase 2. Phase 2 does not need phase 1, but this order keeps
the flow tests simple.

## Global Constraints

- Every script starts with `set -euo pipefail`. `shellcheck` and `shfmt -d` are clean on `gh-pr-review`,
  `lib/*.sh`, `lib/git-ro` and `tests/*.sh`.
- `lib/*.sh` files only define functions and constants. Sourcing one runs nothing. Tests source them directly.
- Prompt text goes in quoted heredocs. Dynamic values go through `printf`, or unquoted heredocs with SHAs only.
- A records failure never blocks a post: a bad findings block falls back to parsing, and a parse failure leaves a
  record with `"source": "parsed"` and empty findings.
- The posted Markdown is today's Markdown, minus the findings block, plus one marker line. Nothing else changes.
- No git command of the script changes my clone's branches, remote-tracking refs, `HEAD`, index, stash, config or
  working tree. It only writes `refs/pr-review/*` and the review worktree.
- Every git command the script runs against a clone uses `-c core.hooksPath=/dev/null`.
- `--fresh` gives today's checkout: a throwaway clone, now inside the run folder.
- Test fixtures are synthetic. This repo is public, and the real reviews come from internal repos. Fixtures copy the
  formats (bullets, numbered items, a Rethink-only review, a review from before the approach pass), never the text.
- Tests never use the network. Git tests point `https://h/o/r.git` at a local bare repo with `url.<path>.insteadOf`
  set through `GIT_CONFIG_COUNT`.

## Review Focus

- A finding title contains `--`, `-->` or `<!--` (real titles quote `--extend`). The marker must still be one valid
  HTML comment, and decode to the same title. Test in Task 2.
- The model writes the findings block in the middle of the reply, twice, or as plain ` ```json ` with no `findings`
  tag. The last ` ```json findings ` block wins. A plain `json` block is left in the body and the run falls back to
  parsing. Test in Task 2.
- A Rethink run has no code review. Its record has `"code_review": false`, empty findings, and null counts, never
  zeros. Test in Tasks 2 and 3.
- Earlier rounds by another reviewer, and old reviews with the `generated` marker but no round marker, both count
  toward K. A `--no-post` run never does. Test in Task 3.
- The PR's head branch is `main` on a fork, contains `/`, or is 200 characters long. Test in Task 8.
- My own PR's branch is checked out in my clone or one of its worktrees. The detached review worktree still works.
  Test in Task 8.
- The author force-pushes between two rounds. `refs/pr-review/<N>/round-<K>` keeps the old commit. Test in Task 8.
- My clone is shallow or partial. The run skips it, says why, and uses the cache clone. Test in Task 7.
- While pi runs, I commit in my clone. That is a warning, not a stop. Test in Task 9.
- A run is killed and leaves its lock behind. The next run takes the lock over when the recorded PID is gone. Test
  in Task 6.

---

## Phase 1: Round records

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
- Produces: dispatch. When the first argument is `rounds` or `gc`, the script shifts it off and calls
  `cmd_rounds "$@"` or `cmd_gc "$@"`, then exits. `status` and `shepherd` are reserved: they print "not yet
  available" and exit 1. Anything else is a review, as today.

- [ ] **Step 1: Move code.** Move `last_verdict` to `lib/verdicts.sh`, and the target parsing and token export to
  `lib/common.sh`. Source `lib/*.sh` at the top of `gh-pr-review`.
- [ ] **Step 2: Tests.** `tests/verdict.sh` and `tests/post-decision.sh` source `lib/verdicts.sh`. The post block
  is still cut from `gh-pr-review` with `sed`.
- [ ] **Step 3: Dispatch.** Add it before argument parsing. Add the subcommands to `--help`.
- [ ] **Step 4: Run tests and lint.** `for t in tests/*.sh; do bash "$t" || exit 1; done && shellcheck gh-pr-review lib/*.sh tests/*.sh && shfmt -d gh-pr-review lib/*.sh tests/*.sh`.
  Expected: all `ok`, no lint output. Then `gh pr-review status` prints "not yet available".
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
  after the highest number in the previous record. Phase 1 sets every status to `new` and leaves `later` empty.
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
  `jq -L "$LIB_DIR" 'include "records"; …'`, so later phases reuse it.
- [ ] **Step 5: Run tests and lint.** As in Task 1, Step 4. Expected: all `ok`, no lint output.
- [ ] **Step 6: Commit.** `git commit -m "Add round records: findings parser, record builder and marker"`

### Task 3: Records in the review run

**Files:**
- Modify: `gh-pr-review` (`write_pr_context` keeps the raw JSON; `build_prompt` asks for the findings block; the run
  section builds the record; the post block appends the marker and writes `round.json`)
- Modify: `tests/flow.sh`, `tests/pr-context.sh`
- Modify: `README.md` (Artifacts: `round.json`; one paragraph on the hidden marker)

**Interfaces:**
- Consumes: Task 2's functions.
- Produces: `$CONTEXT_DIR/discussion.json`, the raw `comments,reviews` JSON that `write_pr_context` already fetches.
- Produces: `ROUND`: 1 plus the number of reviews in `discussion.json` whose body contains
  `<!-- gh-pr-review generated -->`. `PREVIOUS_RECORD`: `marker_record` of the latest of those, or `null`.
- Produces: `$SESSION_DIR/round.json`, written after the review is assembled. A posted run adds `posted_at` and the
  decision. A `--no-post` run writes it with `"preview": true`.
- Produces: the posted body. The findings block is cut out, and the `marker_line` goes right after
  `<!-- gh-pr-review generated -->`.

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
- [ ] **Step 6: Run tests and lint.** As in Task 1, Step 4.
- [ ] **Step 7: Commit.** `git commit -m "Record each review round on the PR and in round.json"`

### Task 4: `gh pr-review rounds <PR>`

**Files:**
- Create: `lib/rounds.sh`, `tests/rounds.sh`
- Modify: `README.md` (Usage: `rounds`)

**Interfaces:**
- Consumes: `resolve_target`, `use_gh_user`, `marker_record`, `backfill_record`.
- Produces: `cmd_rounds <PR> [--json] [-u <login>]`. It fetches the PR's reviews (REST, paginated, with
  `commit_id`) and commit dates. Then it keeps the reviews with the `generated` marker, oldest first. For each, it
  uses the marker record, or else `backfill_record` with the previous record. It prints one row per round:

```
ROUND  DATE         COMMIT   +COMMITS  APPROACH      READY           CRIT  IMP  MINOR  SOURCE
1      11-24 15:03  48963e5  1         questionable  no              2     7    1      backfill
```

  `+COMMITS` is the number of commits dated after the previous round and up to this one. A Rethink row shows `–` in
  the three count columns. `--json` prints the array of records instead.

- [ ] **Step 1: Write `tests/rounds.sh`** with a stub `gh` that returns three reviews: one plain comment (ignored),
  one backfill review, one with a round marker. It also returns four commits. Check the rows, `+COMMITS`, the
  sources, a Rethink row, and the `--json` output.
- [ ] **Step 2: Run it.** Expected: it fails.
- [ ] **Step 3: Implement** `cmd_rounds`.
- [ ] **Step 4: README.** Add `gh pr-review rounds <PR>` under Usage, with one sample row.
- [ ] **Step 5: Run tests and lint.** As in Task 1, Step 4.
- [ ] **Step 6: Commit.** `git commit -m "Add gh pr-review rounds to print a PR's review history"`

### Task 5: Check phase 1 on real PRs

**Files:**
- Create: `docs/superpowers/specs/2026-11-26-review-tracking-results.md`

- [ ] **Step 1: Backfill check.** Run `gh pr-review rounds <PR> --json` on the twelve PRs in the spec's
  calibration table (use `-u catalan_adobe` for of1-labs). Compute Critical plus Important per round. Expected: the
  series in the spec's Why table and calibration table, with the Rethink round of adobe/skills#813 as `–`.
- [ ] **Step 2: Preview run.** Run `gh pr-review <an open PR> --no-post`. Expected: `round.json` with
  `"source": "model"`. Its findings match the Markdown findings in count and severity.
- [ ] **Step 3: Record results.** Write counts, sources and mismatches only. No review text: this repo is public.
- [ ] **Step 4: Commit.** `git commit -m "Record phase 1 checks on real review history"`

---

## Phase 2: Local clones and review worktrees

### Task 6: Config, state folder and lock

**Files:**
- Create: `lib/config.sh`, `lib/state.sh`, `tests/state.sh`
- Modify: `gh-pr-review` (`SESSIONS_DIR` and `SESSION_DIR` setup; lock around the run)
- Modify: `tests/flow.sh` (session paths)

**Interfaces:**
- Produces: `config_get <jq-path> <default>`. It reads
  `${XDG_CONFIG_HOME:-$HOME/.config}/gh-pr-review/config.json` when it exists, and prints the value or the default.
  An invalid file is an error that names the file.
- Produces: `state_root`: `${GH_PR_REVIEW_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/gh-pr-review}`.
  `pr_state_dir`: `<state_root>/<host>/<owner>/<repo>/<N>`.
- Produces: `SESSION_DIR`. It is `<pr_state_dir>/run-<UTC timestamp>` while the run works. After a post it is
  renamed to `round-<K>`, or kept as `run-…` with a warning if `round-<K>` already exists. A `--no-post` run is
  renamed to `preview-<timestamp>`. A failed run keeps `run-…`. The printed session path is the final one.
- Produces: `pr_lock` and `pr_unlock`. `pr_lock` makes `<pr_state_dir>/lock/` with a `pid` file. If the folder exists
  and that PID is alive, it fails: "another review of this PR is running (pid …)". If the PID is gone, it takes the
  lock over with a note. An `EXIT` trap unlocks.
- Produces: `pr_json_get <key>` and `pr_json_set <key> <value>` on `<pr_state_dir>/pr.json`.

- [ ] **Step 1: Write `tests/state.sh`:** config defaults and values, an invalid config, the state paths with and
  without `XDG_STATE_HOME` and `GH_PR_REVIEW_STATE`, the lock (taken, refused while the PID lives, taken over after
  the PID is gone), and `pr.json` get and set.
- [ ] **Step 2: Run it.** Expected: it fails.
- [ ] **Step 3: Implement**, and switch the script to the new session paths. Old `pr-review-sessions/` folders are
  left alone.
- [ ] **Step 4: Flow tests.** Point the session-path checks at `$stub/home/.local/state/gh-pr-review/`. Add: a posted
  run ends in `round-1/`, and a `--no-post` run ends in `preview-…/`.
- [ ] **Step 5: Run tests and lint.** As in Task 1, Step 4.
- [ ] **Step 6: Commit.** `git commit -m "Keep run files in one state folder per PR, with a lock"`

### Task 7: Find the clone

**Files:**
- Create: `lib/clones.sh`, `tests/clones.sh`

**Interfaces:**
- Produces: `normalize_remote <url>`, which prints `host/owner/repo`, lowercase, for `https://h/o/r(.git)`,
  `git@h:o/r(.git)` and `ssh://git@h/o/r(.git)`.
- Produces: `find_clone <host> <owner> <repo>`, which prints a path and sets `CLONE_KIND` (`config`, `scan`, `cache`
  or `override`). The order:
  1. `--clone <path>` (`CLONE_OVERRIDE`).
  2. The config `clones` map.
  3. `<state_root>/clones.json`, kept only if the path still has a matching remote.
  4. A scan of the config `roots` (default `["~/repos"]`) with `find -maxdepth 5 -type d -name .git -prune`. That
     only finds main clones, because a linked worktree's `.git` is a file. It skips `node_modules` and `*.reviews`.
     It keeps clones where some remote's `normalize_remote` matches. With several, the newest `FETCH_HEAD` wins
     (`date -r <file> +%s` works with BSD and GNU `date`; no `FETCH_HEAD` counts as 0). The pick goes to
     `clones.json`.
  5. The cache clone `~/.cache/gh-pr-review/clones/<host>/<owner>/<repo>`: made with
     `git clone --bare --quiet <url> <path>` (with `GIT_AUTH` and hooks off) if missing.
- A candidate that is shallow (`rev-parse --is-shallow-repository`) or partial (`extensions.partialClone` set) is
  skipped with a note naming the reason. If nothing else matches, the cache clone is used.
- The run prints `clone: <path> (<kind>)`.

- [ ] **Step 1: Write `tests/clones.sh`** with real git in a temp folder: a bare "remote", two matching clones with
  different `FETCH_HEAD` times, a clone whose matching remote is not called `origin`, a shallow clone, a partial
  clone, a non-matching clone, a linked worktree (must not be picked), and a config `clones` entry that wins.
  `normalize_remote` cases for all three URL forms. A cache clone made through `insteadOf`.
- [ ] **Step 2: Run it.** Expected: it fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run tests and lint.** As in Task 1, Step 4.
- [ ] **Step 5: Commit.** `git commit -m "Find the local clone for a PR, with a cache clone fallback"`

### Task 8: Fetch into private refs and the review worktree

**Files:**
- Create: `lib/worktree.sh`, `tests/worktree.sh`
- Modify: `gh-pr-review` (replace `clone + checkout` with `find_clone`, fetch and worktree; set the round ref after a
  post; add `--clone <path>` and `--fresh`)
- Modify: `tests/flow.sh` (runs use `--fresh`)

**Interfaces:**
- Consumes: `find_clone`, `pr_json_get` and `pr_json_set`, `GIT_AUTH`.
- Produces: `fetch_pr <clone> <url> <N> <base-branch>`. It fetches
  `+refs/pull/<N>/head:refs/pr-review/<N>/head` and `+refs/heads/<base>:refs/pr-review/<N>/base` with `--no-tags`,
  hooks off and `GIT_AUTH`. A failure that mentions a ref lock is retried once.
- Produces: `branch_slug <name>`: characters other than `A-Za-z0-9._-` become `-`, runs of `-` collapse, leading
  and trailing `-` go, cut at 60 characters, and an empty result becomes `pr`.
- Produces: `review_worktree <clone> <N> <head-branch> <sha>`, which prints the worktree path.
  - The path comes from `pr.json` when that worktree is still registered (`git worktree list --porcelain`).
    Otherwise it is `$(dirname clone)/$(basename clone).reviews/<slug>/<N>`.
  - New: run `git worktree prune`, then `git worktree add --detach <path> <sha>`. If the path exists and is not a
    registered worktree, fail and name the path. Never delete it.
  - Reused: if `git status --porcelain` is not empty, warn and add `"worktree was dirty"` to the run's warnings.
    Then `git checkout --detach --force <sha>` and `git clean -fd`.
  - Save the clone, worktree, head branch and user in `pr.json`.
- Produces: `mark_round <clone> <N> <K> <sha>`, which runs `update-ref refs/pr-review/<N>/round-<K> <sha>` after a
  successful post.
- Produces: `--fresh`, which clones into `$SESSION_DIR/repo` with `--depth 50`, as today. It runs `fetch_pr` on that
  clone (also `--depth 50`) and checks out the PR head detached there. There is no `.reviews` worktree. The
  "no merge-base within depth 50" error stays in this mode only.
- `BASE_SHA` comes from `merge-base HEAD refs/pr-review/<N>/base` in both modes.

- [ ] **Step 1: Write `tests/worktree.sh`** with real git and `insteadOf`. The bare remote has `refs/pull/7/head`.
  Check:
  - Round 1 makes `<clone>.reviews/feat-x/7`, detached at the PR head. The clone's branches, `HEAD`, `origin/*` refs
    and status are unchanged.
  - Round 2 after a force-push reuses the folder and moves it to the new head. `refs/pr-review/7/round-1` still
    resolves to the old commit.
  - The PR branch checked out in the clone itself still works.
  - Slugs: `feat/x`, `main`, a 200-character name, and a name with spaces and unicode.
  - An unregistered folder at the path fails and is left in place.
  - A dirty worktree is reset, with a warning.
  - A clone hook (a `post-checkout` that writes a file) never runs.
- [ ] **Step 2: Run it.** Expected: it fails.
- [ ] **Step 3: Implement**, and wire it into the script. pi runs with the worktree as its working folder.
- [ ] **Step 4: Flow tests.** Add `--fresh` to `run()` in `tests/flow.sh`, so the stub `git` stays simple. Add one
  flow case with real git through `insteadOf` and a stub `pi`: the review runs in `<clone>.reviews/…`, and a posted
  run sets `refs/pr-review/1/round-1`.
- [ ] **Step 5: Run tests and lint.** As in Task 1, Step 4.
- [ ] **Step 6: Commit.** `git commit -m "Review in a worktree of the local clone, with private refs per PR"`

### Task 9: Keep the reviewer read-only

**Files:**
- Create: `lib/git-ro` (executable), `lib/guard.sh`, `tests/guard.sh`
- Modify: `gh-pr-review` (`run_pi` runs pi in the sandbox, between two tripwire snapshots)
- Modify: `.github/workflows/ci.yml` (lint `lib/git-ro`)

**Interfaces:**
- Produces: `lib/git-ro`, run as `git` from a temp `bin/` folder first on pi's `PATH`. It reads the real git from
  `GH_PR_REVIEW_REAL_GIT`. It skips global options (`-C <dir>`, `-c <k=v>`, `--no-pager`, `-P`, `--git-dir=…`,
  `--work-tree=…`) to find the subcommand. It runs the real git for `show`, `diff`, `log`, `blame`, `grep`,
  `ls-files`, `ls-tree`, `cat-file`, `rev-parse`, `rev-list`, `merge-base`, `range-diff`, `for-each-ref`,
  `describe`, `shortlog`, `status`, `help` and `version`, and for `--version` and `--help`. Anything else exits 1
  with: `git <subcommand> is not allowed in a read-only review`.
- Produces: `pi_env`, the `env` arguments for pi: `PATH=<bin>:$PATH`, `GH_PR_REVIEW_REAL_GIT`,
  `GIT_CONFIG_COUNT=2`, `GIT_CONFIG_KEY_0=credential.helper`, `GIT_CONFIG_VALUE_0=` (empty),
  `GIT_CONFIG_KEY_1=core.hooksPath`, `GIT_CONFIG_VALUE_1=/dev/null`, `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=false`,
  `SSH_ASKPASS=false` and `GIT_SSH_COMMAND=false`.
- Produces: `tripwire_snapshot <clone> <worktree> <out-dir>`, which writes `worktree.txt` (the worktree's `HEAD` and
  `status --porcelain`) and `clone.txt` (`for-each-ref` without `refs/pr-review/`, the clone's `HEAD`, and
  `stash list`). `tripwire_check <before> <after>` returns 0 when nothing changed, 4 when `worktree.txt` changed
  (and prints the diff), and 0 when only `clone.txt` changed (it prints a warning and adds it to the run's warnings).
- `run_pi` takes a snapshot before and after each pi call. On code 4 the run stops before posting, says what changed,
  keeps the session, and exits 4.

- [ ] **Step 1: Write `tests/guard.sh`** with real git:
  - `git-ro` passes `log`, `diff`, `-C <dir> show`, `-c core.quotepath=off status` and `--version`. It refuses
    `commit`, `checkout`, `branch -D`, `push`, `stash` and `worktree add`. After the refused commands the repo is
    unchanged.
  - With `pi_env`, the real git's `credential fill` returns nothing, and a hook does not run.
  - Tripwire: no change gives 0. A commit in the worktree (made by the real git, as if the wrapper were bypassed)
    gives 4. A new branch in the clone gives 0 with a warning.
- [ ] **Step 2: Flow case.** Use the real-git flow setup from Task 8, Step 4. The stub `git` of the other flow cases
  cannot trip the tripwire. The stub `pi` runs `git checkout -b evil` through the wrapper (refused) and then
  `"$GH_PR_REVIEW_REAL_GIT" -C . commit --allow-empty -m x` (it gets through). Expected: exit 4 and nothing posted.
- [ ] **Step 3: Run them.** Expected: they fail.
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run tests and lint.** As in Task 1, Step 4, plus `shellcheck lib/git-ro && shfmt -d lib/git-ro`.
- [ ] **Step 6: Commit.** `git commit -m "Run the reviewer with a read-only git and a worktree tripwire"`

### Task 10: `gh pr-review gc`

**Files:**
- Create: `lib/gc.sh`, `tests/gc.sh`
- Modify: `README.md` (Usage: `gc`)

**Interfaces:**
- Consumes: `state_root`, `pr.json`, `use_gh_user`.
- Produces: `cmd_gc [--dry-run] [--purge]`. For each `<state_root>/*/*/*/*/pr.json`, it asks
  `gh pr view <N> --repo <host>/<owner>/<repo> --json state`, with the `user` in `pr.json` for github.com. On
  `MERGED` or `CLOSED`, it runs `git worktree remove --force <worktree>` (hooks off), deletes
  `refs/pr-review/<N>/*` with `for-each-ref` and `update-ref -d`, removes the `<slug>` and `.reviews` folders if
  empty, and runs `git worktree prune`. With `--purge` it also removes the PR's state folder. It prints one line per
  PR and a total. `--dry-run` only prints. A PR whose state cannot be read is skipped, with the reason.

- [ ] **Step 1: Write `tests/gc.sh`** with real git and a stub `gh`: one merged PR, one open PR, one PR whose state
  fails to load. Check the folders and refs that are removed and kept, `--dry-run`, and `--purge`.
- [ ] **Step 2: Run it.** Expected: it fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run tests and lint.** As in Task 1, Step 4.
- [ ] **Step 5: Commit.** `git commit -m "Add gh pr-review gc to remove review worktrees of closed PRs"`

### Task 11: Docs, doctor and a real run

**Files:**
- Modify: `README.md` (where reviews run, the state folder, the config file, `--clone`, `--fresh`, exit code 4,
  troubleshooting)
- Modify: `gh-pr-review` (`--doctor` prints the state folder, the config file if any, and the clone roots)
- Modify: `docs/superpowers/specs/2026-11-26-review-tracking-results.md`

- [ ] **Step 1: README.** Replace the Artifacts section with "Where reviews run": the clone lookup order, the
  `<clone>.reviews/<branch>/<N>` worktree, the private refs, the state folder layout, and the guards in a few lines.
  Add `--clone`, `--fresh` and exit codes 4 and 5 (reserved) to the options. Add a config example with `roots` and
  `clones`. Add a troubleshooting entry for "skipped a shallow clone". Run `se lint README.md` and fix the findings.
- [ ] **Step 2: Doctor.** Add three lines (state folder, config file, roots), and a note when the state folder is
  not writable.
- [ ] **Step 3: Real run.** `gh pr-review <an open PR whose repo I have cloned> --no-post`. Expected: the run prints
  the clone it picked. The worktree is at `<clone>.reviews/<slug>/<N>`. `git -C <clone> status` and
  `git -C <clone> branch` match their state before the run. `refs/pr-review/<N>/head` exists. The review reads the
  same as with `--fresh`. Run it again: the same worktree is reused.
- [ ] **Step 4: Record results.** Clone lookup times on `~/repos` (cold and cached), and the run time against
  `--fresh` on one large repo. No review text.
- [ ] **Step 5: Run tests and lint.** As in Task 1, Step 4.
- [ ] **Step 6: Commit.** `git commit -m "Document local review worktrees and check them on a real PR"`
