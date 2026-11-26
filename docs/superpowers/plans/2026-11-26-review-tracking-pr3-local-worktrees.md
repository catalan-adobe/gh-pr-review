# Review Tracking PR 3, Local Clones and Review Worktrees: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reviews run in a review worktree of my local clone, at `<clone>.reviews/<head-branch>/<N>`, with all run
files in one state folder. The reviewer runs read-only. Earlier reviewed commits survive force-pushes, so
incremental rounds stay incremental. `gh pr-review gc` cleans up.

**Architecture:** Same script and libraries as PRs 1 and 2. New: `lib/config.sh`, `lib/state.sh`, `lib/clones.sh`,
`lib/worktree.sh`, `lib/guard.sh`, `lib/gc.sh`, and `lib/git-ro`, a read-only `git` wrapper for pi. The reviewer
(pi) runs with a git sandbox: no credentials, no hooks, the wrapper first on its `PATH`, and a tripwire on the review
worktree.

**Tech Stack:** Bash (`set -euo pipefail`), `gh`, `git`, `jq`, `pi`. Lint: `shellcheck`, `shfmt`. Tests: plain Bash
scripts in `tests/`, with stubs for `gh` and `pi`, and real `git` on local repos.

**Spec:** `docs/superpowers/specs/2026-11-26-review-tracking-design.md`, phases 2 and 6. Needs PR 1. Uses PR 2's
`pick_delta` when present.

**Check** (every task ends with it):
`for t in tests/*.sh; do bash "$t" || exit 1; done && shellcheck gh-pr-review lib/*.sh lib/git-ro tests/*.sh && shfmt -d gh-pr-review lib/*.sh lib/git-ro tests/*.sh`.
Expected: all `ok`, no lint output.

## Global Constraints

- All PR 1 constraints hold.
- No git command of the script changes my clone's branches, remote-tracking refs, `HEAD`, index, stash, config or
  working tree. It only writes `refs/pr-review/*` and the review worktree.
- Every git command the script runs against a clone uses `-c core.hooksPath=/dev/null`.
- `--fresh` gives today's checkout: a throwaway depth-50 clone, now inside the run folder.
- Tests never use the network. Git tests point `https://h/o/r.git` at a local bare repo with `url.<path>.insteadOf`
  set through `GIT_CONFIG_COUNT`.

## Review Focus

- The PR's head branch is `main` on a fork, contains `/`, or is 200 characters long. Test in Task 3.
- My own PR's branch is checked out in my clone or one of its worktrees. The detached review worktree still works.
  Test in Task 3.
- The author force-pushes between two rounds. `refs/pr-review/<N>/round-<K>` keeps the old commit, and the next
  round is `rebased`, not `full`. Test in Task 3.
- My clone is shallow or partial. The run skips it, says why, and uses the cache clone. Test in Task 2.
- While pi runs, I commit in my clone. That is a warning, not a stop. Test in Task 4.
- A run is killed and leaves its lock behind. The next run takes the lock over when the recorded PID is gone. Test
  in Task 1.

---

### Task 1: Config, state folder and lock

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
- Produces: `<pr_state_dir>/loop-check.md`, written with `loop_text` whenever the loop check stops a run or
  `--check` reports a stop. The run's `round-<K>` name uses `LOOP.next_round` from PR 1.

- [ ] **Step 1: Write `tests/state.sh`:** config defaults and values, an invalid config, the state paths with and
  without `XDG_STATE_HOME` and `GH_PR_REVIEW_STATE`, the lock (taken, refused while the PID lives, taken over after
  the PID is gone), and `pr.json` get and set.
- [ ] **Step 2: Run it.** Expected: it fails.
- [ ] **Step 3: Implement**, and switch the script to the new session paths. Old `pr-review-sessions/` folders are
  left alone.
- [ ] **Step 4: Flow tests.** Point the session-path checks at `$stub/home/.local/state/gh-pr-review/`. Add: a posted
  run ends in `round-1/`, and a `--no-post` run ends in `preview-…/`.
- [ ] **Step 5: Check.**
- [ ] **Step 6: Commit.** `git commit -m "Keep run files in one state folder per PR, with a lock"`

### Task 2: Find the clone

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
- [ ] **Step 4: Check.**
- [ ] **Step 5: Commit.** `git commit -m "Find the local clone for a PR, with a cache clone fallback"`

