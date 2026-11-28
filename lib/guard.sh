#!/usr/bin/env bash
# The reviewer's git sandbox: a read-only git on pi's PATH, no credentials, no hooks, and a tripwire on the review
# worktree around each pi call. Functions only.

# Puts lib/git-ro in <dir> as `git`, for pi_env.
pi_bin() { # <dir>
	mkdir -p "$1"
	cp "$(dirname "${BASH_SOURCE[0]}")/git-ro" "$1/git"
	chmod +x "$1/git"
}

# Runs a command (pi) in the sandbox: the wrapper in <bin-dir> first on PATH, the real git (the git on PATH now) in
# GH_PR_REVIEW_REAL_GIT, no credential helper, no hooks, no password prompt, no ssh, and no optional locks: `git status`
# does not rewrite the index.
pi_env() { # <bin-dir> <command> [args...]
	local bin=$1 real
	shift
	real=$(command -v git) || {
		echo "Error: git not found" >&2
		return 1
	}
	env PATH="$bin:$PATH" GH_PR_REVIEW_REAL_GIT="$real" \
		GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
		GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/dev/null \
		GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false SSH_ASKPASS=false GIT_SSH_COMMAND=false \
		GIT_OPTIONAL_LOCKS=0 "$@"
}

# What the reviewer must not change. worktree.txt: the review worktree's HEAD (commit and branch) and status.
# clone.txt: the clone's refs but refs/pr-review/, its HEAD and its stash. Errors go in the files: they compare too.
tripwire_snapshot() { # <clone> <worktree> <out-dir>
	local g=(--no-optional-locks -c core.hooksPath=/dev/null -c core.fsmonitor=false)
	mkdir -p "$3"
	{
		echo "HEAD $(git -C "$2" "${g[@]}" rev-parse HEAD 2>&1)"
		echo "branch $(git -C "$2" "${g[@]}" symbolic-ref -q HEAD 2>&1)"
		git -C "$2" "${g[@]}" status --porcelain 2>&1 || echo "status failed: $?"
	} >"$3/worktree.txt"
	{
		{ git -C "$1" "${g[@]}" for-each-ref --format='%(objectname) %(refname)' 2>&1 || echo "for-each-ref failed"; } |
			{ grep -v ' refs/pr-review/' || true; }
		echo "HEAD $(git -C "$1" "${g[@]}" rev-parse HEAD 2>&1) $(git -C "$1" "${g[@]}" symbolic-ref -q HEAD 2>&1)"
		git -C "$1" "${g[@]}" stash list 2>&1 || echo "stash list failed: $?"
	} >"$3/clone.txt"
}

# 0 when nothing changed. 4 when the worktree changed: prints what did. A change in the clone only (a commit or a
# branch I make while pi runs) is no stop: 0, with a warning.
tripwire_check() { # <before-dir> <after-dir>
	local clone=same
	cmp -s "$1/clone.txt" "$2/clone.txt" || clone=changed
	if ! cmp -s "$1/worktree.txt" "$2/worktree.txt"; then
		echo "The reviewer changed the review worktree (its HEAD or its files):" >&2
		{ diff -u "$1/worktree.txt" "$2/worktree.txt" || true; } | tail -n +3 >&2
		if [[ $clone == changed ]]; then
			echo "and the clone's refs, HEAD or stash:" >&2
			{ diff -u "$1/clone.txt" "$2/clone.txt" || true; } | tail -n +3 >&2
		fi
		return 4
	fi
	if [[ $clone == changed ]]; then
		echo "Warning: the clone's refs, HEAD or stash changed while the reviewer ran (the review worktree did not):" >&2
		{ diff -u "$1/clone.txt" "$2/clone.txt" || true; } | tail -n +3 >&2
	fi
	return 0
}
