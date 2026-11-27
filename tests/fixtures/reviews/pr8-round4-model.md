### Strengths

- `gh-pr-review:1103–1106` binds the POST to the commit the model actually reviewed. `tests/flow.sh:559–568` checks the consequence that matters: when a push lands during review, the old commit gets a comment and the new commit remains eligible.
- `lib/records.jq:234–245` measures the assembled body after each compaction step. The boundary tests in `tests/records.sh` check the exact 60,000-character transition rather than estimating how much space a marker needs.
- `lib/loop.jq:68` gives the review command, `rounds`, and `--check` one decision function. I ran all eight test scripts on this checkout; **all 473 checks passed**. The cases below are outside those assertions.

### Issues

#### 🚨 Critical (Must Fix Before Merge)

*(none found)*

#### ⚠️ Important (Should Fix)

- **`gh-pr-review:974–977` — A different review can confirm a failed POST.** The new recovery check matches the account, commit, generated header, and a time window—not the review body or action. If two jobs share an account and review the same SHA, one job’s comment can make the other report that its request for changes landed. I also verified the false success with a slow-client-clock fixture: the POST failed, but the script exited 0 and saved `preview: false` for a request for changes that was not on the PR.
  - **Fix:** Match the attempted `post.json` body, commit, and corresponding GitHub review state, excluding review IDs already present before the POST. If the match is ambiguous, keep the preview and report an unconfirmed outcome.

- **`gh-pr-review:1030–1031` — The overlap check compares counts, not which rounds were read.** I started a run with review ID 10, then had the stub return ID 10 with its generated header edited out and a newly submitted generated review, ID 11. Both snapshots contained one round. The run posted `APPROVE` based on ID 10 instead of exiting 6 for ID 11. This is distinct from two POSTs racing *after* the recheck: the new round was already visible to it.
  - **Fix:** Retain GitHub review IDs in the history snapshot and compare the ordered IDs before posting. Report newly arrived IDs even when the total count is unchanged.

- **`lib/records.jq:260` — A partial marker can turn a visible Critical into a `ready` round.** The validator accepts an ordinary code-review marker without `counts`; only an explicitly compacted marker takes the count-rebuilding path. I passed the history reader a marker with `F1` marked Critical, a matching Critical Markdown bullet, and `ready: "yes-with-fixes"`, but no `counts`. `lib/loop.jq:14` converted the missing count to zero, and the decision reported `series: [0]` and `label: "ready"`.
  - **Fix:** Distinguish full code-review, Rethink, and minimal markers during validation. When a code-review marker lacks a usable blocking count, reconstruct it from the findings or Markdown rather than treating unknown as zero.

- **`lib/records.jq:88–90` — The findings check accepts blockers that the review explicitly says do not exist.** The previous fix catches omitted blockers and repeated locations. The reverse mismatch remains: with `*(none found)*` under all three severity headings and four Critical entries in the block, the flow posted an approval and recorded four open Criticals. Four such records produce `churning`, `churning`, then a stop, despite no posted review reporting a blocker.
  - **Fix:** At minimum, treat an explicit empty severity section as authoritative and fall back to Markdown if the block adds findings there. This need not require exact counts for Markdown the parser cannot recognize.

#### 💡 Minor (Nice to Have)

- **`gh-pr-review:885–886` — Multiple JSON values bypass the invalid-block fallback.** `jq -e` validates a stream and returns the result for its last value. I supplied `[]` followed by a valid findings array in the same fence: validation passed, `--argjson` later rejected the two values, and the run posted without a marker or `round.json`. Slurp the block, require exactly one array, and otherwise use the already-parsed Markdown.

- **`lib/rounds.sh:173` — `+COMMITS` can attribute a push to the round that did not review it.** If B is pushed while the model reviews A, B’s committer date can fall before round A’s submission. The table then counts B in round A and shows `0` for the round that actually reviews B. The date-window calculation follows the written plan; the misleading part is presenting it as commits between reviewed heads. Count between the pinned SHAs, or label the column as a date-window estimate.

- **`README.md:129–131` — The privacy guarantee reads as if it covers local `round.json`.** The marker filters unpublished titles and paths, but `tests/flow.sh:253` intentionally verifies that the local record retains a private instruction echoed only in a model title. Clarify that the visibility filter applies to the GitHub marker and that users should inspect `round.json` before sharing it.

### Recommendations

Use GitHub review IDs for both pre-POST history comparison and failed-POST recovery. Extend the existing producer-to-consumer test with two negative cases: a different review by the same account on the same SHA, and a changed history whose count stays constant. Assert the remote action **and** whether the local record was finalized.

### Assessment

**Ready to merge?** No

**Reasoning:** Commit pinning and the calibrated loop rules are well tested. The remaining issues affect what unattended callers can trust: the command can report a review as posted when it was not, post over a round it already saw, or make a loop decision from counts that contradict the visible review.

```json findings
[
  {"severity":"important","file":"gh-pr-review","line":976,"title":"A different review can confirm a failed POST"},
  {"severity":"important","file":"gh-pr-review","line":1031,"title":"The overlap check misses replacement rounds when the count stays constant"},
  {"severity":"important","file":"lib/records.jq","line":260,"title":"Missing marker counts can turn a visible Critical into a ready round"},
  {"severity":"important","file":"lib/records.jq","line":88,"title":"The record accepts blockers from explicitly empty Markdown sections"},
  {"severity":"minor","file":"gh-pr-review","line":885,"title":"Multiple JSON values bypass the Markdown fallback"},
  {"severity":"minor","file":"lib/rounds.sh","line":173,"title":"Commit dates can attribute a push to the wrong review round"},
  {"severity":"minor","file":"README.md","line":129,"title":"The marker privacy guarantee does not apply to local round.json"}
]
```
