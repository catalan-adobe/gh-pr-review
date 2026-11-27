# gh-pr-review

AI code review for any GitHub pull request, as a `gh` CLI extension.
Clones the PR, hands the full checkout to a headless
[pi](https://github.com/earendil-works/pi) agent running a GitHub Copilot
model, and prints a structured review — optionally posting it as a PR
review.

A review has two passes. First, the agent acts as the repository's
long-time maintainer and judges the approach: does this change belong
here, built this way? It is told to read the repository's own rules (`AGENTS.md`,
`CLAUDE.md`, `REVIEW.md`, ADRs) at the base commit. It forms its own view
of the change, and only then reads the PR description.

Its verdict is Sound, Questionable or Rethink. A Rethink stops the run there and posts
the approach feedback alone. Otherwise a second pass reviews the code
line by line.

> **Requires a GitHub Copilot subscription.** The review runs on Copilot
> models through pi; without a Copilot seat the default setup will not work.

## Install

```
gh extension install catalan-adobe/gh-pr-review
gh pr-review --doctor
```

`--doctor` checks every prerequisite and tells you exactly how to fix
anything missing. Once it's all ✓:

```
gh pr-review https://github.com/owner/repo/pull/42
```

## Requirements

| What | Why | Get it |
| --- | --- | --- |
| `gh` (authenticated) | PR metadata, posting comments, this extension | `gh auth login` |
| `git`, `jq` | clone + JSON plumbing | `brew install jq` |
| Node 22+ | runtime for pi | https://nodejs.org |
| `pi` | headless review agent | `npm install -g @earendil-works/pi-coding-agent` |
| GitHub Copilot subscription | model access | run `pi`, then `/login` → GitHub Copilot |

## Usage

```
gh pr-review <PR-URL | PR-number> [options]
```

Inside a repo clone, a bare number works: `gh pr-review 42`.

| Option | Default | Purpose |
| --- | --- | --- |
| `--model <id>` | `github-copilot/gpt-5.6-sol` | Any pi model ID |
| `-u`, `--user <login>` | active `gh` account | Use another logged-in `gh` account for this run only; global `gh auth` is not changed |
| `--no-post` | posting on (with confirm) | Print the review only |
| `--instructions <text>` | none | Extra guidance for both passes, for example `"Focus on db/; skip style nits"`. For a file: `--instructions "$(cat notes.md)"`. The tool does not post them, and the reviewer is told not to quote them, but the review can still reflect them: use `--no-post` to preview a review shaped by sensitive notes |
| `--skip-approach` | off | Skip the maintainer's approach pass and run the code review only, for example when the approach is already agreed |
| `--decision <d>` | from verdict | `comment`, `approve`, `request-changes`. Unset: an approach verdict of Rethink → request-changes. Otherwise the last "Ready to merge?" line decides: No → request-changes, a bare Yes → approve, anything else (Yes with fixes, Yes, with fixes, …) → comment. On your own PR it is always comment. `-y` submits the decision without asking |
| `-y`, `--yes` | off | Skip the confirmations. A loop-check stop then exits with code 3, and no new commits with code 5, instead of asking |
| `--check` | off | Run only the loop check (see below) and exit 0, 3 or 5. No clone, no model call |
| `--json` | off | With `--check`: print the decision as JSON on stdout |
| `--force-round` | off | Run a round even when the loop check stops it or nothing changed |
| `--doctor` | — | Check prerequisites and exit |

Environment variables: `GH_PR_REVIEW_MODEL` (default model),
`GH_PR_REVIEW_USER` (default `--user`),
`GH_PR_REVIEW_PI_EXTENSION` (path to a pi extension to load during
review), `GITHUB_TOKEN` (private repo clones; `gh` auth usually
suffices).

GitHub Enterprise: pass the full PR URL (e.g. `https://git.example.com/o/r/pull/1`)
after `gh auth login --hostname git.example.com`. `--user` only selects the
github.com account; Enterprise hosts use their own stored `gh` login.

Note: `gh pr review` (spaces) is GitHub's built-in approve/comment
command; `gh pr-review` (hyphen) is this extension. They coexist.

## What a review looks like

