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
