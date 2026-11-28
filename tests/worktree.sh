#!/usr/bin/env bash
# Checks fetch_pr, branch_slug, review_worktree, mark_round, round_shas and fresh_checkout with real git. No network:
# https://h/o/r.git points at a local bare repo through url.<path>.insteadOf.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
for lib in config state clones worktree delta; do
	# shellcheck source=/dev/null
	source "$root/lib/$lib.sh"
done
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
t=$(cd "$t" && pwd -P)
export HOME="$t/home" XDG_STATE_HOME="$t/state" XDG_CONFIG_HOME="$t/config"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$t/remote.git.insteadOf" GIT_CONFIG_VALUE_0=https://h/o/r.git
unset GH_PR_REVIEW_STATE GIT_DIR GIT_WORK_TREE GH_USER DELTA_REMOTE
mkdir -p "$HOME"
url=https://h/o/r.git
fail=0

check() { # name got want
	if [[ "$2" == "$3" ]]; then echo "ok   $1"; else
		echo "FAIL $1: got '$2', want '$3'"
		fail=1
	fi
}

# ── slugs ──
long=$(printf 'a%.0s' $(seq 200))
check "slug feat/x" "$(branch_slug feat/x)" feat-x
check "slug main" "$(branch_slug main)" main
check "slug 200 characters" "$(branch_slug "$long")" "${long:0:60}"
check "slug cut before a separator" "$(branch_slug "${long:0:59}/b")" "${long:0:59}"
check "slug spaces and unicode" "$(branch_slug 'my branch ünïcode/π')" my-branch-n-code
check "slug runs and edges" "$(branch_slug '--feat//x--y-')" feat-x-y
check "slug no hidden folder" "$(branch_slug ../.x)" x
check "slug empty" "$(branch_slug '///')" pr

# ── a remote with refs/pull/7/head, and my clone ──
seed="$t/seed"
git init -q -b main "$seed"
echo one >"$seed/f"
git -C "$seed" add f
git -C "$seed" commit -q -m one
git -C "$seed" checkout -q -b feat/x
echo two >>"$seed/f"
git -C "$seed" commit -q -am two
git -C "$seed" checkout -q main
git init -q --bare -b main "$t/remote.git"
git -C "$seed" push -q "$t/remote.git" main feat/x feat/x:refs/pull/7/head feat/x:refs/pull/8/head
head1=$(git -C "$seed" rev-parse feat/x)
base1=$(git -C "$seed" rev-parse main)

clone="$t/repos/r"
git clone -q "$url" "$clone"
git -C "$clone" branch -q mine
echo local >"$clone/scratch"
mkdir -p "$clone/.git/hooks"
printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$t" >"$clone/.git/hooks/post-checkout"
chmod +x "$clone/.git/hooks/post-checkout"
snapshot() { # the state of my clone that the review must not change
	git -C "$clone" for-each-ref --format='%(refname) %(objectname)' | grep -v '^refs/pr-review/' || true
	git -C "$clone" symbolic-ref HEAD
	git -C "$clone" status --porcelain
	git -C "$clone" config --local --list
	git -C "$clone" stash list
	ls "$clone/.git/FETCH_HEAD" 2>/dev/null || true
}
before=$(snapshot)

# ── round 1 ──
PR_STATE_DIR="$t/state/h/o/r/7"
fetch_pr "$clone" "$url" 7 main
check "fetch: refs/pr-review/7/head" "$(git -C "$clone" rev-parse refs/pr-review/7/head)" "$head1"
check "fetch: refs/pr-review/7/base" "$(git -C "$clone" rev-parse refs/pr-review/7/base)" "$base1"
check "fetch: no tags, no FETCH_HEAD" "$(
	git -C "$clone" tag
	ls "$clone/.git/FETCH_HEAD" 2>/dev/null || true
)" ""
review_worktree "$clone" 7 feat/x "$head1" 2>"$t/err"
wt="$t/repos/r.reviews/feat-x/7"
check "round 1: the worktree path" "$WORKTREE_DIR" "$wt"
check "round 1: detached at the PR head" "$(git -C "$wt" rev-parse HEAD) $(git -C "$wt" symbolic-ref -q HEAD || echo detached)" "$head1 detached"
check "round 1: the files are there" "$(cat "$wt/f")" $'one\ntwo'
check "round 1: no warning" "$(cat "$t/err")" ""
check "round 1: my clone is unchanged" "$(snapshot)" "$before"
check "round 1: pr.json" "$(jq -c '[.clone, .worktree, .head_branch, .user]' "$PR_STATE_DIR/pr.json")" \
	"$(jq -nc --arg c "$clone" --arg w "$wt" '[$c, $w, "feat/x", ""]')"
