<!-- gh-pr-review generated -->
<!-- gh-pr-review:round {"schema":1,"source":"model","pr":{"host":"github.com","owner":"catalan-adobe","repo":"gh-pr-review","number":8},"round":5,"mode":"incremental","mode_reason":"previous head is an ancestor of the head","reviewer":"catalan-adobe","model":"azure-openai-direct/gpt-6.2-astra","posted_at":"2026-11-27T11:57:46Z","base_sha":"4817c8dec1f7bb41f17abfb261f2722f3d5498fa","head_sha":"0f749ef9f2dc1f87c3b0e79cbbb0e9fef52a0a77","previous_head_sha":"505c56d0714b9a4771954e6cb7b0a4d7d30bc16b","approach":"sound","ready":"no","ready_overridden":false,"decision":"comment","preview":false,"code_review":true,"findings":[{"id":"F21","severity":"important","status":"fixed","first_round":4,"in_delta":true,"file":"gh-pr-review","line":993},{"id":"F22","severity":"important","status":"fixed","first_round":4,"in_delta":true,"file":"gh-pr-review","line":1052},{"id":"F23","severity":"important","status":"open","first_round":4,"in_delta":true,"file":"lib/records.jq","line":269},{"id":"F24","severity":"important","status":"open","first_round":4,"in_delta":true,"file":"lib/records.jq","line":90},{"id":"F25","severity":"minor","status":"fixed","first_round":4,"in_delta":true,"file":"gh-pr-review","line":897},{"id":"F26","severity":"minor","status":"fixed","first_round":4,"in_delta":true,"file":"lib/rounds.sh","line":146},{"id":"F27","severity":"minor","status":"fixed","first_round":4,"in_delta":true,"file":"README.md","line":133},{"id":"F28","severity":"important","status":"new","first_round":5,"in_delta":true,"file":"gh-pr-review","line":373},{"id":"F29","severity":"minor","status":"new","first_round":5,"in_delta":true,"file":"lib/records.jq","line":275},{"id":"F30","severity":"minor","status":"new","first_round":5,"in_delta":true,"file":"README.md","line":143}],"later":[],"last_ids":{"F":30,"L":0},"counts":{"open_blocking":3,"critical":0,"important":3,"minor":2,"new":3,"fixed":5,"declined":0,"regressed":0,"later":0,"unverified":0},"loop":{"label":"nit-loop","flags":["too-big"],"decision":"run"},"forced":false} -->
### Round 5 · since round 4
5 fixed · 2 still open · 3 new (3 in the new commits) · open blocking: 3 (was 4) · loop: nit loop
**Next:** Approve, and file the remaining findings as follow-ups

### Approach

**What it does:** Records posted reviews as rounds and checks that history before cloning the PR or calling the model again.

**Fit with the repo:** Round 4’s concern is resolved. The author clarified that “that delegation was not intended.” `lib/rounds.sh` now counts only the operator’s own reviews and those GitHub attributes to an owner, member, or collaborator. `rounds`, `--check`, and the pre-post check all use that same history. An outsider’s generated header alone can no longer stop a maintainer’s run.

**Strongest case for the approach as built:** Trusted reviewers can share prior work through the existing GitHub review marker, without a new store or credential. The 14 rounds recorded for `adobe/skills#813` show why checking before another paid call is worthwhile.

**Alternatives:** Keep the shared gate. Counting only the operator’s reviews would repeat work across maintainers. I’d revisit the trust rule if hidden organization membership routinely excluded legitimate rounds; `README.md` documents that limit.

**Questions for the author:** None.  
**Missing context:** None that changes the verdict.

**Approach:** Sound

### Strengths