```
### Approach

**What it does:** Adds a second export format inside the JSON exporter ...
**Fit with the repo:** The README documents `Exporter` as the extension
point; this PR branches inside the JSON exporter instead ...
**Alternatives:** (1) A new `CsvExporter` ... (2) As-is: ...
**Questions for the author:** ...

**Approach:** Questionable

### Strengths
- **[src/session.ts:88]** Clean teardown path: the abort controller ...

### Issues

#### 🚨 Critical (Must Fix Before Merge)
- **[src/api.ts:141]** Webhook payload is trusted without signature
  verification ...

#### ⚠️ Important (Should Fix)
...

**Ready to merge?** No
```

## Artifacts

Each run writes its files to `./pr-review-sessions/pr-review-XXXXX/` in
your current directory, so you can inspect or re-post later:

- `owner-prompt.md` and `approach.md`: the approach pass
- `prompt.md` and `review.md`: the code review (absent after a Rethink); `review-body.md` is the reply
  without its findings block, and `findings.json` the block itself
- `round.json`: the round record (see below); `posted.md`: the exact body posted
- `context/`: the PR description, the discussion and the inline review threads both passes read
- `repo/`: the checkout

Add `pr-review-sessions/` to `.gitignore` if you run it inside a repo.

## Round history

Every review this tool posts on a PR is one round. Each round carries a hidden
record on GitHub, in an HTML comment right below the
`<!-- gh-pr-review generated -->` line: the round number, the commits reviewed,
the approach and "Ready to merge?" verdicts, and the findings (severity,
`file:line`, a short title, an ID such as `F4` that later rounds keep). The same
record is saved as `round.json`. The record on GitHub holds only what the
review already says: a title or path the posted review does not show is left
out of the marker, and the `--instructions` text and the prompts are never in
it. `round.json` in the session folder is not filtered: it keeps everything the
model returned, so inspect it before sharing it.

