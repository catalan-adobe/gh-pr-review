#!/usr/bin/env bash
# Picks how to show what changed since the last round (pick_delta, changed_files), with real git on local repos.
# A bare repo plays GitHub: `https://h/o/r.git` points at it through GIT_CONFIG_COUNT, so nothing uses the network.
# HOME, XDG_CONFIG_HOME, the global and the system git config are isolated from the user's.
# Conditions are single-quoted on purpose: expect() evals them after each case sets out (and files).
# SC2034: GIT_AUTH is read by the sourced pick_delta. SC2329: has runs inside expect's eval.
# SC2030/SC2031: the cases that break the remote URL do it in a subshell on purpose.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2329
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG \
	GIT_CONFIG_PARAMETERS GIT_CEILING_DIRECTORIES GIT_AUTH
mkdir -p "$tmp/home"
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$tmp/home/.gitconfig"
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
export GIT_TERMINAL_PROMPT=0
remote="$tmp/remote.git"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$remote.insteadOf" GIT_CONFIG_VALUE_0="https://h/o/r.git"
# Points every https://h/ URL at a folder that does not exist: a fetch through it fails, locally.
broken_key="url.file://$tmp/nowhere/.insteadOf" broken_value="https://h/"

# shellcheck source=lib/delta.sh
source "$root/lib/delta.sh"

expect() { # name condition
	if eval "$2"; then echo "ok   $1"; else
		echo "FAIL $1 ($2)"
		printf '%s\n' "$out" | sed 's/^/     | /'
		fail=1
	fi
}

world() { # a fresh "GitHub" remote and the author's repo, on main
	rm -rf "$remote" "$tmp/src"
	git init --quiet --bare -b main "$remote"
	# GitHub serves a commit by SHA as long as it still has the object, even after a force-push.
	git -C "$remote" config uploadpack.allowAnySHA1InWant true
	git init --quiet -b main "$tmp/src"
	git -C "$tmp/src" remote add origin "$remote"
}

src() { git -C "$tmp/src" "$@"; }

commit() { # <message> <file=content>...: writes the files and commits them
	local message=$1 pair
	shift
	for pair in "$@"; do printf '%s\n' "${pair#*=}" >"$tmp/src/${pair%%=*}"; done
	src add -A
	src commit --quiet -m "$message"
}

publish() { # pushes main and the PR branch, as GitHub keeps refs/pull/1/head
	src push --quiet --force origin main feature feature:refs/pull/1/head
}

checkout() { # <depth>: the review checkout, as gh-pr-review clones it. Prints its path.
	local dir
	dir=$(mktemp -d "$tmp/checkout-XXXXX")/repo
	git clone --depth "$1" --quiet https://h/o/r.git "$dir"
	git -C "$dir" fetch origin pull/1/head:pr-branch --depth "$1" --quiet
	git -C "$dir" fetch origin main:refs/remotes/origin/main --depth "$1" --quiet
	printf '%s\n' "$dir"
}

has() { git -C "$1" cat-file -e "${2}^{commit}" 2>/dev/null; } # <repo> <sha>

ten=$(printf 'line %s\n' 1 2 3 4 5 6 7 8 9 10)
ten_changed=${ten/line 8/LINE 8}

# ── sourcing ─────────────────────────────────────────────────────────────────
out=$(bash -c 'before=$(set -o; shopt); source "$1"; [[ $(set -o; shopt) == "$before" ]] && echo same' _ \
	"$root/lib/delta.sh")
expect "source: defines functions only (no output, no options)" '[[ $out == same ]]'

# ── incremental: a plain new commit ──────────────────────────────────────────
world
commit m1 "a.txt=$ten"
src checkout --quiet -b feature
commit f1 b.txt=one
publish
prev_head=$(src rev-parse HEAD) prev_base=$(src rev-parse main)
commit f2 b.txt=two e.txt=new
publish
repo=$(checkout 50)
head=$(git -C "$repo" rev-parse pr-branch)
base=$(git -C "$repo" merge-base pr-branch origin/main)
out=$(pick_delta "$repo" "$prev_head" "$prev_base" "$head" "$base")
expect "incremental: stdout is one JSON line" '[[ $(wc -l <<<"$out") -eq 1 ]] && jq -e . <<<"$out" >/dev/null'
expect "incremental: mode" '[[ $(jq -r .mode <<<"$out") == incremental ]]'
expect "incremental: reason" '[[ $(jq -r .reason <<<"$out") == "previous head is an ancestor of the head" ]]'
expect "incremental: diff --stat and diff, full SHAs" \
	'[[ $(jq -c .commands <<<"$out") == "[\"git diff --stat $prev_head..$head\",\"git diff $prev_head..$head\"]" ]]'
expect "incremental: SHA fields" \
	'[[ $(jq -r "[.prev_head, .prev_base, .head, .base] | join(\" \")" <<<"$out") == "$prev_head $prev_base $head $base" ]]'
