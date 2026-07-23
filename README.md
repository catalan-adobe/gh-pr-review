# gh-pr-review

AI code review for any GitHub pull request, as a `gh` CLI extension.
Clones the PR, hands the full checkout to a headless
[pi](https://github.com/earendil-works/pi) agent running a GitHub Copilot
model, and prints a structured review — optionally posting it as a PR
comment.

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
| `--no-post` | posting on (with confirm) | Print the review only |
| `-y`, `--yes` | off | Skip the post confirmation |
| `--doctor` | — | Check prerequisites and exit |

Environment variables: `GH_PR_REVIEW_MODEL` (default model),
`GH_PR_REVIEW_PI_EXTENSION` (path to a pi extension to load during
review), `GITHUB_TOKEN` (private repo clones; `gh` auth usually
suffices).

Note: `gh pr review` (spaces) is GitHub's built-in approve/comment
command; `gh pr-review` (hyphen) is this extension. They coexist.

## What a review looks like

```
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

Each run writes its prompt, review, and repo checkout to
`./pr-review-sessions/pr-review-XXXXX/` in your current directory, so you
can inspect or re-post later. Add `pr-review-sessions/` to `.gitignore`
if you run it inside a repo.

## Troubleshooting

- **Empty review** — pi may have failed or timed out; retry with
  `--model github-copilot/gpt-5.5` (or any other model from `pi --list-models`).
- **`gh not authenticated`** — `gh auth login`.
- **Private repo clone fails** — export `GITHUB_TOKEN` with repo read access.
- **Update the extension** — `gh extension upgrade pr-review`.

## License

Apache-2.0