check "review_base" "$(review_base "$wt" 7)" "$base1"
mark_round "$clone" 7 1 "$head1"
check "mark_round: refuses a name for a commit" "$(mark_round "$clone" 7 2 HEAD 2>&1 >/dev/null | grep -c 'not a PR number')" 1
check "mark_round: refuses a round that is not a number" "$(mark_round "$clone" 7 '../x' "$head1" 2>/dev/null || echo refused)" refused
check "mark_round: round-1" "$(git -C "$clone" rev-parse refs/pr-review/7/round-1)" "$head1"
check "mark_round: round-1-base" "$(git -C "$clone" rev-parse refs/pr-review/7/round-1-base)" "$base1"

# ── force-push, round 2 ──
git -C "$seed" commit -q --allow-empty -m main2
git -C "$seed" checkout -q feat/x
git -C "$seed" rebase -q main
git -C "$seed" commit -q --amend -m two-again
git -C "$seed" checkout -q main
git -C "$seed" push -q -f "$t/remote.git" main feat/x:refs/pull/7/head
head2=$(git -C "$seed" rev-parse feat/x)
base2=$(git -C "$seed" rev-parse main)
fetch_pr "$clone" "$url" 7 main
git -C "$clone" -c gc.reflogExpire=now -c gc.reflogExpireUnreachable=now gc -q --prune=now
check "force-push: head moved" "$(git -C "$clone" rev-parse refs/pr-review/7/head)" "$head2"
check "force-push: round-1 keeps the old head" "$(git -C "$clone" rev-parse 'refs/pr-review/7/round-1^{commit}')" "$head1"
check "force-push: round-1-base keeps the old base" "$(git -C "$clone" rev-parse 'refs/pr-review/7/round-1-base^{commit}')" "$base1"
review_worktree "$clone" 7 feat/x "$head2" 2>"$t/err"
check "round 2: the same folder" "$WORKTREE_DIR" "$wt"
check "round 2: moved to the new head" "$(git -C "$wt" rev-parse HEAD)" "$head2"
check "round 2: no warning" "$(cat "$t/err")" ""
# A record without a base (read back from its Markdown) is full under #9's rule; the round refs make it rebased.
check "force-push: without the refs, no base is full" "$(pick_delta "$wt" "$head1" "" "$head2" "$base2" | jq -r .mode)" full
prev=$(round_shas "$wt" 7 1 "$head1" "")
check "round_shas: the refs, the base from round-1-base" "$prev" "$head1"$'\n'"$base1"
check "round_shas: no ref, the record" "$(round_shas "$wt" 7 5 "$head2" x)" "$head2"$'\nx'
check "round_shas: a ref that disagrees with the record, the record" "$(round_shas "$wt" 7 1 "$head2" x)" "$head2"$'\nx'
check "round_shas: a round that is not a number, the record" "$(round_shas "$wt" 7 '1/../1' "" y)" $'\ny'
delta=$(DELTA_REMOTE=$url pick_delta "$wt" "$(sed -n 1p <<<"$prev")" "$(sed -n 2p <<<"$prev")" "$head2" "$(review_base "$wt" 7)")
check "force-push: pick_delta is rebased, not full" "$(jq -r .mode <<<"$delta")" rebased

# ── a dirty worktree, and a renamed branch ──
echo junk >>"$wt/f"
mkdir -p "$wt/new"
echo x >"$wt/new/untracked"
review_worktree "$clone" 7 feat/renamed "$head2" 2>"$t/err"
check "dirty: reset" "$(git -C "$wt" status --porcelain)" ""
check "dirty: untracked files removed" "$([[ -e "$wt/new" ]] && echo there || echo gone)" gone
check "dirty: a warning that names the folder" "$(grep -c "review worktree was dirty; resetting it: $wt" "$t/err")" 1
check "renamed branch: the worktree from pr.json" "$WORKTREE_DIR" "$wt"
check "renamed branch: pr.json head_branch" "$(PR_STATE_DIR="$PR_STATE_DIR" pr_json_get head_branch)" feat/renamed