files=$(changed_files "$repo" "$out")
expect "incremental: changed_files" '[[ $files == "b.txt"$'"'\n'"'"e.txt" ]]'
out=$(pick_delta "$repo" "$head" "$base" "$head" "$base")
expect "incremental: same head says so" \
	'[[ $(jq -r .mode,.reason <<<"$out" | paste -sd, -) == "incremental,no new commits since the previous round" ]]'

# ── incremental: the author merged the base branch in ────────────────────────
world
commit m1 "a.txt=$ten"
src checkout --quiet -b feature
commit f1 b.txt=one
publish
prev_head=$(src rev-parse HEAD) prev_base=$(src rev-parse main)
src checkout --quiet main
commit m2 c.txt=from-main "a.txt=$ten_changed"
src checkout --quiet feature
src merge --quiet --no-edit main
commit f2 b.txt=two
publish
repo=$(checkout 50)
head=$(git -C "$repo" rev-parse pr-branch)
base=$(git -C "$repo" merge-base pr-branch origin/main)
out=$(pick_delta "$repo" "$prev_head" "$prev_base" "$head" "$base")
from=$(jq -r '.from // ""' <<<"$out")
expect "base merged in: incremental, from the previous head merged onto the new base" \
	'[[ $(jq -r .mode <<<"$out") == incremental && -n $from && $(jq -r .reason <<<"$out") == "the base branch was merged in"* ]]'
expect "base merged in: the diff starts from that tree" \
	'[[ $(jq -c .commands <<<"$out") == "[\"git diff --stat $from $head\",\"git diff $from $head\"]" ]]'
expect "base merged in: the diff holds the author's change only" \
	'[[ $(git -C "$repo" diff --name-only "$from" "$head") == b.txt ]]'
files=$(changed_files "$repo" "$out")
expect "base merged in: changed_files leaves out what the base brought" '[[ $files == b.txt ]]'

world
commit m1 "a.txt=$ten"
src checkout --quiet -b feature
commit f1 "a.txt=$ten_changed"
publish
prev_head=$(src rev-parse HEAD) prev_base=$(src rev-parse main)
src checkout --quiet main
commit m2 "a.txt=${ten/line 8/main 8}"
src checkout --quiet feature
src merge --quiet --no-edit main >/dev/null 2>&1 || true
commit f2 "a.txt=${ten/line 8/both 8}"
publish
repo=$(checkout 50)
head=$(git -C "$repo" rev-parse pr-branch)
base=$(git -C "$repo" merge-base pr-branch origin/main)
out=$(pick_delta "$repo" "$prev_head" "$prev_base" "$head" "$base")
expect "base merged in with conflicts: a range-diff, and it says why" \
	'[[ $(jq -r .mode,.reason <<<"$out" | paste -sd, -) == "rebased,the base branch was merged in with conflicts" ]] && [[ $(jq -r ".commands[0]" <<<"$out") == "git range-diff "* ]]'

# ── rebased: onto a moved base, with a changed patch ─────────────────────────
world
commit m1 "a.txt=$ten" c.txt=c1
src checkout --quiet -b feature
commit f1 "a.txt=$ten_changed"
commit f2 b.txt=old g.txt=dropped-later
publish
prev_head=$(src rev-parse HEAD) prev_base=$(src rev-parse main)
# The base moves: lines above the PR's change in a.txt (new hunk line numbers, same patch), and c.txt.
src checkout --quiet main
commit m2 "a.txt=top"$'\n'"$ten" c.txt=c2
# The author redoes the PR on the new base: same a.txt change, b.txt changed, d.txt new, g.txt gone.
src checkout --quiet -B feature main
commit f1 "a.txt=top"$'\n'"$ten_changed"
commit f2 b.txt=new d.txt=added
publish
repo=$(checkout 50)
head=$(git -C "$repo" rev-parse pr-branch)
base=$(git -C "$repo" merge-base pr-branch origin/main)
expect "rebased: setup, the old head is not in the checkout" '! has "$repo" "$prev_head"'
out=$(pick_delta "$repo" "$prev_head" "$prev_base" "$head" "$base")
expect "rebased: stdout is one JSON line" '[[ $(wc -l <<<"$out") -eq 1 ]] && jq -e . <<<"$out" >/dev/null'
expect "rebased: mode" '[[ $(jq -r .mode <<<"$out") == rebased ]]'
expect "rebased: range-diff of the two ranges" \
	'[[ $(jq -c .commands <<<"$out") == "[\"git range-diff $prev_base..$prev_head $base..$head\"]" ]]'
expect "rebased: the old head was fetched" 'has "$repo" "$prev_head"'
files=$(changed_files "$repo" "$out")
expect "rebased: changed_files, the changed, new and dropped files only" \
	'[[ $files == "b.txt"$'"'\n'"'"d.txt"$'"'\n'"'"g.txt" ]]'
