# Review dashboard: design

Date: 2026-11-26. Status: drafted in conversation, decisions below agreed. The doc itself still needs a read.

Builds on [review tracking](2026-11-26-review-tracking-design.md): round records (phase 1), `status` (phase 4) and
the shepherd (phase 5).

## Why

`gh pr-review status` prints a table. A table answers "what is the state", but a review session is a loop of small
moves: look at the PRs that need me, read why one is stuck, look at its rounds and open findings, run a round or ask
an agent, approve a shepherd draft, and move on. I want to do all of that from one keyboard-driven screen that looks
good.

## Goal

`gh pr-review dash`: a terminal dashboard that works in any terminal.

- One screen lists every PR that involves me, grouped by whose turn it is, with its loop label and a sparkline of
  blocking findings per round.
- A detail pane shows a PR's overview, rounds, findings, threads and shepherd drafts.
- Every move is one key: run a round, preview, ask an agent, open the worktree, view the delta, approve a draft.
  `?` lists every key.
- Long jobs (a review round takes 5 to 10 minutes) run in the background. The dashboard stays usable, shows their
  progress and live log, and says when they end.
- It paints from cache at once and refreshes in the background. It never blocks on the network.
- Later, optionally: launch jobs and agents in herdr panes, or any multiplexer through a command template.

Success test:

- From start to a painted list in under 200 ms (warm cache).
- Every action is reachable from the keyboard, and `?` lists every binding.
- It is usable at 80×24 (list only, detail on Enter) and comfortable at 160×45 (list and detail side by side).
- No action posts to GitHub without a confirm dialog that shows the exact text.
- Everything works in a plain terminal, with no multiplexer.

Out of scope:

- Merging, approving outside the shepherd, writing comments by hand: GitHub and `gh` do that well.
- A diff viewer: `d` hands the delta to `$GH_PAGER`, `delta` or `less`.
- Mouse-first use. Mouse scrolling and clicks work where Ratatui gives them for free.

## Decisions taken in conversation

- **Stack:** Rust and Ratatui (with the crossterm backend).
- **Standalone first.** The dashboard runs in any terminal. Jobs run as its own background processes. Herdr is an
  optional launcher for a later phase, not a requirement.
- **When herdr comes (phase D5):** a popup key binding and a "reviews" tab; jobs and agents in herdr panes.
- **Agent for `a`:** pi by default, configurable.

## Architecture

### A thin client over the CLI

The dashboard computes nothing about reviews. It reads JSON from `gh pr-review` subcommands and runs `gh pr-review`
subcommands for every action. The loop rules, the records and the GitHub queries stay in one place (Bash and jq),
and everything the dashboard shows can be scripted or checked without it.

| Need | CLI call | From |
| --- | --- | --- |
| The PR list | `gh pr-review status --json [--cached]` | phase 4 |
| One PR in detail | `gh pr-review show <PR> --json` | new, phase 4 |
| A one-line count | `gh pr-review status --short` | new, phase 4 |
| The loop check before a round | `gh pr-review <PR> --check --json` | new, phase 3 |
| Shepherd drafts | `gh pr-review shepherd inbox --json` | phase 5 |
| Actions | `gh pr-review <PR> …`, `shepherd approve <id>`, `gc`, … | phases 1 to 6 |

`status --json` and `show --json` carry `"schema": 1`. The dashboard refuses another major version, with a message
that names both versions.

### The JSON it reads

`status --json`, one object per PR, as phase 4 defines it, with at least:

```json
{
  "schema": 1,
  "generated_at": "2026-11-26T09:12:00Z",
  "accounts": [ { "host": "github.com", "user": "catalan-adobe", "ok": true } ],
  "hidden": { "bots": 152, "stale": 66, "ignored": 0 },
  "gc_candidates": 3,
  "prs": [ {
    "key": "github.com/adobe/skills#823",
    "url": "https://github.com/adobe/skills/pull/823",
    "title": "…", "author": "catalan-adobe", "account": "catalan-adobe",
    "roles": ["author"], "draft": true, "checks": "success",
    "size": { "additions": 2939, "deletions": 215, "files": 62 },
    "created_at": "…", "updated_at": "…",
    "turn": { "who": "me", "reason": "2 commits since round 2" },
    "label": "early", "flags": ["too-big"],
    "rounds": [ { "round": 1, "at": "…", "head": "c3fd879", "approach": "questionable", "ready": "no",
                  "critical": 2, "important": 7, "minor": 1, "blocking": 9, "source": "backfill" } ],
    "threads": { "open": 0, "outdated_unresolved": 0, "resolved": 0 },
    "restart_of": "github.com/adobe/skills#813", "superseded_by": null,
    "worktree": "/Users/…/skills.reviews/feat-extend-pages/823",
    "shepherd_pending": 0,
    "loop_check": null
  } ]
}
```

