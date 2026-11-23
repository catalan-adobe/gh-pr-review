# Owner approach pass: test-set results

Date: 2026-11-23. Model: `github-copilot/gpt-5.6-sol`. Each PR ran twice with `--no-post`, all runs in parallel.
No prompt tuning was needed.

## Results

| PR | What it is | Expected | Run 1 | Run 2 | Run time (s) | Approach length (words) |
| --- | --- | --- | --- | --- | --- | --- |
| of1-labs#331 | Figma reskin in Stardust Replica (open) | Questionable or Rethink | Questionable | Questionable | 692, 388 | 266, 329 |
| of1-labs#467 | Admin-only portal pages (merged) | Sound | Questionable | Questionable | 226, 219 | 251, 244 |
| of1-labs#454 | UTC label in the ready email (merged) | Sound | Sound | Sound | 154, 150 | 133, 184 |
| of1-labs#448 | DA config access with content (merged) | Sound | Sound | Sound | 226, 272 | 201, 178 |

The verdicts matched across both runs of every PR.

## Reading the results

**#331 met the success test.** Both runs judged the approach Questionable. Both named a structural problem and gave
alternatives with costs. The author changed the PR on the morning of the test: head `1b1c976`,
"feat: run Figma reskin as its own job kind". Reskin now has a job driver (`container/src/replica/job.ts`) and a
`stardust-reskin` create alias. The pass credited the job driver as a good seam. Then it found the problem in the
new design:

- `type: "stardust-reskin"` is translated to `stardust-replica` at create. It is not in the type registry, which
  `docs/experiment-types.md` names as the single source of truth.
- Run 2 also counted reskin-aware code in 11 existing container modules, and the phase translation in `ledger.ts`.
- Both runs quoted the planned "Figma-only run" follow-up as a reason the identity question matters.
- Both runs offered the same three options: `jobKind: "reskin"` on the Replica type, a real registered type, or
  as-is.

It did not return Rethink. That fits the rubric: the PR moved toward a separate job, and the open question is the
API identity, which discussion can settle.

**#467 is a true positive, not a false alarm.** We expected Sound. Both runs found that the code fits, and flagged a
written-rule conflict instead. `AGENTS.md` says behaviour described in of1/docs must be updated in the same work.
The PR body says "The umbrella repo docs (of1/docs) are not updated". The pass checked `of1/docs/integrate/with-labs.md`,
which still tells non-admin Adobe users to open the OF1 page.

The verdict is Questionable, not Rethink, and the fix it names is a companion docs PR. That is the behaviour we
want: a written rule outranks taste.

**#454 and #448 returned Sound**, short and specific, with "Questions for the author: None".

## Later single runs

After the test set, the final code ran once on four more open PRs, with `--no-post`.

| PR | What it is | Approach | Run time (s) |
| --- | --- | --- | --- |
| of1-labs#460 | Replica status page facts as report JSON | Sound | 583 |
| of1-labs#466 | Insights for http:// sources, retries, backfill | Sound | 344 |
| of1-labs#473 | Opt-in Pi and GPT-6.2 Astra for Replica | Questionable | 1523 |
| of1-labs#462 | DA site plugins and flags at Replica completion | Rethink | 146 |

- #473: Pi branches in 14 production files, picked by a model name instead of an extension point. The pass asks
  if Pi is a time-boxed pilot or a runtime the team will keep.
- #462: a second writer of the DA site config next to Stardust's `da-library.mjs`, which #458 makes part of
  completion. The run stopped before the code review, as designed. A manual check confirmed the line counts, #458,
  the stale-read note in the runbook and the missing of1/docs link. It did not confirm that both writers touch the
  same config keys.

## Things noticed

- On a merged PR, the merge base equals the head, so `base..head` is empty. The model noticed and reviewed the PR's
  commits instead. This is how the script already worked before this change, and it does not affect open PRs.
- The approach pass adds 1 to 4 minutes per run. #331 is the slowest, at 6 to 11 minutes in total.

## #331 Approach section (run 2)

The model's output, unchanged:

````markdown
### Approach

**What it does:** Adds a Figma-backed `reskin` job to the existing Stardust Replica lifecycle, including encrypted token handling, distinct prompts, scoped completion, and restart behavior.

**Fit with the repo:** The runner-side approach fits well: `container/src/replica/job.ts` selects one job driver that owns prompts, contract, scope, and delivery while reusing Replica’s container, attempts, checkpoints, and UI. The concern is API identity. `docs/experiment-types.md` names `service/src/lib/type-registry.ts` as the type source of truth, but create accepts the unregistered `type: "stardust-reskin"`, immediately translates it to `stardust-replica`, stores `job_kind = 'reskin'`, and reads it back as `type: "stardust-replica", jobKind: "reskin"`. That create/read asymmetry is a translation layer outside the documented extension point. Reskin also requires phase translation in `ledger.ts` and reskin-aware behavior across 11 existing container modules.

**Strongest case for the approach as built:** Reskin genuinely shares Replica’s provisioning, access, quotas, attempts, runtime, and delivery lifecycle. Making it a separate stored experiment type would duplicate policy and require the hazardous table rebuild described in `docs/onboarding-new-experiment-type.md`. The new job-driver seam is substantially better than scattering top-level job branches through `ReplicaOps`.

**Alternatives:** (1) Keep the implementation and `job_kind`, but create with `type: "stardust-replica", jobKind: "reskin"`; small coordinated change to the pending Catalyst PR, and the API matches storage and reads. (2) As-is; lowest immediate cost, but permanently bypasses the type registry and encourages another pseudo-type for the PR’s planned “Figma-only run” follow-up. (3) Register and store `stardust-reskin` as a true type; highest migration and policy cost, justified only if it needs independent access, quotas, or product identity.

**Questions for the author:** Is `type: "stardust-reskin"` an externally fixed contract? Why not use the `jobKind` discriminator already persisted and returned? Is sharing Replica access and quotas a confirmed product decision?

**Missing context:** No ADR or PR rationale explains why the public create contract should look like a new type while every persisted and returned representation treats it as a Replica job. The linked Catalyst PR is still open, so it does not establish a compatibility constraint.

**Approach:** Questionable
````
