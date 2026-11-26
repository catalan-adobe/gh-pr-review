# Review tracking: results

Checks of each PR against real review history. Counts, labels and exit codes only: no review text, because this
repo is public and many of the reviews come from internal repos.

## PR 1: round records and the loop check

Date: 2026-11-26. Branch `review-tracking`.

### History (`gh pr-review rounds <PR> --json`)

All twelve PRs of the spec's calibration table, read back from GitHub. Every review predates the round markers, so
every record is `source: backfill`.

| PR | Blocking per round | Labels | Matches the spec |
| --- | --- | --- | --- |
| adobe/skills#813 | 9, 12, 8, 10, 8, 8, 8, 9, 9, 7, 8, 8, –, 10 | `eeCCCCCCCCCC-C` | yes |
| adobe/skills#823 | 9, 7 | `ee` | yes |
| adobe/skills#764 | 5, 3, 2 | `eec` | yes |
| adobe/skills#763 | 3, 2, 3 | `een` | yes |
| of1-labs#331 | 4, 8 | `ee` | yes |
| of1-labs#512 | 5, 2, 2, 1, 0, 1, 1, 0 | `eeccRccR` | yes |
| of1-labs#504 | 1, 1, 3, 2, 3, 3 | `eennnn` | yes |
| of1-labs#486 | 1, 0, 1, 0 | `eRcR` | yes |
| of1-labs#460 | 5, 10, 9, 2, 1, 0 | `eeCccR` | yes |
| of1-labs#466 | 3, 5, 6, 0 | `eeCR` | yes |
| of1-labs#473 | 4, 3, 10, 6, 3 | `eeCCc` | yes |
| of1-labs#505 | 3, 0 | `eR` | yes |

e = Early, c = Converging, R = Ready, n = Nit loop, C = Churning, – = Rethink (no code review).

### Loop check (`gh pr-review <PR> --check`)

| PR | Decision | Exit | Note |
| --- | --- | --- | --- |
| adobe/skills#813 | nothing-new | 5 | No commits since round 14. With any new head, the same records give `stop`, suggesting to settle the approach first (approach-stuck, too-big). |
| adobe/skills#823 | run | 0 | Early: two rounds. Flag too-big. |
| of1-labs#331 | run | 0 | Early: two rounds. Flag too-big. |
| adobe/skills#831 | nothing-new | 5 | A full run without `--force-round` stopped before the clone, as designed. |

The plan expected a stop on #813. "No new commits" wins over a stop, and nothing was pushed after round 14, so exit
5 is the right answer today.

### Preview round

`gh pr-review https://github.com/adobe/skills/pull/831 --no-post --force-round`, model `github-copilot/gpt-5.6-sol`.
Nothing was posted.

- Without `--force-round`, the run stopped at "no new commits since round 1" (exit 5), before the clone.
- With it: exit 0, round 2, `forced: true`, `preview: true`, `decision: null`, no `posted.md`.
- The model wrote the `json findings` block (1 Minor finding). It is in `review.md` and cut from `review-body.md`,
  the body that would be posted. `source: model`: no fallback to parsing.
- The finding is `F2`: IDs continue after the backfilled round 1. `previous_head_sha` is round 1's head.
- `loop`: label `ready` (round 1's), decision `nothing-new`, as forced.

### Platforms

The whole suite passes on macOS (BSD userland, jq 1.8.2) and in an Ubuntu 24.04 container (mawk, jq 1.7, no
`column`). The first Linux run caught one bug: `column` turned the `–` placeholder into byte escapes outside a UTF-8
locale. `rounds` now pads its table in jq.

## PR 2: incremental rounds

Date: 2026-11-26. Branch `review-tracking`. No round was posted.

### Preview round 3 on adobe/skills#823

`gh pr-review https://github.com/adobe/skills/pull/823 --no-post`, model `github-copilot/gpt-5.6-sol`. Rounds 1 and
2 predate the records, so round 3 builds on the backfilled round 2: 8 findings with IDs F11 to F18.

| Check | Result |
| --- | --- |
| Mode | `incremental`: the author merged `main` into the PR since round 2, so the delta starts from round 2's head merged onto the new base |
| Files the delta touched | 11, all in the PR (a plain diff from round 2's head listed 32: 21 came from `main`) |
| Earlier IDs accounted for | 8 of 8: 5 fixed, 2 open, 1 declined (with the author's reason quoted), 0 not re-checked |
| New findings | 2 (F19, F20), both in the new commits. Later list: empty |
| Open blocking | 3 (was 7): 1 Critical, 2 Important. Label `converging` (series 9, 7, 3) |
| Progress line | `5 fixed · 2 still open · 2 new (2 in the new commits) · 1 declined · open blocking: 3 (was 7) · loop: converging`, the same numbers as `round.json` |
| Owner pass | Got its round 2 verdict (Questionable) and the delta. It changed the verdict to Sound and wrote the full section |
| Findings block | Present (10 entries), cut from the body. No loop line next to the progress line |

The model set `in_delta: true` on the earlier findings too. It only matters for new findings (the progress line
counts those), so the record keeps it as given.

### Bugs this check found, fixed before the run above

- **Backfill carried every earlier finding.** With statuses, a backfilled round carried the round before it as
  "open, not re-checked", so the backfilled blocking series grew (adobe/skills#813: 9, 21, 29, …). An old review says
  nothing about what was fixed, so backfill now uses the previous record for ID numbers only. The 12 calibration PRs
  match the spec's table again.
- **A merge of the base branch counted as the author's change.** A plain `git diff <previous head>..<head>` included
  everything `main` brought in. The delta now compares with the previous head merged onto the new base
  (`git merge-tree --write-tree`), and falls back to a range-diff when that merge conflicts.

### Not checked yet

- A rebase between two rounds on a real PR: none at hand. The rebase, force-push and shallow cases are covered by
  `tests/delta.sh` with real git.
- A posted round: waits for a yes.