`show <PR> --json` adds what only the detail pane needs: the full round records (findings with status), each
round's review body (the posted Markdown, from `round-K/posted.md` when present, else from GitHub), the review
threads (path, line, state, author, first comment), and the PR description.

`status --short` reads only the cache, prints one line such as `⚑4 ✓1 ↻2` (my turn, ready, jobs running), and
returns in under 50 ms. It prints nothing when there is no cache. It fits a shell prompt, a tmux status line, or a
herdr tab bar.

### Entry point and install

- `gh pr-review dash` is a Bash subcommand. It looks for the `gh-pr-review-dash` binary on `PATH`, then in
  `${XDG_DATA_HOME:-~/.local/share}/gh-pr-review/bin/`, and `exec`s it with `GH_PR_REVIEW_BIN` set to the running
  script, so the dashboard always calls the same CLI version.
- Missing binary: it prints the install command and exits 1:
  `cargo install --locked --git https://github.com/catalan-adobe/gh-pr-review gh-pr-review-dash`.
- Later: release binaries (cargo-dist) and `gh pr-review dash --install`, which downloads the one for this platform.
- The crate lives in `dash/` in this repo. CI runs `cargo fmt --check`, `cargo clippy -D warnings` and `cargo test`
  there.

### Inside the binary

- **Crates:** `ratatui` and `crossterm` for the UI, `serde` and `serde_json` for the data, `tui-markdown` (or
  `pulldown-cmark` with our own styling, if it falls short) for review bodies, `nucleo` for the filter and the
  command palette, `notify` to watch the state folder.
- **Modules:** `model` (types for the JSON), `cli` (runs `gh pr-review`, with timeouts, in worker threads), `jobs`
  (jobs and their `Launcher`), `ui` (list, detail tabs, sparkline, Markdown, log view, help overlay, confirm dialog,
  palette, toasts), `keys` (the keymap, overridable from the config), `config`.
- **Event loop:** terminal events, a tick, and messages from the workers (refresh done, job changed, state folder
  changed) on one channel. Drawing never waits on a worker.
- **Refresh:** paint from `status --json --cached`, then run `status --json` in the background. Refresh again every 5
  minutes (configurable), after every job, on `R`, and when a file in the state folder changes.
- **Handing the terminal over:** for `$EDITOR`, the pager, a shell in the worktree, or an interactive agent, the
  dashboard leaves the alternate screen, runs the program in the same terminal, and comes back when it exits.
  Background jobs keep running meanwhile.

## Jobs

`r` (round), `p` (preview) and `s` (shepherd) start a job. A job is one `gh pr-review` command.

- **The default launcher, `inline`:** the dashboard starts the command in a new session (`setsid`), with stdin from
  `/dev/null`, stdout and stderr in `<state>/jobs/<job-id>.log`, wrapped so that its exit code lands in
  `<state>/jobs/<job-id>.exit`. `<job-id>.json` records the kind, the PR, the command, the start time and the PID.
- **Progress:** the Jobs view and the header show running jobs. The PR row shows a spinner. The detail's Overview
  shows the job's last log line.
- **The end:** the dashboard watches the `.exit` file. It updates the job, refreshes the PR, and shows a toast:
  - `0`: "Round 3 posted · #823 · blocking 5 (was 6) · converging".
  - `3`: "Loop check stopped #813 · churning · see the diagnosis".
  - `5`: "#823 · no new commits since round 2".
  - `4` or `1`: "Review of #823 failed · see the log".
  `dash.notify` adds the terminal bell (`bell`) or a desktop notification through OSC 9 (`desktop`, for terminals
  that support it) on top of the toast.
- **Quitting with jobs running:** the dashboard asks, then leaves them running. They run in their own session, so
  quitting, or closing the terminal window, does not stop them. Their `.exit` files are read on the next start, and
  the toast shows then.
- **Limits:** at most `dash.max_jobs` (default 3) running at once; more wait in a queue. One job per PR at a time;
  the CLI's per-PR lock backs that up.
