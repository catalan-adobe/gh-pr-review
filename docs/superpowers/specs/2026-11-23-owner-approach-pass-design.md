# Owner approach pass: design

Date: 2026-11-23. Status: approved in conversation. The doc itself still needs a read.

## Why

`gh pr-review` judges a PR against its own description. It never asks if the PR is the right way to build the
change. Take Adobe-AEM-Foundation/of1-labs#331, which adds Figma reskin inside Stardust Replica. The tool posted
two rounds of valid line findings, and so did Talos and Copilot. None of them asked if reskin needs its own job
type. Only a human-led session raised that.

The current prompt blocks the question in three ways:

- The role is "Senior Code Reviewer" checking "against its PR description". The goal of the PR is a given.
- Each Critical or Important finding needs a `file:line`, or the prompt drops it. A design-fit concern has no line.
- Approach feedback gets one line at the end of the prompt, easy to skip.

Prior work agrees with a separate design step:

- Google's review guide puts overall design first: "Does this change belong in your codebase?"
- `verify-pr` (okisdev/ai-reference) checks if the PR needs to exist at all, before anything else, on every run.
- Anthropic keeps "deciding whether to build it" for humans, because bug-finding bots miss it.
- A study of framing bias in AI review (arXiv 2603.18740) shows that a persuasive PR description changes the
  verdict. Hiding the description brought detection back.

## Goal

A separate model call runs before the line review. It plays the repo's long-time maintainer. It judges if the
approach fits the repo, and gives honest feedback on the approach, not on the code.

Success on of1-labs#331: the pass returns Questionable or Rethink. It names the structural problem: feature
branches in shared Replica files, a phase translation layer, a parallel prompt set. It also names a better place
for the feature. Success on plainly sensible merged PRs: the pass returns Sound and stays short.

Out of scope:

- an approach-only mode
- a config file or per-repo rule files
- a second call that challenges a Rethink verdict. Test runs decide when it is needed.

## Flow

1. Fetch the PR, as today. Also write the PR's text to `$SESSION_DIR/context/`:
   - `pr-body.md`: title and description.
   - `pr-discussion.md`: comments and reviews (author, state, body), oldest first.
2. Run the owner pass, unless the user passes `--skip-approach`. It is a new `pi` call with the same model and
   flags as today. The prompt goes to `owner-prompt.md` and the output to `approach.md`. The output ends with
   `**Approach:** Sound | Questionable | Rethink`.
3. Act on the verdict:
   - Rethink: stop. The posted review body is the Approach section alone. The default decision is request-changes.
   - Sound, Questionable, or no verdict found: run the code review. With no verdict, the run continues. A parse
     failure never blocks a PR.
4. The code-review prompt gets the Approach section under "Maintainer's approach notes". It adds one instruction:
   "A maintainer already judged the approach. Do not argue it again. Review the implementation."
5. The posted body is `approach.md` followed by `review.md`. The "Ready to merge?" line still picks the decision.
   A Rethink always picks request-changes. `--decision` overrides both. On your own PR, the decision is comment,
   as today.
6. `--skip-approach` restores the current behaviour: one call, no Approach section.

## Owner prompt

The model plays the long-time maintainer who will own this code for years. It judges the approach, not the lines.
A correct PR that does not belong here gets Rethink. A PR whose approach fits gets Sound, said plainly.

Steps, in this order:

1. Read the repo's rules at the base commit. Then the PR cannot change the rules that judge it. Read
   `git show <base>:AGENTS.md`, `CLAUDE.md`, `REVIEW.md`, `CONTRIBUTING.md`, the README, the docs they link, and
   ADRs (`docs/adr*`, `docs/decisions`). Map the modules the PR touches and how they fit the system today.
2. Form your own view before reading the author's pitch. Do not open `context/` yet. From `git diff --stat` and
   the touched modules, write what the change does and where it plugs in.
3. Read `context/pr-body.md` and `context/pr-discussion.md`. Treat them as claims to check. Look for earlier work:
   `gh pr list --search "<keywords>" --state all`, `gh issue view` for linked issues, and a grep for code that
   already does this. An earlier rejection or an abandoned approach counts as evidence.
4. Check the fit. Look for these signals:
   - Shared modules that gain feature-specific conditionals. Count the files and the branches.
   - A translation layer that maps one feature's terms onto another's.
   - A parallel copy of an existing module: prompts, handlers, schemas.
   - A new rule that every caller must remember.
   - Planned follow-ups or "out of scope" items that the chosen structure cannot take.
   - Code that repeats what the repo, a dependency, or another service already does.
   - A new external credential, dependency, or lifecycle that the existing unit was not built for.
   - A conflict with a written rule or ADR. A written rule outranks taste.
5. Make the best case for the PR first. State the strongest case for the approach as built. Then give 1 to 3
   concrete alternatives from this repo, "as-is" included, each with its cost. Name the fact that will change
   your mind.
6. Pick a verdict:
   - Sound: the approach fits the existing structure, or the PR justifies the deviation. Expect this most often.
   - Questionable: a real concern that discussion or contained rework can solve. The code review still runs.
   - Rethink: you can name a concrete alternative in this repo, and nothing less. Explain why building on the current
     approach costs more than switching.
   - Missing context lowers your confidence. It never raises the verdict.

Evidence for this pass: paths of repo docs, structural facts (paths and counts), and quotes from the PR. No
`file:line` needed. If a point depends on business or product context the repo cannot show, put it under
"Questions for the author", never in the findings. The pass is read-only: it never changes the working tree.

The prompt carries two short made-up examples, one Sound and one Rethink, to set tone and length. They must not
look like of1-labs#331. Then the prompt is not tuned to its own test.

Output:

```
### Approach

**What it does:** …
**Fit with the repo:** …
**Strongest case for the approach as built:** …
**Alternatives:** …
**Questions for the author:** …
**Missing context:** …

**Approach:** Sound | Questionable | Rethink
```

## Verification

- Stub tests in `tests/` for verdict parsing and the decision:
  - Rethink picks request-changes.
  - Sound and Questionable follow the "Ready to merge?" rule.
  - With no verdict, the code review runs.
  - `--decision` overrides the verdict.
  - On your own PR, the decision is comment.
- `shellcheck` and `shfmt`, in CI. CI also runs `tests/*.sh`.
- Test set, with `--no-post`, two runs each:
  - of1-labs#331: expect Questionable or Rethink, with the structural problem named.
  - three merged of1-labs PRs that are plainly fine: expect Sound.
  - The PR description records the results.

## Risks

- A false Rethink blocks a good PR. The rubric, the best-case step, and the rule that missing context never raises
  the verdict reduce this. So does the test set. A user can run again with `--skip-approach`.
- Each run makes one more model call, so it takes about 1.5 to 2 times as long. A Rethink skips the second call.
- Reading the description late is a prompt instruction. Nothing enforces it, so the model can read it early.