out=$(pick_delta "$repo" "$prev_head" "" "$head" "$base")
expect "rebased: no previous base is full" \
	'[[ $(jq -r .mode,.reason <<<"$out" | paste -sd, -) == "full,previous base unknown" ]]'
# A git that fails on range-diff only: the round falls back to full and says why.
real_git=$(command -v git)
mkdir -p "$tmp/bin"
cat >"$tmp/bin/git" <<S
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == range-diff ]] && exit 1; done
exec "$real_git" "\$@"
S
chmod +x "$tmp/bin/git"
out=$(
	PATH="$tmp/bin:$PATH"
	pick_delta "$repo" "$prev_head" "$prev_base" "$head" "$base"
)
expect "rebased: range-diff failing falls back to full" \
	'[[ $(jq -r .mode <<<"$out") == full && $(jq -r .reason <<<"$out") == "range-diff failed on "* ]]'
files=$(changed_files "$repo" "$out")
expect "full: changed_files is empty" '[[ -z $files ]]'

# ── full: force-push to unrelated history, the old head gone from the remote ─
world
commit m1 "a.txt=$ten"
src checkout --quiet -b feature
commit f1 b.txt=old
publish
prev_head=$(src rev-parse HEAD) prev_base=$(src rev-parse main)
src checkout --quiet -B feature main
commit g1 z.txt=other
publish
git -C "$remote" reflog expire --expire=now --all
git -C "$remote" gc --quiet --prune=now
out=''
expect "force-push: setup, the remote lost the old head" '! has "$remote" "$prev_head"'
repo=$(checkout 50)
head=$(git -C "$repo" rev-parse pr-branch)
base=$(git -C "$repo" merge-base pr-branch origin/main)
out=$(pick_delta "$repo" "$prev_head" "$prev_base" "$head" "$base")
expect "force-push: full, with the reason" \
	'[[ $(jq -r .mode,.reason <<<"$out" | paste -sd, -) == "full,previous head ${prev_head:0:12} not found after fetch" ]]'
expect "force-push: no commands" '[[ $(jq -c .commands <<<"$out") == "[]" ]]'
files=$(changed_files "$repo" "$out")
expect "force-push: changed_files is empty" '[[ -z $files ]]'

# ── full: no previous round ──────────────────────────────────────────────────
out=$(pick_delta "$repo" "" "" "$head" "$base")
expect "no previous round: full" \
	'[[ $(jq -r .mode,.reason <<<"$out" | paste -sd, -) == "full,no previous round" ]]'
expect "no previous round: no commands" '[[ $(jq -c .commands <<<"$out") == "[]" ]]'

# ── shallow: the previous head is older than the depth but still on the remote ─
world
commit m1 "a.txt=$ten"
src checkout --quiet -b feature
commit f1 s1.txt=1
commit f2 s2.txt=2
publish
prev_head=$(src rev-parse HEAD) prev_base=$(src rev-parse main)
for i in 3 4 5 6 7 8; do commit "f$i" "s$i.txt=$i"; done
publish
head=$(src rev-parse feature)
# The merge-base sits below the shallow boundary too, so the base is given, as an earlier run would have found it.
base=$prev_base
repo=$(checkout 3)
out=''
expect "shallow: setup, the previous head is not in the checkout" '! has "$repo" "$prev_head"'
out=$(pick_delta "$repo" "$prev_head" "$prev_base" "$head" "$base")
expect "shallow: incremental after the fetch (GIT_AUTH unset)" \
	'[[ $(jq -r .mode <<<"$out") == incremental && $(jq -r ".commands[1]" <<<"$out") == "git diff $prev_head..$head" ]]'
files=$(changed_files "$repo" "$out")
expect "shallow: changed_files" '[[ $(paste -sd, - <<<"$files") == "s3.txt,s4.txt,s5.txt,s6.txt,s7.txt,s8.txt" ]]'
# Only GIT_AUTH knows where the remote is: the fetch works only if pick_delta passes it to git.
repo=$(checkout 3)
out=$(
	export GIT_CONFIG_KEY_0="$broken_key" GIT_CONFIG_VALUE_0="$broken_value"
	GIT_AUTH=(-c credential.helper= -c "url.file://$remote.insteadOf=https://h/o/r.git")
	pick_delta "$repo" "$prev_head" "$prev_base" "$head" "$base"
)
expect "shallow: incremental with GIT_AUTH set (it reaches git)" '[[ $(jq -r .mode <<<"$out") == incremental ]]'
# Same, without GIT_AUTH: the fetch fails, and the round is full.
repo=$(checkout 3)
out=$(
	export GIT_CONFIG_KEY_0="$broken_key" GIT_CONFIG_VALUE_0="$broken_value"
	pick_delta "$repo" "$prev_head" "$prev_base" "$head" "$base"
)
expect "shallow: the fetch failing is full, quietly" \
	'[[ $(jq -r .mode,.reason <<<"$out" | paste -sd, -) == "full,previous head ${prev_head:0:12} not found after fetch" ]]'

exit "$fail"
