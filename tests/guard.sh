#!/usr/bin/env bash
# Checks the reviewer's git sandbox with real git in a temp folder: lib/git-ro, pi_env and the tripwire.
# Conditions are single-quoted on purpose: expect() evals them.
# shellcheck disable=SC2016,SC2034,SC2329 # SC2329: ro runs inside expect's eval
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/guard.sh
source "$root/lib/guard.sh"
# The script must reach its end: Bash 3.2 can stop on an error inside an EXIT trap with status 0.
finished=false
trap '[[ $finished == true ]] || { echo "FAIL stopped before the end"; exit 1; }' EXIT
fail=0

t=$(mktemp -d)
t=$(cd "$t" && pwd -P)
export HOME="$t/home" GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL=a@x GIT_COMMITTER_NAME=a \
	GIT_COMMITTER_EMAIL=a@x
mkdir -p "$HOME"
real=$(command -v git)

expect() { # name condition
	if eval "$2"; then echo "ok   $1"; else
		echo "FAIL $1 ($2)"
		fail=1
	fi
}

# The whole state of a repo the wrapper must not touch.
state() { # <repo>
	git -C "$1" for-each-ref
	git -C "$1" rev-parse HEAD
	git -C "$1" status --porcelain
	git -C "$1" stash list
	git -C "$1" worktree list
	git -C "$1" config --list --local
}

repo="$t/repo"
git init -q "$repo"
git -C "$repo" checkout -q -b main
for n in 1 2 3; do
	echo "$n" >"$repo/f"
	git -C "$repo" add f
	git -C "$repo" commit -qm "c$n"
done
git -C "$repo" branch side
git init -q --bare "$t/remote.git"
git -C "$repo" remote add origin "$t/remote.git"
echo dirty >"$repo/f"
pi_bin "$t/bin"

# ── git-ro ──
ro() { # git args... (through the wrapper on pi's PATH, from the repo)
	(cd "$repo" && pi_env "$t/bin" git "$@") >"$t/ro.out" 2>&1
}
for args in "log --oneline" "diff" "-C $repo show --stat" "-c core.quotepath=off status" "--version" \
	"range-diff HEAD~2 HEAD~1 HEAD" "--no-pager log -1" "rev-parse HEAD"; do
	expect "git-ro passes: $args" "ro $args"
done
before=$(state "$repo")
for args in "commit -qam x" "checkout -b evil" "branch -D side" "push origin main" "stash" "worktree add ../wt" \
	"fetch origin" "-C $repo reset --hard" "-c core.pager=cat --no-pager tag v1"; do
	sub=${args##*-pager }
	sub=${sub##*"$repo" }
	sub=${sub%% *}
	expect "git-ro refuses: $args" \
		"! ro $args && [[ \$(cat \"\$t/ro.out\") == 'git $sub is not allowed in a read-only review' ]]"
done
expect "git-ro: the repo is unchanged after the refused commands" '[[ "$(state "$repo")" == "$before" && ! -e "$t/wt" ]]'
expect "git-ro: nothing was pushed" '[[ -z "$(git -C "$t/remote.git" for-each-ref)" ]]'
expect "git-ro: an option where the subcommand goes is refused" '! ro --exec-path=/x status'
expect "git-ro: no real git, no run" \
	'! (cd "$repo" && GH_PR_REVIEW_REAL_GIT="" "$t/bin/git" log) >/dev/null 2>&1'

# ── pi_env ──
printf '[credential]\n\thelper = store\n' >"$HOME/.gitconfig"
echo "https://u:s3cret@example.com" >"$HOME/.git-credentials"
cred=$'protocol=https\nhost=example.com\n'
expect "pi_env: credentials are there outside it (control)" \
	'git credential fill <<<"$cred" 2>/dev/null | grep -q password=s3cret'
expect "pi_env: the real git's credential fill returns nothing" \
	'[[ -z "$(pi_env "$t/bin" bash -c "\"\$GH_PR_REVIEW_REAL_GIT\" credential fill" <<<"$cred" 2>/dev/null)" ]]'
rm "$HOME/.gitconfig" "$HOME/.git-credentials"
git init -q "$t/hooked"
printf '#!/bin/sh\ntouch "%s/hook.ran"\n' "$t" >"$t/hooked/.git/hooks/pre-commit"
chmod +x "$t/hooked/.git/hooks/pre-commit"
# shellcheck disable=SC2016 # expanded by the inner shell, where pi_env set it
pi_env "$t/bin" bash -c 'cd "$1" && "$GH_PR_REVIEW_REAL_GIT" commit -q --allow-empty -m h' _ "$t/hooked"
expect "pi_env: a hook does not run" '[[ ! -e "$t/hook.ran" ]]'
git -C "$t/hooked" commit -q --allow-empty -m h
expect "pi_env: the hook runs outside it (control)" '[[ -e "$t/hook.ran" ]]'
expect "pi_env: the wrapper is git on PATH" '[[ "$(pi_env "$t/bin" bash -c "command -v git")" == "$t/bin/git" ]]'
expect "pi_env: real git is the git outside it" '[[ "$(pi_env "$t/bin" printenv GH_PR_REVIEW_REAL_GIT)" == "$real" ]]'

# ── tripwire ──
git -C "$repo" checkout -q -- f
git -C "$repo" worktree add -q --detach "$t/review" main
snap() { tripwire_snapshot "$repo" "$t/review" "$t/snap$1"; }
check() { # before after
	rc=0
	tripwire_check "$t/snap$1" "$t/snap$2" >"$t/check.out" 2>&1 || rc=$?
}
snap 1
snap 2
check 1 2
expect "tripwire: no change gives 0, quietly" '[[ $rc == 0 && ! -s "$t/check.out" ]]'
git -C "$repo" update-ref refs/pr-review/1/round-1 HEAD
snap 3
check 2 3
expect "tripwire: refs/pr-review/ is not watched" '[[ $rc == 0 && ! -s "$t/check.out" ]]'
git -C "$t/review" commit -q --allow-empty -m x
snap 4
check 3 4
expect "tripwire: a commit in the worktree gives 4, with the diff" \
	'[[ $rc == 4 ]] && grep -q "review worktree" "$t/check.out" && grep -q "^+HEAD" "$t/check.out"'
git -C "$repo" branch newb
snap 5
check 4 5
expect "tripwire: a new branch in the clone gives 0, with a warning" \
	'[[ $rc == 0 ]] && grep -q "^Warning" "$t/check.out" && grep -q "refs/heads/newb" "$t/check.out"'
touch "$t/review/new-file"
snap 6
check 5 6
expect "tripwire: a new file in the worktree gives 4" '[[ $rc == 4 ]] && grep -q "new-file" "$t/check.out"'
rm "$t/review/new-file"
git -C "$t/review" checkout -q -b evil
snap 7
check 5 7
expect "tripwire: a branch checked out in the worktree gives 4" '[[ $rc == 4 ]]'

finished=true
exit "$fail"