- **Interactive prompts:** jobs always run with `-y`, so the loop check answers with exit code 3 instead of asking.
  `r` first runs `gh pr-review <PR> --check --json` and shows the result in the dashboard. On a stop, the dialog
  offers "run anyway" (`--force-round`) or "ask an agent" (`a`).

## Screens

### Dashboard

```
╭─ gh pr-review ───────────────────────────── 3 accounts · refreshed 2m ago · ⟳ 1 job running ─╮
│  Your turn 4   Waiting on author 3   Ready 1   Others 6                       / filter      │
├────────────────────────────────────────────┬────────────────────────────────────────────────┤
│ YOUR TURN                                  │ adobe/skills#823  replica --extend adds pages… │
│ ▸ ● Churning   skills#813  14 ▅▇▅▆▅▅▅▆▆▄▅▅ │  1 Overview  2 Rounds  3 Findings  4 Threads  5 Shepherd
│   ◐ Early      skills#823   2 ▆▄  ⟳        │                                                │
│   ◐ Early      of1-labs#331 2 ▃▆  ⚑threads │  Loop      Early · 2 rounds · blocking 9 → 7   │
│   ◆ Nit loop   of1-labs#504 6 ▁▁▃▂▃▃       │  Approach  Questionable, both rounds           │
│ WAITING ON AUTHOR                          │  Turn      yours: 2 commits since round 2      │
│   ○ Converging of1-labs#512 8 ▅▂▂▁ ▁▁      │  Restart   of #813 (14 rounds, Churning)       │
│ READY TO MERGE                             │  Job       round 3 running · 4m · reading diff │
│   ✓ Ready      …                           │                                                │
│                                            │  Suggested: a ask an agent                     │
├────────────────────────────────────────────┴────────────────────────────────────────────────┤
│ j/k move  ⏎ open  r round  p preview  a agent  w worktree  d delta  o browser  ? help  q quit │
╰─────────────────────────────────────────────────────────────────────────────────────────────╯
```

- **Header:** accounts (a red mark on one that failed), the time of the last refresh, running jobs, the count per
  group, and the filter.
- **List:** groups in this order: Your turn, Waiting on author, Ready to merge, Others. Inside a group: Churning,
  Nit loop, Converging, Early, Ready, New. A row: label (symbol and color), short repo and number, rounds, a
  sparkline of blocking findings per round (a gap for a Rethink round), flags, a spinner while a job runs, and the
  title in the space left. Superseded PRs are dim, with a "→ #823" mark.
- **Detail tabs:**
  1. **Overview:** the loop diagnosis, why it is my turn, the approach trend, size, checks, restart or superseded
     links, the worktree, a running job, and up to two suggested keys.
  2. **Rounds:** one row per round (date, commit, commits since, approach, ready, counts, source). Enter shows that
     round's review, rendered as Markdown.
  3. **Findings:** the latest record's findings, grouped Open, New, Regressed, Later, Fixed, with severity,
     `file:line` and title. Enter opens the file at that line in `$EDITOR`, in the review worktree.
  4. **Threads:** human review threads: open first, then outdated and unresolved, then resolved (folded).
  5. **Shepherd:** this PR's drafts, with the same keys as the inbox.
- **Footer:** the keys that apply to the focused element. Toasts appear above it for a few seconds.

### Inbox

All pending shepherd drafts, newest first: PR, action, reason. The right side shows the exact text it would post.
`A` approve, `E` edit in `$EDITOR`, `X` reject with a reason.

### Jobs

Running, queued and finished jobs: kind (round, preview, shepherd), PR, start time, duration, state (queued,
running, done, stopped by the loop check, nothing to review, failed). Enter opens the job's log full screen, in
follow mode while it runs (`F` toggles follow, `G` jumps to the end). `K` stops a running job (confirm first). `c`
clears finished jobs.

### Layout by size

- 140 columns or more: list and detail side by side.
- 100 to 139 columns: detail below the list.
- Less than 100 columns, or less than 24 rows: list only. Enter opens the detail full screen, `esc` goes back.

### Look

- One accent color (config `dash.theme.accent`, default cyan). Label colors: Ready green, Converging cyan, Early
  gray, Nit loop yellow, Churning red, Stale and Superseded dim.
- A symbol for every label (`✓ ○ ◐ ◆ ●`), so meaning never depends on color alone. `NO_COLOR` turns color off.
  `--ascii` swaps Unicode symbols and sparklines for ASCII.
