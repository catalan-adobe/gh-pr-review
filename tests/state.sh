#!/usr/bin/env bash
# Checks the config file (lib/config.sh) and the state folder (lib/state.sh): paths, the lock, pr.json and the
# run folder's names. Everything lives in a temporary HOME.
# shellcheck disable=SC2016 # lock_in runs its single-quoted commands in the locked process
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
LIB_DIR="$root/lib"
# shellcheck source=lib/config.sh
source "$root/lib/config.sh"
# shellcheck source=lib/state.sh
source "$root/lib/state.sh"
# shellcheck source=lib/loop.sh
source "$root/lib/loop.sh"
# The script must reach its end: Bash 3.2 can stop on an error inside an EXIT trap with status 0.
finished=false
trap '[[ $finished == true ]] || { echo "FAIL stopped before the end"; exit 1; }' EXIT
fail=0

eq() { # name got want
	if [[ "$2" == "$3" ]]; then echo "ok   $1"; else
		echo "FAIL $1: got '$2', want '$3'"
		fail=1
	fi
}

tmp=$(mktemp -d)
export HOME="$tmp/home"
unset XDG_CONFIG_HOME XDG_STATE_HOME GH_PR_REVIEW_STATE

# ── config ──
eq "config: no file, the default" "$(config_get '.roots[0]' repos)" repos
mkdir -p "$HOME/.config/gh-pr-review"
echo '{"roots": ["src"], "stale_days": 7, "loop": {"min_rounds": 3}, "off": false}' \
	>"$HOME/.config/gh-pr-review/config.json"
eq "config: a string" "$(config_get '.roots[0]' repos)" src
eq "config: a number" "$(config_get '.stale_days' 30)" "7"
eq "config: an object, compact" "$(config_get '.loop' '{}')" '{"min_rounds":3}'
eq "config: false is a value" "$(config_get '.off' true)" "false"
eq "config: a missing key, the default" "$(config_get '.clones' '{}')" "{}"
export XDG_CONFIG_HOME="$tmp/xdg-config"
eq "config: XDG_CONFIG_HOME wins" "$(config_get '.stale_days' 30)" "30"
mkdir -p "$XDG_CONFIG_HOME/gh-pr-review"
echo '{"stale_days": ' >"$XDG_CONFIG_HOME/gh-pr-review/config.json"
got=$(config_get '.stale_days' 30 2>&1) && rc=0 || rc=$?
eq "config: an invalid file is an error that names it" "$rc $got" \
	"1 Error: invalid config file (not one JSON value): $XDG_CONFIG_HOME/gh-pr-review/config.json"
: >"$XDG_CONFIG_HOME/gh-pr-review/config.json"
config_get '.stale_days' 30 >/dev/null 2>&1 && rc=0 || rc=$?
eq "config: an empty file is invalid" "$rc" 1
unset XDG_CONFIG_HOME

# ── paths ──
eq "state_root: the default" "$(state_root)" "$HOME/.local/state/gh-pr-review"
eq "state_root: XDG_STATE_HOME" "$(XDG_STATE_HOME=/x/state state_root)" "/x/state/gh-pr-review"
eq "state_root: GH_PR_REVIEW_STATE wins" "$(XDG_STATE_HOME=/x/state GH_PR_REVIEW_STATE=/y/prs state_root)" "/y/prs"
eq "pr_state_dir" "$(pr_state_dir github.com o r 42)" "$HOME/.local/state/gh-pr-review/github.com/o/r/42"
eq "pr_state_dir: with GH_PR_REVIEW_STATE" "$(GH_PR_REVIEW_STATE=/y/prs pr_state_dir h o r 1)" "/y/prs/h/o/r/1"
eq "pr_state_dir: host, owner and repo lowercased" "$(pr_state_dir GitHub.com Owner Repo 7)" \
	"$(pr_state_dir github.com owner repo 7)"
eq "pr_state_dir: lowercase" "$(GH_PR_REVIEW_STATE=/y pr_state_dir H.X MyOrg My-Repo 7)" "/y/h.x/myorg/my-repo/7"
for bad in .. . '' a/b; do
	pr_state_dir github.com "$bad" r 1 >/dev/null 2>&1 && rc=0 || rc=$?
	eq "pr_state_dir: refuses the owner '$bad'" "$rc" 1
done

# ── the lock ──
PR_STATE_DIR=$(pr_state_dir github.com o r 42)
lock_in() { # runs pr_lock in a new process that then runs <command>; prints its output and status
	PR_STATE_DIR="$PR_STATE_DIR" bash -c 'set -euo pipefail; LIB_DIR="$1/lib"; source "$1/lib/state.sh"
		pr_lock; eval "$2"' _ "$root" "$1" 2>&1 && echo "rc=0" || echo "rc=$?"
}
got=$(lock_in 'cat "$PR_STATE_DIR/lock/pid"; echo "$$"')
eq "lock: taken, with its PID" "$(sed -n 1p <<<"$got")" "$(sed -n 2p <<<"$got")"
eq "lock: released on exit" "$([[ -e "$PR_STATE_DIR/lock" ]] && echo there || echo gone)" gone
lock_in 'exit 3' >/dev/null
eq "lock: released on a failing exit" "$([[ -e "$PR_STATE_DIR/lock" ]] && echo there || echo gone)" gone
sleep 30 &
live=$!
mkdir -p "$PR_STATE_DIR/lock"
echo "$live" >"$PR_STATE_DIR/lock/pid"
eq "lock: refused while the PID lives" "$(lock_in 'echo ran')" \
	"Error: another review of this PR is running (pid $live). Lock: $PR_STATE_DIR/lock