### Task 3: Fetch into private refs and the review worktree

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
  successful post. It also keeps the round's base as `refs/pr-review/<N>/round-<K>-base`.
- Changes: `pick_delta` (PR 2) looks for the previous head and base under `refs/pr-review/<N>/round-<K-1>` and
  `…-base` first. A force-push no longer makes a round full. The fetch-by-SHA fallback stays for rounds posted
  before PR 3 or from another machine.
- Produces: `--fresh`, which clones into `$SESSION_DIR/repo` with `--depth 50`, as today. It runs `fetch_pr` on that
  clone (also `--depth 50`) and checks out the PR head detached there. There is no `.reviews` worktree. The
  "no merge-base within depth 50" error stays in this mode only.
- `BASE_SHA` comes from `merge-base HEAD refs/pr-review/<N>/base` in both modes.

- [ ] **Step 1: Write `tests/worktree.sh`** with real git and `insteadOf`. The bare remote has `refs/pull/7/head`.
  Check:
  - Round 1 makes `<clone>.reviews/feat-x/7`, detached at the PR head. The clone's branches, `HEAD`, `origin/*` refs
    and status are unchanged.
  - Round 2 after a force-push reuses the folder and moves it to the new head. `refs/pr-review/7/round-1` still
    resolves to the old commit, and `pick_delta` gives `rebased`, not `full`.
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
- [ ] **Step 5: Check.**
- [ ] **Step 6: Commit.** `git commit -m "Review in a worktree of the local clone, with private refs per PR"`

### Task 4: Keep the reviewer read-only

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
- [ ] **Step 2: Flow case.** Use the real-git flow setup from Task 3, Step 4. The stub `git` of the other flow cases
  cannot trip the tripwire. The stub `pi` runs `git checkout -b evil` through the wrapper (refused) and then
  `"$GH_PR_REVIEW_REAL_GIT" -C . commit --allow-empty -m x` (it gets through). Expected: exit 4 and nothing posted.
- [ ] **Step 3: Run them.** Expected: they fail.
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Check**, plus `shellcheck lib/git-ro && shfmt -d lib/git-ro`.
- [ ] **Step 6: Commit.** `git commit -m "Run the reviewer with a read-only git and a worktree tripwire"`

### Task 5: `gh pr-review gc`

**Files:**
- Create: `lib/gc.sh`, `tests/gc.sh`
- Modify: `gh-pr-review` (dispatch: `gc` calls `cmd_gc`, no longer "not yet available")
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
- [ ] **Step 4: Check.**
- [ ] **Step 5: Commit.** `git commit -m "Add gh pr-review gc to remove review worktrees of closed PRs"`

### Task 6: Docs, doctor and a real run

**Files:**
- Modify: `README.md` (where reviews run, the state folder, the config file, `--clone`, `--fresh`, exit code 4,
  troubleshooting)
- Modify: `gh-pr-review` (`--doctor` prints the state folder, the config file if any, and the clone roots)
- Modify: `docs/superpowers/specs/2026-11-26-review-tracking-results.md`

- [ ] **Step 1: README.** Replace the Artifacts section with "Where reviews run": the clone lookup order, the
  `<clone>.reviews/<branch>/<N>` worktree, the private refs, the state folder layout, and the guards in a few lines.
  Add `--clone`, `--fresh` and exit code 4 to the options. Add a config example with `roots` and
  `clones`. Add a troubleshooting entry for "skipped a shallow clone". Run `se lint README.md` and fix the findings.
- [ ] **Step 2: Doctor.** Add three lines (state folder, config file, roots), and a note when the state folder is
  not writable.
- [ ] **Step 3: Real run.** `gh pr-review <an open PR whose repo I have cloned> --no-post`. Expected: the run prints
  the clone it picked. The worktree is at `<clone>.reviews/<slug>/<N>`. `git -C <clone> status` and
  `git -C <clone> branch` match their state before the run. `refs/pr-review/<N>/head` exists. The review reads the
  same as with `--fresh`. Run it again: the same worktree is reused.
- [ ] **Step 4: Record results.** Clone lookup times on `~/repos` (cold and cached), and the run time against
  `--fresh` on one large repo. No review text.
- [ ] **Step 5: Check.**
- [ ] **Step 6: Commit.** `git commit -m "Document local review worktrees and check them on a real PR"`