- The sparkline is green when the last value is lower than the first, red when it is not.
- The selected row has an accent bar on the left and a bold title. No full-row reverse video.
- Dark and light themes. `dash.theme.mode` = `auto` (from the terminal background, dark if unknown), `dark`
  or `light`.

## Keys

Vim-style movement and one-letter mnemonic actions. Lowercase keys act on my side. Uppercase `A`, `E` and `X` act on
shepherd drafts, and `K` stops a job. No `ctrl+b`, `ctrl+a` or `ctrl+space`, the usual multiplexer prefixes.

| Area | Key | Does |
| --- | --- | --- |
| Move | `j` `k` `↓` `↑` | next and previous row |
| | `gg` `G` | first and last row |
| | `ctrl+d` `ctrl+u` | half a page down and up |
| | `[` `]` | previous and next group |
| | `tab` `shift+tab` | focus list ↔ detail |
| | `1`–`5` | detail tab |
| Views | `I` | inbox |
| | `J` | jobs |
| | `esc` | back, close a dialog, clear the filter |
| | `/` | filter (fuzzy, over repo, number, title, author, label) |
| | `:` | command palette (every action, by name) |
| | `?` | help overlay |
| | `R` | refresh now |
| | `q` | quit (asks when jobs are running; they keep running) |
| Selected PR | `enter` | open the detail (or full screen at small sizes) |
| | `r` | run a round: shows the loop check result first, then confirms |
| | `p` | preview a round (`--no-post`) |
| | `a` | ask an agent about this PR, in its review worktree |
| | `w` | open a shell in the review worktree |
| | `d` | the delta since the last round, in the pager |
| | `e` | open the selected finding in `$EDITOR` |
| | `s` | run the shepherd for this PR (draft) |
| | `o` | open the PR in the browser |
| | `y` | copy the PR URL (OSC 52, else `pbcopy` or `xclip`) |
| | `x` | mute the PR (adds it to the config `ignore` list; `:unmute` undoes) |
| Shepherd drafts | `A` | approve: confirm dialog with the exact text, then the executor runs |
| | `E` | edit the text in `$EDITOR` |
| | `X` | reject, with a reason |
| Jobs | `enter` | the job's log |
| | `F` | follow the log on or off |
| | `K` | stop the job |
| | `c` | clear finished jobs |

Bindings are overridable in the config (`dash.keys`), and `?` always shows the live map.

Confirm dialogs: the text that will be posted, the target PR and the account. `enter` or `y` confirms. `esc` or `n`
cancels. The default button is Cancel for `A` on a high-risk action.

## Asking an agent (`a`)

1. `gh pr-review show <PR> --json` gives the history. The dashboard writes a brief to
   `<pr_state_dir>/brief-<time>.md`: the PR, the loop label and diagnosis, the round series, the open and Later
   findings, the approach notes, the open threads, and the question "What should happen next with this PR: another
   round, a split (into what), a design decision (which), or approve with follow-ups?".
2. The dashboard hands the terminal to the agent, in the review worktree:
   `dash.agent.command`, default `pi "Read {brief}, then answer its question."`. It comes back when the agent exits.
3. The agent works in the review worktree, so the reviewer's read-only rules do not apply to it. It is my session,
   like any other.

`{brief}`, `{worktree}`, `{pr}`, `{url}` and `{number}` are the placeholders. The default works for pi. Other agents
get their own command, for example `claude "Read {brief}, then answer its question."`.

## Launchers (phase D5, optional)

The default `inline` launcher needs nothing but a terminal. A launcher only changes *where* a job or an agent runs;
the `.log`, `.exit` and `.json` files stay the same, so the Jobs view and the toasts work with every launcher.

- `inline` (default): jobs as background processes; agents, the shell and the editor take over the terminal.
- `command`: templates for other multiplexers, with the same placeholders plus `{cmd}`, `{cwd}` and `{title}`:

  ```json
  "launcher": {
    "type": "command",
    "job": "tmux new-window -d -c {cwd} -n {title} {cmd}",
    "agent": "tmux new-window -c {cwd} -n {title} {cmd}"
  }
  ```

