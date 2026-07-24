# GitHub Action mode — design exploration

**Status:** investigation (2026-07-23). Not implemented. This documents the
findings and the intended design for running gh-pr-review's agentic review
inside GitHub Actions — on demand via a `/pr-review` PR comment, and
eventually automatically on new PRs.

## Why an Action at all

The local extension can't do **review automation** — reviews that happen on
GitHub without anyone at a terminal. That's the one capability that requires
CI. The Action is a second delivery surface for the same review process, not
a replacement: `gh pr-review` stays the richer interactive path.

## Feasibility: the agent loop exists in CI now

This tool's value is an *agentic* review — the model explores the checkout
(diff, blame, full files, related modules) rather than receiving a one-shot
prompt. Two developments make that possible in Actions:

1. **[GitHub Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/automate-copilot-cli/automate-with-actions)**
   runs agentically and headlessly in workflows: `copilot -p "<prompt>"`
   with tool permissions. The review prompt from `gh-pr-review` ports
   directly; `actions/checkout` supplies the PR checkout.
2. Authentication in CI is now officially supported (see below) — this was
   historically the blocker that forced tools like this one to stay local.

An earlier alternative considered and rejected: the GitHub Models API
(PAT with `models:read`). It is genuinely non-interactive and CI-friendly,
but single-shot — the workflow would have to inline diff + file contents
into one prompt, losing the agentic exploration and hitting context caps on
large PRs.

## The three identities

Every run involves three separate identities; conflating them is what makes
the auth question confusing:

| Identity | Used for | Source |
| --- | --- | --- |
| Workflow `GITHUB_TOKEN` | checkout, posting the review comment, reactions | automatic, per run |
| Copilot credential | the inference (the expensive part) | the design question below |
| Requester identity | selecting whose credential; billing attribution | `github.triggering_actor` |

Only the inference needs a Copilot credential. Repo operations never do.

## Authentication routes

### Route A — org-pooled: built-in `GITHUB_TOKEN`

Copilot CLI accepts the workflow's own `GITHUB_TOKEN` when the org has a
Copilot subscription **and** the org's **"Copilot CLI in Actions" policy**
is enabled ([docs](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli-in-actions)).
Zero secrets, zero user setup; billing goes to the org's Copilot plan.
Unavailable in orgs without Copilot.

### Route B — user-tied: fine-grained PAT with "Copilot Requests"

Fine-grained PATs now support a **Copilot Requests** permission
([docs](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli)).
Key properties:

- **User-owned only.** The permission does not appear on org-owned PATs
  (tracked in [copilot-cli#223](https://github.com/github/copilot-cli/issues/223)).
  This is the feature, not a bug: the token represents the *user's* Copilot
  access and works in any org's repo, regardless of that org's subscription.
- **Minimal blast radius.** The PAT is used only for inference — scope it to
  *Public repositories (read-only)* with no repo permissions beyond Copilot
  Requests. If it leaks, it can spend quota, not touch code.
- **Billing follows the token owner** — their seat's monthly premium-request
  allowance, attributed to them in admin usage reports.
- **Distribution cost:** Actions secrets are repo/org-scoped, so each user
  stores their PAT as a secret per repo/org, named by convention:

  ```yaml
  env:
    COPILOT_GITHUB_TOKEN: ${{ secrets[format('COPILOT_PAT_{0}', github.triggering_actor)] }}
  ```

  Gotcha: secret names allow only `[A-Za-z0-9_]` but usernames may contain
  `-` — normalize in a small step (never by dumping `toJSON(secrets)` into
  the job, which exposes every secret).
- Classic PATs (`ghp_`) are **not** supported by Copilot CLI.

### Route C — GitHub App with user authorization (deferred)

Copilot CLI/SDK also accept `ghu_` user-to-server tokens from an OAuth
GitHub App: users authorize once, tokens are short-lived, no secrets to
distribute. The catch: GitHub delivers the user token **once, to the app's
callback** — GitHub is not a retrievable token vault. Someone must operate
a backend that stores refresh tokens (which rotate on use), verifies
workflow claims (GitHub Actions OIDC: validate the JWT, match the `actor`
claim), and enforces a repo/org allowlist against the confused-deputy
attack (a hostile repo triggering token release by luring a user to comment
there). Right answer at scale; disproportionate for a small user base.

### The dedicated-seat variant ("org PAT" that isn't)

Since only users can own Copilot-capable PATs, org-level automation in a
non-Copilot org means a **service account**: a machine user granted one
Copilot seat, whose user-owned PAT is stored as an org secret. Admin
controlled, attributable to the bot, own allowance. Costs a seat; in
enterprise-managed (EMU) enterprises, service accounts must be provisioned
through the IdP.

### Comparison, including the zero-build alternative

| | "Connected to my user"? | Who runs the broker | Custom review prompt? |
| --- | --- | --- | --- |
| Native [Copilot code review](https://docs.github.com/en/copilot/using-github-copilot/code-review) | ✅ automatic | GitHub | ❌ (instruction files only) |
| Route B (PAT secret) | ✅ manual (user places credential) | nobody | ✅ |
| Route C (GitHub App) | ✅ after one-time authorize | you | ✅ |

Native Copilot code review is worth benchmarking against this tool's
agentic prompt before investing in the Action — if it's good enough for the
CI case, this design shrinks to a README paragraph.

## Billing model (why "requester pays" works)

- **Metering is per user.** Each seat has a monthly premium-request
  allowance (resets on the 1st, UTC). Model multipliers apply — an advanced
  reasoning model can consume 5–20× per prompt, so **model choice is a
  budget decision**. One agentic review ≈ one prompt × multiplier.
- **Payment is per org/enterprise.** Overage beyond a user's allowance is
  governed by the org's
  [premium request overage policy](https://docs.github.com/en/copilot/how-tos/manage-and-track-spending/manage-request-allowances)
  (billed vs blocked/degraded).
- A comment-triggered review with the requester's PAT therefore maps 1:1
  onto GitHub's own metering: self-limiting, fairly attributed, admin
  visible. Automatic review on every PR charged to one person's seat can
  exhaust it mid-month — automation belongs on Route A or a dedicated seat.
- **Measuring real cost per review** (no dashboard needed): snapshot
  `credits_used` before/after a run —

  ```bash
  gh api copilot_internal/user --jq .quota_snapshots.premium_interactions.credits_used
  ```

  Caveat: internal client endpoint, undocumented, may change shape. Useful
  for personal measurement; do not build on it. (Enterprise-managed users
  may have no personal billing UI at all — EMU accounts 404 on
  `github.com/settings/billing`; itemized reports live with org admins.)

## On-demand flow (`/pr-review` comment)

Slash commands are not a platform feature — the "trigger" is a workflow on
the repo's **default branch** listening to `issue_comment`. Lifecycle:

1. **Gate:** PR comments only, `startsWith(body, '/pr-review')`, commenter
   has `write`+ permission (anti-abuse: nobody else can spend credits or
   feed the agent instructions).
2. **Ack:** 👀 reaction on the comment.
3. **Credential ladder:**

   ```text
   1. COPILOT_PAT_<REQUESTER> secret exists?   → requester's PAT (works in any org)
   2. org has Copilot + CLI-in-Actions policy? → GITHUB_TOKEN (org pays)
   3. neither                                  → teaching failure comment
      ("create a PAT with Copilot Requests, store as COPILOT_PAT_<YOU>")
   ```

4. **Checkout** the PR ref. `issue_comment` workflows always execute the
   *default-branch* workflow definition, so a hostile PR cannot rewrite the
   workflow itself.
5. **Review:** Copilot CLI programmatic mode with this repo's review
   prompt. Hardening: read-only tool allowlist
   (`--allow-tool 'shell(git diff,git log,git show,git blame,cat,ls)'`),
   deny writes, `--secret-env` masking, no unrelated secrets in the job,
   ~15 min timeout, concurrency group per PR (re-request cancels prior
   run). A prompt-injected diff can at worst produce a bad review.
6. **Deliver:** post as PR comment via `GITHUB_TOKEN` with an HTML marker
   for idempotent re-runs; flip reaction to ✅/❌.

## Deployment: getting the trigger into repos

- **Reusable workflow + thin shim** (chosen direction): all logic lives in
  this repo (`on: workflow_call`); each repo carries only a ~12-line shim
  declaring the `issue_comment` trigger and `uses:` pointing here. Central
  fixes propagate on the next run. `on:` triggers cannot live in the
  reusable part — the shim must declare them.
- **`gh pr-review setup-action`** (planned): the extension scaffolds the
  shim and opens the PR adding it — one command per repo, and the PR body
  doubles as the PAT-setup teaching moment.
- **Org-wide, no per-repo file:** org rulesets can require a centrally
  defined workflow on all PRs — fits the *automatic* mode (pull_request
  trigger, GHEC + admin), not comment triggers. A GitHub App with
  `issue_comment` webhooks would cover on-demand org-wide but is Route C
  infrastructure.

## Proposed scope

- **v2:** comment-triggered on-demand reviews. Credential ladder steps 1–3.
  Reusable workflow + shim + `setup-action`. Same review prompt as the CLI.
- **v2.x:** auto-trigger (`pull_request`) as opt-in config, documented as
  requiring Route A or a dedicated seat. Org-ruleset recipe for enterprises.
- **v3 (evidence-gated):** Route C token service, only if adoption makes
  per-repo PAT distribution the dominant pain.

## Open questions

- Comment flag parsing surface (`--model`, `--depth`?) and per-repo config
  (default model, max PR size).
- Re-runs: edit the existing review comment vs append.
- Checkout choice: PR merge ref vs head ref.
- Benchmark: native Copilot code review vs this prompt, same PRs.
- Quota-aware runs: warn when the requester's `percent_remaining` is low
  (blocked on official per-user quota API; internal endpoint unsuitable).