- `gh-pr-review:1051–1052` compares ordered GitHub review IDs before posting. The regression test at `tests/flow.sh:509` checks the important case: one round disappears and another arrives, so the count stays the same but the post must stop.
- `gh-pr-review:989–996` checks the attempted body, commit, account and review state before confirming a failed POST. `tests/flow.sh:746–752` verifies that a different body, a different state, and two matching reviews all leave the outcome unconfirmed.
- I ran all eight test scripts against an archive of the reviewed commit. **All 519 checks passed.** The cases below are outside those assertions.

### Issues

#### 🚨 Critical (Must Fix Before Merge)

*(none found)*

#### ⚠️ Important (Should Fix)

- **F23 · `lib/records.jq:269–275`** — Rebuilding a missing total can still erase a known Critical. The original bold-bullet case is fixed. With `counts: {"critical":1,"important":0}` but no `open_blocking`, and a plain `-` bullet under Critical, I got `critical: 0` and the label `ready`. The total was available without parsing Markdown. There is also a separate path at `lib/rounds.sh:43–50`: with no severity headings, the same review text gave `unknown` with an ordinary count-less marker but `ready` with a minimal marker.
  - Use the sum when both severity counts are usable. When neither the record nor the Markdown establishes a count, preserve `null` on the minimal-marker path too.

- **F24 · `lib/records.jq:90`** — The empty-section check and the record builder disagree about which entries count. The check exempts `fixed`, `declined` and `later` entries, but `lib/records.jq:191–192` converts all accepted entries to `new`. With “none found” under every heading and four Critical entries marked `fixed` in the block, the flow stub submitted `APPROVE` and saved `source: model` with four open blockers.
  - Validate the entries as this version will store them, or reject unsupported status and Later fields and fall back to Markdown. This does not require implementing cross-round statuses in this PR.

- **`gh-pr-review:373–376`** — A failed account lookup silently removes the operator’s own contributor rounds from the gate. With one such review on the current head, I got exit 5 normally. Making only `gh api user` fail changed `--check` to exit 0, named the operator’s review as ignored, and proposed round 1. The final re-read uses the same unresolved `ROUNDS_ME`, so it cannot catch the mistake before posting. `lib/rounds.sh:172` has the same fallback.
  - Resolve and validate the account before deciding which rounds count. Retry a failed lookup, then report that the history cannot be verified rather than starting a paid round from incomplete history.

#### 💡 Minor (Nice to Have)

- **`lib/records.jq:275`** — When Markdown supplies replacement counts, the record keeps the findings list that failed validation. In the case at `tests/rounds.sh:140`, `rounds --json` reports one Critical alongside `findings: []`, without `findings_dropped`. Rebuild the list from the parsed findings or mark it unavailable, so consumers can distinguish “no findings” from “no reliable list.”
- **`README.md:143`** — “The history is the same for everyone with the same access” is not true of two contributors with identical access: each counts their own rounds and ignores the other’s. Clarify that owner, member and collaborator rounds are shared, while the own-account exception can give contributors different round numbers.

<details><summary>Fixed since the last round (5)</summary>

- **F21** — Failed-POST recovery now requires exactly one matching review and excludes IDs from the final round snapshot.
- **F22** — The overlap check compares ordered review IDs rather than counts.
- **F25** — The findings fence must contain exactly one JSON array; multiple values fall back to Markdown.
- **F26** — The README and `rounds --help` explain that `+COMMITS` is a date window, not a comparison of reviewed SHAs.
- **F27** — The README distinguishes the filtered GitHub marker from the local `round.json` and warns users to inspect it before sharing.

</details>

### Recommendations

Extend the existing round-trip tests to assert both the persisted findings and the next decision. In particular, changing only marker compaction should not turn `unknown` into `ready`, and an entry excluded during validation should not reappear as an open blocker after posting.

### Assessment

**Ready to merge?** No

**Reasoning:** The overlap and failed-POST fixes address their reported failure cases. The remaining issues affect the gate itself: it can skip the operator’s history, report a known blocker as zero, or stop on blockers the visible review says do not exist.

---
*Review generated by gh pr-review · model: azure-openai-direct/gpt-6.2-astra*