Not every review that looks generated is a round. Anyone who can comment on
a PR can post a review that starts with the `<!-- gh-pr-review generated -->`
line, and a round can stop the next one, so only trusted reviews count: those
whose author GitHub reports as an owner, member or collaborator of the repo
(the review's `author_association`), and your own, so your rounds count where
you are only a contributor. Everything that reads the history uses the same
rule (the loop check, `--check`, `rounds`, the re-read before posting, finding
IDs). Rounds by owners, members and collaborators are shared by everyone; a
contributor's own rounds count only for that contributor, so two contributors
(neither a member nor a collaborator) each count their own rounds and not the
other's, and their round numbers can differ. If the account running the tool
can't be read, the history can't be checked, and nothing runs. The reviews
left out are named once, for example
`ignored: 1 generated review by @x (not a member or collaborator of the repo)`.
GitHub can report a member of an organization whose membership is private as
a contributor, to a token that cannot see that membership: their rounds are
then left out. `--force-round` still runs a round the loop check would not.

`gh pr-review rounds <PR-URL | PR-number>` prints that history, one row per
round. Reviews posted before the records existed are read back from their
Markdown (`backfill`):

```
ROUND  DATE         COMMIT   +COMMITS  APPROACH      READY  CRIT  IMP  MINOR  LABEL     SOURCE
3      11-25 08:37  e55e68d  2         questionable  no     2     6    2      churning  backfill
4      11-25 09:14  09b6b7c  1         questionable  no     1     9    1      churning  backfill
next round: stop · churning · approach-stuck too-big · Settle the approach before the next round: …
```

`+COMMITS` counts the PR's commits whose commit date falls between the
previous round's review and this one's. It is a date window, not the commits
between the two reviewed heads: a commit pushed while a review runs can be
counted toward that review instead of the next one.

The label says whether the loop converges: `early` (fewer than 3 rounds),
`converging`, `ready`, `nit-loop` (a few Important findings that keep coming
back) or `churning`; `unknown` when a round's record has no blocking count and
neither its findings nor its Markdown can rebuild one (never read as 0, so
never `ready`). `--json` prints the records and the decision; `-u <login>`
picks the gh account, as for a review.

## Loop check

Before a round, the tool reads the PR's earlier rounds and decides whether
another one is worth running. It counts the blocking findings (Critical and
Important) of each round:

- **Converging:** the count drops (to 1 or less, or by 30% over two rounds).
  The round runs.
- **Nit loop** (3 or fewer, no Critical) or **Churning** (anything else) after
  the first 3 rounds: a warning. The round runs, and the posted review starts
  with a line such as
  `**Loop:** Churning · blocking 9, 12, 8 · Split the PR: each part converges on its own`.
- **Two such rounds in a row:** the round stops before any clone or model
  call. In a terminal it asks first; with `-y` (scripts and agents) it exits
  with code 3. The suggested move comes from the history: settle the approach,
  split the PR, or approve and file the rest as follow-ups.
- **No new commits** since the last round: nothing to review. In a terminal it
  asks "Run round K anyway?" (a second opinion on the same commit); with `-y` it
  exits with code 5. A round that only judged the approach (a Rethink) leaves
  the code unreviewed, so a `--skip-approach` run on that commit still runs.

A stop lifts when a person other than the PR author reviews or comments after
the last round. The author's own replies do not count, so a fix agent posting
as the author cannot lift its own stop. Comments without an identified user
(a deleted account, shown as `ghost`) do not count either. `--force-round` runs a round anyway,
without asking, and the record says so (`forced`).

Rounds are numbered in the order GitHub received them. Just before posting,
the tool reads the rounds again and compares them, by GitHub review ID, with
the rounds it started from: if someone posted one while this review ran (or a
round was deleted, or edited so it is no longer one), it says who, posts
nothing, keeps the session folder, and exits with code 6, in a terminal too:
run the review again to review on top of the rounds as they are now. If
the rounds can't be read again (one retry), it posts nothing either, keeps
the session, and exits with code 1. Two runs that post at the very same
moment both land; reading the history then gives the later one the next
round number and finding IDs.

The review is posted on the commit it read (the review API's `commit_id`), so
its round covers that commit only. If the PR moved while the review ran, the
review says so ("the PR moved to … during the review; this review covers …")
and is never an approval, even with `--decision approve`: it posts as a
comment. The new commits stay unreviewed, and `--check` runs on them.

Pinning the commit is guaranteed; detecting a push is not. The head is read
once more right before posting, but that read and the post are two separate
requests: a push that lands between them still leaves the review (an approval,
if that was the decision) on the old commit, without the note. GitHub shows
it as a review of an outdated commit. Teams that need a fresh approval after
every push should turn on "Dismiss stale pull request approvals when new
commits are pushed" in the branch protection rules (or rulesets).

If the post request fails, the review may still have landed (the answer can
be lost after GitHub took it). The tool then reads the reviews once and looks
for this run's review: one that was not there at the last read before the
post, by this account, on the reviewed commit, in the state the decision
gives (approved, changes requested, commented), with exactly the body it sent.
Exactly one such review: it reports it posted. None, several, or a failed
read: it says it could not confirm whether the review was posted, keeps the
record a preview, and exits with code 1. Another run's review on the same
commit, by the same account, does not count. Run
`gh pr-review rounds <PR>` before retrying, so the round is not posted twice.

`gh pr-review <PR> --check` runs the check alone and exits 0 (run), 3 (stop)
or 5 (no new commits); `--check --json` prints the decision as JSON for
scripts. `gh pr-review rounds <PR>` shows the same decision under the history.

| Exit code | Meaning |
| --- | --- |
| 0 | Done |
| 1 | Error |
| 3 | Stopped by the loop check |
| 5 | No new commits since the last round |
| 6 | History changed while the review ran (someone posted another round, or a round went away); nothing posted, the session is kept |

## Troubleshooting

- **Empty review** — pi may have failed or timed out; retry with
  `--model github-copilot/gpt-5.5` (or any other model from `pi --list-models`).
- **`gh not authenticated`** — `gh auth login`.
- **Private repo clone fails** — export `GITHUB_TOKEN` with repo read access.
- **Update the extension** — `gh extension upgrade pr-review`.

## Roadmap

A GitHub Action mode (`/pr-review` comment on any PR, plus opt-in
auto-review) is designed but not yet implemented — see
[docs/github-action.md](docs/github-action.md) for the investigation:
Copilot CLI in Actions, authentication routes, billing model, and the
planned deployment story.

## License

Apache-2.0
