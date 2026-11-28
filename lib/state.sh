#!/usr/bin/env bash
# The state folder: one folder per PR for its runs, its lock, pr.json and the last loop check. Functions only.
# PR_STATE_DIR is the PR's folder (pr_state_dir), set by the caller.

# Prints the state folder: $GH_PR_REVIEW_STATE, else $XDG_STATE_HOME/gh-pr-review, else ~/.local/state/gh-pr-review.
state_root() {
	echo "${GH_PR_REVIEW_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/gh-pr-review}"
}

# Prints the PR's folder: <state_root>/<host>/<owner>/<repo>/<N>. GitHub names are case-insensitive, so host, owner
# and repo are lowercased. A part that is empty, `.`, `..` or holds a `/` is an error: the folder never leaves the
# state folder.
pr_state_dir() { # <host> <owner> <repo> <N>
	local part
	for part in "$1" "$2" "$3" "$4"; do
		if [[ -z "$part" || "$part" == . || "$part" == .. || "$part" == */* ]]; then
			echo "Error: not a usable PR folder name: '$part'" >&2
			return 1
		fi
	done
	echo "$(state_root)/$(tr '[:upper:]' '[:lower:]' <<<"$1/$2/$3")/$4"
}

# Takes the PR's lock: the folder <PR_STATE_DIR>/lock with this process's PID in lock/pid, released on exit. While
# the PID in a lock is alive, another run is refused. A lock whose PID is gone (a killed run) is taken over.
pr_lock() {
	local lock="${PR_STATE_DIR:?}/lock" pid
	mkdir -p "$PR_STATE_DIR" || return 1
	if ! mkdir "$lock" 2>/dev/null; then
		pid=$(cat "$lock/pid" 2>/dev/null || true)
		if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
			echo "Error: another review of this PR is running (pid $pid). Lock: $lock" >&2
			return 1
		fi
		echo "Note: taking over the lock of a run that is gone (pid ${pid:-unknown}): $lock" >&2
		rm -rf "$lock"
		mkdir "$lock" 2>/dev/null || {
			echo "Error: could not take the lock: $lock" >&2
			return 1
		}
	fi
	echo "$$" >"$lock/pid"
	trap pr_unlock EXIT
}

# Releases the PR's lock when this process holds it.
pr_unlock() {
	local lock="${PR_STATE_DIR:?}/lock"
	[[ "$(cat "$lock/pid" 2>/dev/null)" == "$$" ]] || return 0
	rm -rf "$lock"
}

# Prints the value of <key> in <PR_STATE_DIR>/pr.json (a string raw), or nothing when it is not there. An invalid
# file is an error that names it.
pr_json_get() { # <key>
	local file="${PR_STATE_DIR:?}/pr.json"
	[[ -e "$file" ]] || return 0
	jq -er --arg k "$1" 'if type == "object" then .[$k] | select(. != null) else error end' "$file" 2>/dev/null ||
		jq -e 'type == "object"' "$file" >/dev/null 2>&1 || {
		echo "Error: invalid PR state file: $file" >&2
		return 1
	}
}

# Sets <key> to the string <value> in <PR_STATE_DIR>/pr.json, made when missing.
pr_json_set() { # <key> <value>
	local file="${PR_STATE_DIR:?}/pr.json" json='{}'
	mkdir -p "$PR_STATE_DIR" || return 1
	if [[ -e "$file" ]] && ! json=$(jq -ce 'if type == "object" then . else error end' "$file" 2>/dev/null); then
		echo "Error: invalid PR state file: $file" >&2
		return 1
	fi
	jq --arg k "$1" --arg v "$2" '.[$k] = $v' <<<"$json" >"$file.$$" && mv "$file.$$" "$file"
}

# Makes the run folder <PR_STATE_DIR>/run-<UTC time> and prints its path. The time is free among the run- and
# preview- folders (else it gets a suffix: -2, -3…), so the preview name the folder may take is free too.
run_dir_new() {
	local stamp name n=1
	stamp=$(date -u +%Y%m%dT%H%M%S)
	name=$stamp
	while [[ -e "$PR_STATE_DIR/run-$name" || -e "$PR_STATE_DIR/preview-$name" ]]; do
		n=$((n + 1))
		name="$stamp-$n"
	done
	mkdir -p "${PR_STATE_DIR:?}" && mkdir "$PR_STATE_DIR/run-$name" && echo "$PR_STATE_DIR/run-$name"
}

# Gives a finished run folder (run-<time>) its final name and prints its path: round-<K> after a post, or
# preview-<time> for a --no-post run. When that name is taken, or the rename fails, the folder keeps its name.
run_dir_finish() { # <run-dir> <K | preview>
	local target
	if [[ "$2" == preview ]]; then
		target="${1%/*}/preview-${1##*/run-}"
	else
		target="${1%/*}/round-$2"
	fi
	if [[ -e "$target" ]]; then
		echo "Warning: ${target} already exists; the run folder keeps its name." >&2
	elif mv "$1" "$target"; then
		echo "$target"
		return 0
	else
		echo "Warning: could not rename the run folder to ${target}." >&2
	fi
	echo "$1"
}

# Writes the loop check's diagnosis (loop_text) to <PR_STATE_DIR>/loop-check.md. A failure is a warning only.
loop_check_save() { # <decision-json>
	if ! mkdir -p "${PR_STATE_DIR:?}" || ! loop_text "$1" >"$PR_STATE_DIR/loop-check.md"; then
		echo "Warning: could not write $PR_STATE_DIR/loop-check.md" >&2
	fi
	return 0
}