rc=1"
eq "lock: a refused run leaves the lock alone" "$(cat "$PR_STATE_DIR/lock/pid")" "$live"
kill "$live"
wait "$live" 2>/dev/null || true
got=$(lock_in 'echo "held by $(cat "$PR_STATE_DIR/lock/pid") = $$"')
eq "lock: taken over after the PID is gone" "$(sed -n 1p <<<"$got")" \
	"Note: taking over the lock of a run that is gone (pid $live): $PR_STATE_DIR/lock"
[[ "$(sed -n 2p <<<"$got")" =~ ^held\ by\ ([0-9]+)\ =\ ([0-9]+)$ && ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" ]] &&
	ok=yes || ok=no
eq "lock: the new run holds it" "$ok $(sed -n 3p <<<"$got")" "yes rc=0"
mkdir -p "$PR_STATE_DIR/lock"
got=$(lock_in 'echo ran')
eq "lock: one without a PID is taken over" "$(sed -n 2,3p <<<"$got")" "ran
rc=0"
mkdir -p "$PR_STATE_DIR/lock"
echo "$$" >"$PR_STATE_DIR/lock/pid"
eq "lock: refused while the PID lives (this test's)" "$(lock_in 'echo ran' | tail -1)" "rc=1"
pr_unlock
eq "pr_unlock: releases its own lock" "$([[ -e "$PR_STATE_DIR/lock" ]] && echo there || echo gone)" gone
mkdir -p "$PR_STATE_DIR/lock"
echo 999999 >"$PR_STATE_DIR/lock/pid"
pr_unlock
eq "pr_unlock: leaves a lock it does not hold" "$(cat "$PR_STATE_DIR/lock/pid")" 999999
rm -rf "$PR_STATE_DIR/lock"

# ── pr.json ──
eq "pr_json_get: no file, nothing" "$(pr_json_get clone)" ""
pr_json_set clone "/repos/r"
pr_json_set worktree "/repos/r.reviews/h/42"
pr_json_set clone "/repos/r2"
eq "pr_json_get: a value" "$(pr_json_get clone)" "/repos/r2"
eq "pr_json_get: another value" "$(pr_json_get worktree)" "/repos/r.reviews/h/42"
eq "pr_json_get: a missing key, nothing" "$(pr_json_get head_branch)" ""
eq "pr_json_set: one object" "$(jq -c 'keys' "$PR_STATE_DIR/pr.json")" '["clone","worktree"]'
echo 'not json' >"$PR_STATE_DIR/pr.json"
got=$(pr_json_get clone 2>&1) && rc=0 || rc=$?
eq "pr_json_get: an invalid file is an error" "$rc $got" "1 Error: invalid PR state file: $PR_STATE_DIR/pr.json"
pr_json_set clone x 2>/dev/null && rc=0 || rc=$?
eq "pr_json_set: an invalid file is an error, left as it is" "$rc $(cat "$PR_STATE_DIR/pr.json")" "1 not json"

# ── run folders ──
run=$(run_dir_new)
[[ "$run" =~ ^$PR_STATE_DIR/run-[0-9]{8}T[0-9]{6}$ && -d "$run" ]] && ok=yes || ok=no
eq "run_dir_new: run-<UTC time>" "$ok" yes
# The same second for the next ones: a fixed clock.
date() { echo 20261126T091200; }
run=$(run_dir_new)
run2=$(run_dir_new)
eq "run_dir_new: a second one in the same second gets a suffix" "${run2#"$run"}" "-2"
eq "run_dir_finish: a post makes round-<K>" "$(run_dir_finish "$run2" 1)" "$PR_STATE_DIR/round-1"
got=$(run_dir_finish "$run" 1 2>&1)
eq "run_dir_finish: round-<K> taken, the run keeps its name" "$got" \
	"Warning: $PR_STATE_DIR/round-1 already exists; the run folder keeps its name.
$run"
eq "run_dir_finish: preview-<time>" "$(run_dir_finish "$run" preview 2>/dev/null)" "$PR_STATE_DIR/preview-${run##*/run-}"
run3=$(run_dir_new)
[[ "${run3##*/run-}" != "${run##*/run-}" ]] && ok=yes || ok=no
eq "run_dir_new: a time a preview has is not reused" "$ok" yes
unset -f date

# ── loop-check.md ──
loop_check_save "$(loop_decide_json '[]' '{}' new false)"
eq "loop_check_save: loop_text in loop-check.md" "$(sed -n 1p "$PR_STATE_DIR/loop-check.md")" "Loop check for round 1: run"

rm -rf "$tmp"
finished=true
exit "$fail"
