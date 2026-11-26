# Reviewer instructions: design

## Why

The person who runs a review often knows things the PR does not say. For
example: "focus on the migration in `db/`", "ignore the generated files",
or "this is a spike, skip style nits". They need a way to pass that to the
reviewer for one run.

## What

- A new flag, `--instructions "<text>"`. For a file, use
  `--instructions "$(cat notes.md)"`. There is no separate file flag.
- Both prompts (the owner pass and the code review) get a
  `## Reviewer instructions` section with the text.
- Where they conflict with the default checklist, the instructions win.
  The output format, the verdict lines and the read-only rule still apply.
- The instructions are not posted. They stay in the session's
  `owner-prompt.md` and `prompt.md`.
- A missing or empty value fails with a clear error.

## Approaches

1. One text flag, both passes (picked). The smallest change, and a file
   works through `$(cat file)`.
2. Separate `--instructions-file`. Rejected: shell substitution already
   covers it.
3. Code review only. Rejected: notes such as "this is a spike" change the
   approach verdict too.

## Non-goals

- No per-repo config file and no environment variable default.
