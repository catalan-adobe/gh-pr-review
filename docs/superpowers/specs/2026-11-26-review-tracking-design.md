# Review tracking: design

Date: 2026-11-26. Status: drafted in conversation, decisions below agreed. The doc itself still needs a read.

## Why

I review more and more PRs, mine and my peers'. Many take several rounds. I can't tell which loops will end and
which need a split, a design talk, or a rewrite. The review history already on GitHub shows the problem.

| PR | Size | Rounds | Blocking findings per round (Critical + Important) | Outcome |
| --- | --- | --- | --- | --- |
| adobe/skills#813 | 4.5k lines, 66 files | 14 in 24 h | 9, 12, 8, 10, 8, 8, 8, 9, 9, 7, 8, 8, (Rethink), 10 | Restarted as #823 (9, 7). Both still open. |
| of1-labs#504 | 717 lines | 6 in 3 h | 1, 1, 3, 2, 3, 3 | Merged on "Yes with fixes" |
| of1-labs#512 | 1.2k lines | 8 in 17 h | 5, 2, 2, 1, 0, 1, 1, 0 | Merged |
| of1-labs#460 | 7.4k lines | 6 in 4 days | 5, 10, 9, 2, 1, 0 | Merged |
| of1-labs#473 | 3.2k lines | 5 | 4, 3, 10, 6, 3 | Merged. Rounds 2 and 3 ran on the same commit: 3, then 10. |

What the data says:

- **Fix loops are fast and automated.** One commit, then a new round, often 10 to 40 minutes later. Nothing stops a
  loop that does not converge.