# ── my own PR: its branch is checked out in my clone ──
git -C "$clone" -c core.hooksPath=/dev/null checkout -q -b feat/x origin/feat/x
before=$(snapshot)
PR_STATE_DIR="$t/state/h/o/r/8"
fetch_pr "$clone" "$url" 8 main
review_worktree "$clone" 8 feat/x "$(git -C "$clone" rev-parse refs/pr-review/8/head)" 2>"$t/err"
check "own PR: worktree made" "$WORKTREE_DIR" "$t/repos/r.reviews/feat-x/8"
check "own PR: detached at the branch head" "$(git -C "$WORKTREE_DIR" rev-parse HEAD)" "$head1"
check "own PR: my clone is unchanged" "$(snapshot)" "$before"

# ── head branch main on a fork ──
PR_STATE_DIR="$t/state/h/o/r/10"
review_worktree "$clone" 10 main "$head1" 2>"$t/err"
check "fork main: path" "$WORKTREE_DIR" "$t/repos/r.reviews/main/10"

# ── a 200-character head branch with spaces and unicode ──
PR_STATE_DIR="$t/state/h/o/r/11"
review_worktree "$clone" 11 "$long/ünï cödé" "$head1" 2>"$t/err"
check "long unicode branch: path" "$WORKTREE_DIR" "$t/repos/r.reviews/${long:0:60}/11"
check "long unicode branch: pr.json keeps the name" "$(pr_json_get head_branch)" "$long/ünï cödé"
check "a name is not a commit ID" "$(review_worktree "$clone" 11 x HEAD 2>&1 | grep -c 'not a commit ID')" 1

# ── a folder in the way ──
PR_STATE_DIR="$t/state/h/o/r/9"
mkdir -p "$t/repos/r.reviews/stray/9"
echo keep >"$t/repos/r.reviews/stray/9/mine.txt"
review_worktree "$clone" 9 stray "$head1" 2>"$t/err" && rc=0 || rc=$?
check "in the way: fails" "$rc" 1
check "in the way: names the path" "$(grep -c "$t/repos/r.reviews/stray/9 is in the way" "$t/err")" 1
check "in the way: left in place" "$(cat "$t/repos/r.reviews/stray/9/mine.txt")" keep

# ── a deleted worktree folder is made again ──
PR_STATE_DIR="$t/state/h/o/r/10"
rm -rf "$t/repos/r.reviews/main/10"
review_worktree "$clone" 10 main "$head2" 2>"$t/err"
check "deleted worktree: made again" "$(git -C "$WORKTREE_DIR" rev-parse HEAD)" "$head2"

check "hooks never ran" "$([[ -e "$t/hook-ran" ]] && echo ran || echo no)" no
git -C "$clone" worktree add -q --detach "$t/control" HEAD
check "control: plain git runs the hook" "$([[ -e "$t/hook-ran" ]] && echo ran || echo no)" ran

# ── fetch errors ──
git -C "$clone" update-ref refs/pr-review/7/head "$head1"
mkdir -p "$clone/.git/refs/pr-review/7"
touch "$clone/.git/refs/pr-review/7/head.lock"
fetch_pr "$clone" "$url" 7 main 2>"$t/err" && rc=0 || rc=$?
check "fetch: a ref lock that stays fails" "$rc:$(grep -q lock "$t/err" && echo lock)" 1:lock
(
	sleep 0.3
	rm -f "$clone/.git/refs/pr-review/7/head.lock"
) &
fetch_pr "$clone" "$url" 7 main 2>"$t/err" && rc=0 || rc=$?
wait
check "fetch: a ref lock is retried" "$rc:$(git -C "$clone" rev-parse refs/pr-review/7/head)" "0:$head2"
fetch_pr "$clone" "$url" 99 main 2>"$t/err" && rc=0 || rc=$?
check "fetch: a missing PR fails" "$rc" 1
check "fetch: the error names the PR" "$(grep -c 'could not fetch PR #99' "$t/err")" 1

check "my clone is unchanged after every step" "$(snapshot)" "$before"

# ── --fresh ──
fresh_checkout "$t/fresh" "$url" 7 main
check "fresh: detached at the PR head" "$(git -C "$t/fresh" rev-parse HEAD) $(git -C "$t/fresh" symbolic-ref -q HEAD || echo detached)" "$head2 detached"
check "fresh: refs/pr-review/7/base" "$(git -C "$t/fresh" rev-parse refs/pr-review/7/base)" "$base2"
check "fresh: review_base" "$(review_base "$t/fresh" 7)" "$base2"
check "fresh: no .reviews folder" "$([[ -e "$t/fresh.reviews" ]] && echo there || echo none)" none
exit "$fail"