- `herdr`: a built-in preset, used when `HERDR_ENV=1` and `herdr` is on `PATH`:
  - Jobs go to panes in a "reviews" tab (`herdr tab create --label reviews --no-focus`, then `herdr pane split
    --no-focus --cwd <worktree>`, `herdr pane rename`, `herdr pane run`), at most `dash.max_job_panes` panes. Enter
    on a job focuses its pane.
  - `a` makes a tab in the review worktree and starts the agent there (`herdr agent start pr-823 --kind pi --pane
    <root>`, then `herdr agent prompt pr-823 "Read <brief>, then answer its question."`), or focuses that agent if
    it is already alive.
  - A job's end also shows a herdr notification (`herdr notification show … --sound done|request`).
  - The dashboard reports `status --short` as workspace metadata (`--token reviews=…`) for a sidebar row.
  - Starting it: a popup binding in `~/.config/herdr/config.toml`, and `gh pr-review dash --tab`, which runs it in a
    "reviews" tab:

    ```toml
    [[keys.command]]
    key = "prefix+r"
    type = "popup"
    command = "gh pr-review dash"
    width = "90%"
    height = "85%"
    ```

  - The dashboard only closes panes it created, and targets panes and tabs by the IDs herdr returns.

## Config

The dashboard reads the `dash` section of the shared config file
(`${XDG_CONFIG_HOME:-~/.config}/gh-pr-review/config.json`):

```json
"dash": {
  "refresh_minutes": 5,
  "max_jobs": 3,
  "notify": "toast",
  "agent": { "command": "pi \"Read {brief}, then answer its question.\"" },
  "launcher": { "type": "inline" },
  "theme": { "mode": "auto", "accent": "cyan" },
  "keys": { "run_round": "r", "ask_agent": "a" }
}
```

## Phases

| Phase | What | Needs |
| --- | --- | --- |
| D1 | Read-only dashboard: list, groups, labels, sparklines, detail tabs, filter, palette, help, refresh | tracking phases 1 and 4 (`status --json`, `show --json`) |
| D2 | Actions and jobs, inline launcher: `r`, `p`, `a`, `w`, `d`, `e`, `o`, `y`, `x`; Jobs view, log view, toasts | D1; tracking phases 2 and 3 |
| D3 | Inbox and shepherd keys | D1; tracking phase 5 |
| D4 | `dash --install` with release binaries; `status --short` recipes for a shell prompt and tmux | D2 |
| D5 | Optional launchers: `command` templates and the `herdr` preset | D2 |

D1 can start before tracking phase 4 ships: it is built and tested against synthetic `status --json` and
`show --json` fixtures that follow the schema above. Phase 4 then has to produce that schema.

## Verification

- Unit tests: JSON fixtures parse, schema mismatch is refused, grouping and sorting, filter matching, the keymap
  (key and focus give an action), job state from `.exit` files, the queue and the per-PR job limit.
- Render tests: Ratatui's `TestBackend` with `insta` snapshots, at 80×24, 120×40 and 160×45, in dark, light,
  `NO_COLOR` and `--ascii`.
- A fake `gh-pr-review` (a script that prints fixtures, sleeps, writes logs and exits with a chosen code) for job,
  toast and refresh tests, including a job that outlives the dashboard.
- By hand, in a plain terminal (macOS Terminal or Ghostty, no multiplexer): a real round as a job, the log view, `a`
  with pi, `w`, `d`, `e`, quitting with a job running and seeing its toast on the next start.
- D5: a fake `herdr` (a script that records its arguments and prints herdr's JSON shapes), the tmux template, and by
  hand inside herdr.

## Risks

- **The dashboard depends on the CLI's JSON.** The schema version and the fixture tests guard it. The Bash side gets
  a test that its output matches the fixtures' shape.
- **Orphaned jobs.** A job that outlives the dashboard keeps its `.json`, `.log` and `.exit` files, so the next
  start picks it up. A job with no `.exit` file whose PID is gone is marked "lost".
- **Two languages in one repo.** Bash and jq for the engine, Rust for the dashboard. The JSON contract is the only
  link, and each side has its own CI job.
- **Terminal differences.** OSC 52 and OSC 9 are not everywhere: copy falls back to `pbcopy` or `xclip`, and the
  toast always shows.

## Open questions

1. Is `tui-markdown` good enough for review bodies (tables, nested lists, code spans), or do we style
   `pulldown-cmark` events ourselves?
2. Should a round started from the dashboard post right away, or always start as a preview (`p`) that `r` then
   posts? Proposal: `r` posts after the confirm, as on the command line.
3. D5 only, for herdr: does `herdr tab focus` from a popup close the popup? The shape of a `tab_bar_right` entry of
   type `command`. `herdr worktree open` or a plain tab for the worktree?