- **Every round is a fresh full review.** On a large PR it finds new issues about as fast as the old ones get fixed.
  The prompt stops repeats of settled points. It does not stop new findings in code that did not change. The same
  commit, reviewed twice (#473), gave 3 and then 10 blocking findings.
- **A flat approach verdict alone does not predict a stuck PR.** #512 stayed Questionable for 8 rounds and merged
  cleanly. A flat approach verdict together with flat findings does (#813).
- **Small PRs loop too, at a low level.** #504 bounced between 1 and 3 Important findings. The right move there is
  to approve and file follow-ups, not another round.
- **Too much noise, no overview.** 67 open PRs that I authored on three accounts, only 17 of them updated in the
  last 30 days. 170 open review requests, 152 of them from bots, mostly Dependabot. Nothing tells me which PRs need
  me now.
- **Throwaway clones.** Each run clones with depth 50 into `./pr-review-sessions/` of whatever directory I am in. The
  history is scattered, an old reviewed commit is lost after a force-push, and the merge-base can fall outside the
  shallow window. All my active repos are already cloned under `~/repos`.

## Goal

Make every PR's review loop visible and bounded:

- Every round leaves a structured record: what was found, what was fixed, what is new.
- From round 2, the reviewer checks the previous findings and reviews what changed. Open findings can reach zero.
- One command shows every PR that involves me, whose turn it is, and whether its loop converges.
- A loop that does not converge stops, with a diagnosis: split, settle the design, or approve with follow-ups.
- An agent, the shepherd, drafts the next move for stuck PRs. I approve before anything is posted. The same code can
  run fully automatically, behind a policy.
- Reviews run in my local clones, in a review worktree next to the clone.

Success test, on real history (backfill, before any prompt change):

- #813 is Churning from round 3. The loop check stops it before round 5.
- #512, #486 and #460 end as Ready. #504 is a Nit loop, and the shepherd proposes approve with follow-ups.
- `status` on my accounts lists about 20 PRs, hides stale and bot PRs, and says how many it hid.

Out of scope:

- An agent that pushes fixes to PRs. Agents that already do this call `gh pr-review`, and the loop check bounds them.
- Merging PRs.
- The GitHub Action mode ([github-action.md](../../github-action.md)). The state lives on GitHub, so it can join later.
- A web UI or a shared server. `status` prints a table, Markdown or JSON.

## Decisions taken in conversation

- **Scope:** every open PR I authored, was asked to review, or reviewed, on every logged-in account. Bots and stale
  PRs are hidden by default.
- **Autonomy:** the shepherd starts in draft mode: I approve each action. It is designed and built so that a
  policy can make it fully automatic.
- **Worktree layout:** `<clone>.reviews/<head-branch>/<N>`, next to the clone.
- **First step:** this spec. Each PR then gets its own plan, as for the approach pass.
- **Order:** the review flow changes first. See "Order of work" below.

## Phases

| Phase | What | Visible change | Needs |
| --- | --- | --- | --- |
| 1 | Round records | Posted reviews carry a hidden record; each round saves `round.json`; `gh pr-review rounds <PR>` | — |
| 2 | Local clones and review worktrees | No fresh clone; worktree at `<clone>.reviews/<branch>/<N>`; one state folder | — |
| 3 | Incremental rounds and the loop check | Round 2+ checks old findings and reviews the delta; stuck loops stop | 1 (2 helps) |
| 4 | `gh pr-review status` | One table across accounts, with labels and whose turn it is | 1 |
| 5 | `gh pr-review shepherd` | Drafted next moves, an inbox, policy-gated auto mode | 3, 4 |
| 6 | `gh pr-review gc` | Removes worktrees and refs of closed PRs | 2 |

Phase 6 is small and can ship with phase 2.

### Order of work

The review flow changes first, then the infrastructure, then the overview:

| PR | Contents | What changes for me |
| --- | --- | --- |
| 1 | Phase 1, plus the loop check of phase 3 | Runaway loops stop. `rounds` shows a PR's history. |
| 2 | The rest of phase 3: incremental rounds | Each round checks the earlier findings and reviews what changed. Open findings can reach zero. |
| 3 | Phases 2 and 6: local clones, review worktrees, `gc` | Faster rounds in my clones. The delta survives force-pushes. |
| 4+ | Phase 4 (`status`), the dashboard, phase 5 (shepherd) | The overview, then the agent. |

The loop check needs only the blocking count per round, which phase 1 records and backfill already give, so it does
not wait for incremental rounds. Until PR 2 lands, it works on found counts, which the calibration below is based
on. Until PR 3 lands, a force-push between rounds means a full round instead of an incremental one.

The terminal dashboard, `gh pr-review dash`, has its own spec:
[review dashboard](2026-11-26-review-dashboard-design.md). It reads `status --json` (phase 4) and adds no review
logic of its own.

## Phase 1: Round records

### What a round is

A round is one posted gh-pr-review review on a PR, by anyone. A `--no-post` run is a preview: it is saved, but it
is not a round. Round number K is 1 plus the number of earlier rounds found on the PR. GitHub is the source of
truth, so the count is the same on every machine and for every reviewer.

### The record

`round.json`:

```json
{
  "schema": 1,
  "source": "model",
  "pr": { "host": "github.com", "owner": "adobe", "repo": "skills", "number": 813 },
  "round": 3,
  "mode": "incremental",
  "reviewer": "catalan-adobe",
  "model": "github-copilot/gpt-5.6-sol",
  "posted_at": "2026-11-25T08:37:12Z",
  "base_sha": "…", "head_sha": "e55e68d…", "previous_head_sha": "96ad460…",
  "approach": "questionable",
  "ready": "no",
  "decision": "comment",
  "findings": [
    { "id": "F3", "severity": "critical", "status": "open", "first_round": 1, "in_delta": false,
      "file": "skills/replica/reference/extend-pass.md", "line": 106,
      "title": "Hands-off mode can force-publish pages the owner did not request" }
  ],
  "later": [ { "id": "L1", "file": "skills/extract/scripts/crawl.mjs", "line": 1370, "title": "…" } ],
  "counts": { "open_blocking": 8, "new": 3, "fixed": 4, "declined": 0, "regressed": 1 },
  "loop": { "label": "churning", "flags": ["approach-stuck", "too-big"] }
}
```

- `source`: `model` (the findings block), `parsed` (fallback on the Markdown), or `backfill` (an old review).
- `severity`: critical, important or minor. Blocking means critical or important.
- `status`: `new`, `open`, `fixed`, `declined`, or `regressed` (marked fixed in an earlier round, back now). In round
  1, and in every round before phase 3, all findings are `new`.
- `approach`: sound, questionable, rethink, skipped, or unknown. `ready`: yes, yes-with-fixes, no, or unknown.
- `loop` is filled in from phase 3.

### How the findings get structured

The code-review prompt asks for one more block at the end of the reply: a fenced `json` block with the findings
(severity, file, line, title; from phase 3 also the ID and status of earlier findings). The script:

1. Cuts the block out before posting. The posted Markdown stays as it is today.
2. Checks it with jq, and numbers new findings itself (F1, F2, … continuing from the last round). The model never
   invents IDs.
3. Falls back to parsing the Markdown when the block is missing or invalid: count the findings under each severity
   heading and take `file:line` from the first code span. Findings come as `- **…` bullets or as `1. **…` numbered
   items (older reviews); both count. The record gets `"source": "parsed"`. A parse failure never blocks the post.

### The hidden marker

The posted body gets a second marker after the existing `<!-- gh-pr-review generated -->` line:

```
<!-- gh-pr-review:round {"schema":1,"round":3,"head":"e55e68d…","approach":"questionable",…} -->
```

- It is `round.json` without long text. Titles are cut to 100 characters.
- An HTML comment must not contain `--`, and finding titles do (`--extend`). The script writes every `--` inside
  the JSON as `-\u002d`, which is the same JSON string.
- It never contains `--instructions` text or prompts.
- GitHub caps a review body at 65,536 characters. If the body and the marker pass 60,000, the marker drops titles
  first, then the `later` list.

### Backfill

Reviews from before phase 1 have the `generated` marker and no record. A parser rebuilds a record from the Markdown:
the approach verdict, the "Ready to merge?" line, and the number of findings per severity. There are no IDs, so no
statuses: counts only, with `"source": "backfill"`. The loop rules only need the blocking count per round, so this
is enough. The tables in this spec came from a prototype of this parser.

A Rethink round has no code review. Its blocking count is unknown, not zero, and the loop rules skip it.

### Seeing the history: `gh pr-review rounds <PR>`

Phase 1 ships one small command that reads the records of one PR (markers, else backfill) and prints a row per
round: date, commit, commits since the last round, approach, "Ready to merge?", and the Critical, Important and
Minor counts. `--json` prints the records. It is the first thing I can use, and it checks the parser on real PRs
before `status` depends on it.

## Phase 2: Local clones and review worktrees

### Find the clone

For `<host>/<owner>/<repo>`, in this order:

1. The `clones` map in the config, for example `"github.com/adobe/skills": "~/repos/ai/adobe/skills"`.
2. A scan of the configured `roots` (default `~/repos`, depth 5) for a main clone, not a linked worktree, with a
   remote URL that matches (https or ssh, with or without `.git`). Some repos are cloned twice (adobe/skills is,
   for example). Then the most recently fetched clone wins (`FETCH_HEAD` time), and the run
   prints which one it picked. The result is cached in `<state>/clones.json` and checked again on use.
3. None found: a cache clone at `~/.cache/gh-pr-review/clones/<host>/<owner>/<repo>`, a bare full clone made once and
   reused after that.

A shallow or partial (blobless) clone is skipped, with a note, and the cache clone is used instead. In such a clone,
`git show` and `git diff` fetch missing history or file contents on demand, which needs the network and the
credentials that the reviewer's git sandbox removes. The script never deepens or changes my clone to fix that.

`--clone <path>` overrides this for one run. `--fresh` keeps today's throwaway clone, in the state folder.

### Fetch into a private namespace

The script never touches the clone's branches, its remote-tracking refs, or its working tree. It fetches by URL,
with the same per-command credential helper as today, into its own refs:

```bash
git -C "$CLONE" -c core.hooksPath=/dev/null "${GIT_AUTH[@]}" fetch --no-tags "$CLONE_URL" \
  "+refs/pull/${PR_NUM}/head:refs/pr-review/${PR_NUM}/head" \
  "+refs/heads/${BASE_BRANCH}:refs/pr-review/${PR_NUM}/base"
```

After it posts round K, it sets `refs/pr-review/<N>/round-<K>` to the reviewed head. These refs keep old commits
alive after a force-push, so the delta between rounds is always there. The full history also ends the "no
merge-base within depth 50" failure.

### The review worktree

Path: `<clone-dir>.reviews/<head-branch-slug>/<N>`, next to the clone. For example
`~/repos/ai/adobe/skills.reviews/feat-extend-pages/823`.

- `<clone-dir>` is the clone's folder name: `~/repos/adobe-skills` gives `adobe-skills.reviews`.
- The slug is the PR's head branch, with `/` and other unsafe characters replaced by `-`, cut at 60 characters.
  The PR number keeps fork PRs with the same branch name apart.
- The run finds an existing worktree by PR number (saved in `pr.json`), so a renamed branch does not get a second one.
- Round 1: `git worktree add --detach <path> refs/pr-review/<N>/head`. Later rounds reuse it:
  `git checkout --detach --force <sha>`.
- A detached HEAD also works for my own PRs, while their branch is checked out in another worktree.
- Every git command of the script runs with `-c core.hooksPath=/dev/null`, so the clone's hooks (husky, lefthook) do
  not run.
- One run per PR at a time: a lock folder, `<state>/<N>/lock`. Different PRs in the same clone can run in
  parallel. A fetch that hits a ref lock is retried once.

### Keep the reviewer read-only

Today the reviewer runs with auto-approved tools in a throwaway clone. Now it runs in a worktree that shares refs,
objects, stash and config with my working clone. Three guards:

1. **A git sandbox for pi.** The pi process gets an environment with no git credentials, no hooks and no prompts:
   `GIT_CONFIG_COUNT=2` with `credential.helper` set to empty (this clears every helper) and `core.hooksPath=/dev/null`,
   plus `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=false`, `SSH_ASKPASS=false` and `GIT_SSH_COMMAND=false`. A `git push`
   from the reviewer fails.
2. **A read-only `git` for pi.** A small `git` wrapper comes first on pi's `PATH`. It passes read commands through
   (`show`, `diff`, `log`, `blame`, `grep`, `ls-files`, `ls-tree`, `cat-file`, `rev-parse`, `rev-list`, `merge-base`,
   `range-diff`, `for-each-ref`, `describe`, `shortlog`, `status`) and refuses everything else with a clear message:
   commit, checkout, switch, reset, branch, tag, stash, merge, rebase, fetch, pull, push, worktree, update-ref. It
   guards against a model's mistake, not an attacker: `/usr/bin/git` with a full path gets past it.
3. **A tripwire on the review worktree.** Before and after each pi pass, the script records the worktree's `HEAD` and
   `git status --porcelain`. Nobody else works there, so any change is the reviewer's. The run stops before posting,
   prints what changed and saves it. With `-y` it exits with code 4. The clone's own branches and stash are compared
   too, but a change there is only a warning: I may be working in the clone while a review runs.

A dirty review worktree at the start of a run is reset (`git checkout --force`, `git clean -fd`), with a warning in
the record.

The reviewer keeps `gh` with my token, to read PRs and issues. That is true today and does not change. The
read-only rule in both prompts still applies.

### The state folder

All run files move from `./pr-review-sessions/` to one place:

```
${GH_PR_REVIEW_STATE:-${XDG_STATE_HOME:-~/.local/state}/gh-pr-review}/<host>/<owner>/<repo>/<N>/
  pr.json                  clone path, worktree path, head branch, last seen updatedAt
  round-3/                 owner-prompt.md, approach.md, prompt.md, review.md, context/, round.json, posted.md
  preview-20261126T091200/ the same files, for a --no-post run
  loop-check.md            the last loop diagnosis (phase 3)
  shepherd/                proposals (phase 5)
```

The run prints the folder, as it does today. Old `pr-review-sessions/` folders are left alone.

## Phase 3: Incremental rounds and the loop check

### What round 2 and later get

The run reads the previous round's record: the local file, or else the marker on GitHub, so rounds that another
person or machine posted count too.

The owner pass gets its previous Approach section and the delta's `--stat`. It keeps the verdict unless the delta or
the new discussion changes it. If nothing changed, it says so in one line and repeats the verdict.

The code review gets:

- The previous open findings, each with its ID, severity, `file:line`, title and text.
- The delta. When the previous head is an ancestor of the new head: `git diff <previous head>..<head>`. After a
  rebase or force-push: `git range-diff <previous base>..<previous head> <base>..<head>`. When the range-diff is
  unusable, the round falls back to a full review (`mode: full`).
- These rules:
  1. Check each previous finding against the current code. Report it as `fixed`, `open` or `declined`. Declined only
     when the discussion gives a reason the reviewer accepts, quoted. A fix attempt that did not work stays `open`,
     with what is still wrong.
  2. Review the delta in full, at every severity. A problem the fix commits introduced is `new` with
     `in_delta: true`. A finding fixed in an earlier round that came back is `regressed`.
  3. In code the delta did not touch, raise a new finding only if it is Critical, and say why earlier rounds missed
     it. Important and Minor issues there go to a `Later` list. It does not block, it is posted folded, and its
     items can become follow-up issues.

"Ready to merge?" is Yes when no blocking finding is open. If the line says Yes while the record has open blocking
findings, the record wins and the decision is comment.

`--full` forces a full review (`mode: full`). It still checks the previous findings, so IDs and counts stay
comparable, but rule 3 does not apply. Use it after a rewrite.

Same head as the last round: the run says "no new commits since round K" and exits with code 5, unless
`--force-round` is passed. #512 and #473 each spent a round on an unchanged commit.

### The posted body, round 2 and later

It starts with one progress line:

```
### Round 3 · since round 2
4 fixed · 2 still open · 3 new (1 in the fix commits) · open blocking: 5 (was 6) · loop: converging
```

Then the approach section (or "Approach unchanged: Questionable"), the open and new findings, a folded
"Fixed this round" section, and a folded "Later" section. A peer who reads the PR sees the trend too.

### Loop rules

B(K) is the blocking count of round K: the open count with phase 3 records, the found count with older records.
Rounds without a code review (Rethink) are skipped: K counts only rounds with a code review, so B(K−2) is the count
two code reviews back. N is the number of rounds with a code review so far.

| Label | Rule, checked in this order |
| --- | --- |
| Ready | B(K) = 0 and "Ready to merge?" is Yes or Yes with fixes |
| Early | N < 3. No trend yet |
| Converging | B(K) ≤ 1, or B(K) ≤ 0.7 × B(K−2) |
| Nit loop | Not converging, B(K) ≤ 3, no open Critical |
| Churning | Not converging, otherwise |

Flags, shown next to any label:

- `approach-stuck`: the approach verdict was Questionable or Rethink in each of the last 3 rounds. It matters only
  next to Nit loop or Churning: #512 shows a Questionable approach can still converge.
- `too-big`: more than 800 changed lines or more than 25 files.
- `threads-stale`: unresolved review threads on code that has since changed (of1-labs#331: 10 of 14, none resolved).

All thresholds live in the config.

### The loop check

The run computes the label of the rounds so far before it starts round K:

- **Warn** after the first Nit loop or Churning round. The run continues. The posted review starts with one loop
  line, for example `**Loop:** Churning · blocking 9, 12, 8 · settle the approach before the next round`. From
  PR 2, the progress line carries the label instead.
- **Stop** after two such rounds in a row:
  - Interactive: print the diagnosis (the series, label, flags and suggested move) and ask "Run round K anyway?
    [y/N]".
  - With `-y` (agents and scripts): run nothing, post nothing, write the diagnosis to stderr and to
    `loop-check.md`, and exit with code 3. The shepherd picks it up.
  - `--force-round` runs anyway, and the record says so.
  - The stop lifts when something changes: a review or comment after the last round by a person other than the
    PR author (not a bot, not a gh-pr-review round), a `--full` round, or a label that is no longer Nit loop or
    Churning. The author's replies do not count: on my own PRs, fix agents post as me, the author, and must not
    lift their own stop.
  - Until the state folder exists (PR 3), the diagnosis goes to stderr and to `--check --json` only.
- **Check only:** `gh pr-review <PR> --check [--json]` computes the label and the decision (run, warn, stop, or
  nothing new) and exits with 0, 3 or 5, without running a round. The dashboard uses it before `r`.

The suggested move comes from the label and the flags:

| Label and flags | Suggested move |
| --- | --- |
| Churning with `approach-stuck` | Settle the approach before the next round: answer the approach questions, or rethink |
| Churning with `too-big` | Split the PR: each part converges on its own |
| Churning | Look at what keeps coming back, and decide it with the author before the next round |
| Nit loop | Approve, and file the remaining findings as follow-ups |

Calibration on the real history, before any prompt change (c = Converging or Early, R = Ready, n = Nit loop,
C = Churning, - = Rethink):

| PR | Outcome | Labels by round | Warn | Stop before |
| --- | --- | --- | --- | --- |
| adobe/skills#813 | open | `ccCCCCCCCCCC-C` | 3 | round 5 (it ran 14) |
| adobe/skills#823 | open | `cc` | — | — |
| adobe/skills#764 | merged | `ccc` | — | — |
| adobe/skills#763 | merged | `ccn` | 3 | — |
| of1-labs#331 | open | `cc` | — | — |
| of1-labs#512 | merged | `ccccRccR` | — | — |
| of1-labs#504 | merged | `ccnnnn` | 3 | round 5 (it ran 6) |
| of1-labs#486 | merged | `cRcR` | — | — |
| of1-labs#460 | merged | `ccCccR` | 3 | — |
| of1-labs#466 | merged | `ccCR` | 3 | — |
| of1-labs#473 | merged | `ccCCc` | 3 | round 5 (it ran 5, merged with 3 blocking open) |
| of1-labs#505 | merged | `cR` | — | — |

Stopping at the first bad round would have cut short #460 and #466, which recovered. Two in a row does not.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Done (posted, or printed with `--no-post`) |
| 1 | Error |
| 3 | The loop check stopped the run |
| 4 | The tripwire found a change in the review worktree; nothing posted |
| 5 | No new commits since the last round |

## Phase 4: `gh pr-review status`

```
gh pr-review status [--json | --md] [--all] [--stale-days <n>] [--mine | --reviewing] [--refresh]
```

A first argument of `rounds`, `status`, `shepherd` or `gc` is a subcommand. Anything else is a PR, as today.

### Which PRs

For each account in the config (default: every login that `gh auth status` lists, here `catalan-adobe` and
`catalan_adobe` on github.com and `catalan` on the company's GitHub Enterprise host): open PRs I authored, PRs
where my review is requested, and PRs I reviewed, without duplicates. Each account is queried with its own token
(`gh auth token --user`), as `--user` does today. `gh search prs` works on the enterprise host with `GH_HOST` set
(checked: 6 authored PRs and 4 review requests on the enterprise host).

Hidden by default, and counted on the last line:

- Bots: the author is a bot or ends in `[bot]`.
- Stale: no update for `--stale-days` (default 30).
- The `ignore` list in the config (repos, owners with `*`, or single PRs).

`--all` shows them.

### Data per PR

One GraphQL query per host for about 20 PRs at a time: state, draft, size, files, head branch, author,
`reviewDecision`, the last commit's date and checks, reviews (author, state, date, and the body only to read
markers), review threads (resolved, outdated), and force-push events. Records come from the local `round.json`,
else the marker, else backfill. Results are cached in `<state>/status-cache.json` by PR and `updatedAt`, so a
second run is fast. The target is under 10 seconds for 20 PRs with a warm cache.

### Whose turn

- **me**: my review is requested and I have not reviewed since the last push. Or I am the author, and someone else
  reviewed, commented or opened a thread after my last push. Or I am the author and the checks fail.
  A gh-pr-review round counts as a review here, even when I posted it on my own PR.
- **author**: I reviewed after the last push and asked for changes or left open findings.
- **merge**: the label is Ready and the PR is approved.
- **others**: anything else, for example waiting on another reviewer.

### Labels

PRs with gh-pr-review rounds get the loop label from phase 3. PRs without them get New (no review yet) or In review
(human reviews only). Two more labels apply to any PR:

- **Superseded**: a newer open PR by the same author, in the same repo, with the same title, or with a description
  that says it replaces, supersedes or restarts #N. #813 becomes Superseded by #823, and #823 shows "restart of
  #813 (14 rounds, Churning)". The rounds are not merged: #823 keeps its own count.
- **Stale**: shown only with `--all`.

### Output

A table, my turn first, then Churning, Nit loop, Converging, Early, Ready, and the rest. For example:

```
TURN    PR                LABEL      ROUNDS  BLOCKING        APPROACH      SIZE         AGE  TITLE
me      of1-labs#331      Early      2       4 8             —             3.2k 53f     23d  (internal) feature PR…
me      adobe/skills#813  Churning   14      …8 8 – 10       questionable  4.5k 66f      2d  feat(stardust): replica --extend…
        ↳ approach-stuck · too-big · superseded by #823
me      adobe/skills#823  Early      2       9 7             questionable  3.2k 62f      1d  feat(stardust): replica --extend…
        ↳ too-big · restart of #813 (14 rounds, Churning)

218 hidden: 152 bots · 66 stale  (--all shows them) · 3 review worktrees can be removed (gh pr-review gc)
```

`--json` prints the full model: one object per PR with its records, label, flags and turn. Agents read this.
`--md` prints the table as Markdown, for a daily note or a chat message.

More outputs serve the terminal dashboard ([review dashboard](2026-11-26-review-dashboard-design.md)), which is a
thin client over this command:

- `--json` carries `"schema": 1` and follows the shape in the dashboard spec. `--cached` prints the last result
  without touching the network.
- `--short` prints one line from the cache only, such as `⚑4 ✓1 ↻2` (my turn, ready, jobs running), in under
  50 ms. It fits a shell prompt or a multiplexer status bar.
- `gh pr-review show <PR> --json` prints one PR in full: every round record with its findings, each round's review
  body, the review threads, and the description.

## Phase 5: The shepherd

```
gh pr-review shepherd [--pr <PR>] [--mode draft|auto] [--dry-run]
gh pr-review shepherd inbox
gh pr-review shepherd approve <id> | edit <id> | reject <id> [--reason <text>]
```

### The model proposes, code acts

The shepherd agent never posts and never runs a `gh` command that writes. It writes a proposal: one action from a
fixed catalog, the text to post, and a short reason for me. A plain executor in the script applies a proposal once
it is approved. A policy decides which proposals need my approval. Draft mode and auto mode run the same code; only
the policy differs. That is how it can become fully automatic later without a rewrite.

### Which PRs it looks at

On each run it builds the `status` model and picks PRs that are Churning, Nit loop, Superseded, Ready and waiting on
a merge, or Stale with a review request on me, and PRs where a loop check stopped a run. It skips a PR unless
something changed since its last proposal there: a new round, a push, a human review, or a new label. At most
`max_prs_per_run` (default 5), my turn first.

### What it reads

One pi call per PR. It runs read-only in the PR's review worktree, with the same three guards. It reads
the `status` entry, every round record, the latest review, `pr-discussion.md`, the loop diagnosis, and the action
catalog. It replies with one proposal as JSON.

### Action catalog

| Action | What it does | Risk |
| --- | --- | --- |
| `comment.loop-check` | Comment with the round trend, what is settled, and the one question to answer before another round | low |
| `comment.split-plan` | Comment with a proposed split: the PRs, the files or commits in each, their order, what each proves | low |
| `comment.nudge` | Remind, or re-request a review from, whoever's turn it is | low |
| `review.round` | Run another gh pr-review round, for example after the author pushed | medium |
| `issue.follow-ups` | Open one checklist issue with the Later and leftover findings, and link it on the PR | medium |
| `review.approve-with-follow-ups` | Approve, with a link to the follow-up issue. Never on my own PR | high |
| `pr.close-superseded` | Close the older PR, with a link to the newer one. Only PRs I authored | high |
| `none` | Nothing to do, with the reason | — |

### Policy

In the config:

```json
"shepherd": {
  "mode": "draft",
  "auto": { "comment.nudge": "own", "comment.loop-check": "own", "review.round": "all" },
  "max_prs_per_run": 5,
  "min_days_between_comments": 3
}
```

`"own"` allows the action without approval on PRs I authored; `"all"` on every PR; a missing action means draft.
`--mode draft`, the default, drafts everything. `--mode auto` applies the policy.
The example shows the format. The default `auto` is empty, so even `--mode auto` drafts everything until I add
actions to it.

Hard limits that no policy changes:

- Never merge, push, dismiss a review, approve my own PR, or close someone else's PR.
- Every posted text carries `<!-- gh-pr-review shepherd -->` and a footer.
- No new shepherd comment on a PR within `min_days_between_comments` of the last one.
- `GH_PR_REVIEW_SHEPHERD=off` turns it off.

### The inbox

Each proposal is `<state>/<N>/shepherd/<time>-<action>.json`, plus `.md` with what would be posted. `shepherd inbox`
lists pending proposals across PRs with their reason. `approve` runs the executor. `edit` opens `$EDITOR` on the
`.md` first. `reject` keeps the proposal with the reason, and the shepherd does not propose the same action on that
PR until something changes. Every applied action goes to `<state>/shepherd-log.jsonl`.

### Running it every day

Not built in. The README shows a launchd job (macOS) that runs `gh pr-review shepherd` on weekday mornings and shows
a notification such as "3 PRs need you · 2 proposals waiting". Any agent (Studio, Claude Code, pi) can also run
`status --json` and `shepherd`.

## Phase 6: `gh pr-review gc`

```
gh pr-review gc [--dry-run] [--purge]
```

For each PR in the state folder that is merged or closed: remove its review worktree (`git worktree remove --force`),
delete `refs/pr-review/<N>/*`, remove empty `<branch>` and `.reviews` folders, and run `git worktree prune`. Records
stay, since they are small and feed the stats, unless `--purge` is passed.

## Config

One optional file, `${XDG_CONFIG_HOME:-~/.config}/gh-pr-review/config.json`. Everything has a default. The current
environment variables keep working and win over the file.

```json
{
  "accounts": [
    { "host": "github.com", "user": "catalan-adobe" },
    { "host": "github.com", "user": "catalan_adobe" },
    { "host": "git.example.com" }
  ],
  "roots": ["~/repos"],
  "clones": { "github.com/adobe/skills": "~/repos/ai/adobe/skills" },
  "stale_days": 30,
  "ignore": ["aemdemos/*"],
  "loop": { "min_rounds": 3, "converge_ratio": 0.7, "nit_max_blocking": 3, "too_big_lines": 800, "too_big_files": 25 },
  "shepherd": { "mode": "draft" }
}
```

The approach-pass and instructions specs ruled out a config file. This feature needs one, for accounts, roots and the
policy. It stays optional.

When `status` or the shepherd starts a review round, it passes the `--user` of the account that found the PR.

## Architecture

- Bash stays. The entry script dispatches the subcommands. No subcommand means a review, so `gh pr-review 42` and
  PR URLs still work.
- New code goes in `lib/*.sh` (records, checkout, loop, status, shepherd), sourced by the entry script. A gh extension
  installs the whole repo, so the files ship with it. Tests source the files instead of cutting blocks out with `sed`.
- jq does the JSON work. The loop rules live in one file, `lib/loop.jq`, used by the loop check, `status`, and the
  tests.
- CI runs shellcheck and shfmt on `lib/*.sh` too.

## Verification

Stub tests in `tests/`, as today:

- Marker: round trip with `--` in titles, the size cap, and no instructions text in it.
- Findings block: cut from the posted body, invalid JSON falls back to parsing, IDs continue across rounds.
- Backfill parser: real review bodies as fixtures. One with `- **` bullets (#813), one with numbered findings
  (#460, round 1), one Rethink-only review, one from before the approach pass.
- Loop rules: the series in the calibration table give the labels, warn rounds and stop rounds in it.
- Checkout: the clone lookup (config, scan, two clones, cache fallback), the worktree path and slug, reuse across
  rounds, a detached HEAD, and hooks off.
- Guards: the git wrapper passes read commands and refuses writes; the tripwire stops a post when the worktree
  changes, and only warns when a branch of the clone changes.
- Loop check: the prompt, exit code 3 with `-y`, `--force-round`, and exit code 5 on an unchanged head.
- `status`: filters, whose-turn rules and superseded detection, on stub GraphQL output.
- Shepherd: draft and auto, own and all, the hard limits, the executor for each action with a stub `gh`, and the
  inbox lifecycle.

Real runs, with `--no-post`:

- `status` with backfill on my accounts. Compare the labels with the calibration table and with my own judgement.
- Phase 3 on a live PR that already has rounds, such as adobe/skills#823. The statuses in `round.json` make sense,
  and open blocking findings go down as fixes land.
- Shepherd drafts for #813 and #823 (expect a split plan or a loop check) and for a nit loop like #504 (expect
  approve with follow-ups).

## Risks

- **The Later rule can hide a real Important issue that is found late.** It is still posted and listed as a
  follow-up, and `--full` lifts the rule. Watch how many Later items turn out to be real bugs.
- **Counts are a rough signal.** A Critical counts the same as an Important. The rules only label; I or the shepherd
  decide. The thresholds are in the config.
- **Backfilled rounds count found findings; phase 3 rounds count open ones.** Labels can jump at the switch. The
  record's `source` says which.
- **The shared clone.** The git sandbox, the read-only git wrapper, the detached worktree, the private ref
  namespace, hooks off and the tripwire cover it. None of them stops a deliberate attacker; they stop mistakes. The
  reviewer still has `gh` with my token, as today.
- **A hidden marker in public reviews.** It holds only what the review already says. Never instructions or prompts.
- **Automation noise.** Draft by default, a comment interval, the marker, and the off switch.
- **Disk.** Review worktrees of big repos add up. `gc`, and `status` shows how many can go.

## Open questions

1. Should the owner pass run in every round, or only when the delta adds files or touches shared modules? Proposal:
   every round, one line when nothing changed. It costs 1 to 4 minutes a round.
2. Does `review-requested:@me` include team requests? If so, use `user-review-requested:@me` and add a `teams`
   switch.
3. Follow-up issues: one checklist issue per PR (proposed), or one issue per finding?
4. If jq gets heavy for `status` and the shepherd, move them into Rust next to the dashboard (`dash/`), or keep
   the engine in Bash and jq? Proposal: keep Bash and jq until a real limit shows up.
