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
| `-y`, `--yes` | off | Skip the post confirmation |
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
record is saved as `round.json`. It holds only what the review already says:
never the `--instructions` text, never the prompts. Rounds posted by anyone with
this tool count, so the history is the same on every machine.

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
