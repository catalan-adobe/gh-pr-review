#!/usr/bin/env bash
# Checks normalize_remote and find_clone with real git in a temp folder. No network: https://h/o/r.git
# points at a local bare repo through url.<path>.insteadOf.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
for lib in config state clones; do
	# shellcheck source=/dev/null
	source "$root/lib/$lib.sh"
done
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
t=$(cd "$t" && pwd -P)
export HOME="$t/home" XDG_STATE_HOME="$t/state" XDG_CONFIG_HOME="$t/config"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$t/remote.git.insteadOf" GIT_CONFIG_VALUE_0=https://h/o/r.git
unset XDG_CACHE_HOME GH_PR_REVIEW_STATE GIT_DIR GIT_WORK_TREE CLONE_OVERRIDE
mkdir -p "$HOME/repos" "$XDG_CONFIG_HOME/gh-pr-review"
fail=0

check() { # name got want
	if [[ "$2" == "$3" ]]; then echo "ok   $1"; else
		echo "FAIL $1: got '$2', want '$3'"
		fail=1
	fi
}

# find_clone in this shell (it sets globals); notes go to $t/notes.
pick() { # host owner repo
	find_clone "$@" 2>"$t/notes" && echo "$CLONE_KIND $CLONE_DIR" || echo "error"
}

# ── normalize_remote ──
for url in https://h/o/r https://h/o/r.git https://H/O/R.git/ http://user@h/o/r.git git@h:o/r git@h:o/r.git \
	h:o/r.git ssh://git@h/o/r ssh://git@h/o/r.git ssh://git@h:2222/o/r.git; do
	check "normalize_remote $url" "$(normalize_remote "$url" || true)" h/o/r
done
check "normalize_remote rejects a path" "$(normalize_remote /srv/r.git || echo none)" none
check "normalize_remote rejects a deeper path" "$(normalize_remote https://h/a/o/r.git || echo none)" none

# ── a bare "remote" and clones ──
git init -q -b main "$t/seed"
git -C "$t/seed" commit -q --allow-empty -m one
git -C "$t/seed" commit -q --allow-empty -m two
git init -q --bare -b main "$t/remote.git"
git -C "$t/remote.git" config uploadpack.allowFilter true
git -C "$t/seed" push -q "$t/remote.git" main

clone() { # dir [git clone options]
	git clone -q "${@:2}" https://h/o/r.git "$1"
}
fetched() { # dir YYYYMMDDhhmm
	touch -t "$2" "$1/.git/FETCH_HEAD"
}
clone "$HOME/repos/a/r"
fetched "$HOME/repos/a/r" 202001010000
clone "$HOME/repos/b/c/r2"
fetched "$HOME/repos/b/c/r2" 202101010000
clone "$HOME/repos/shallow" --depth 1
fetched "$HOME/repos/shallow" 203001010000
clone "$HOME/repos/partial" --filter=blob:none
fetched "$HOME/repos/partial" 203001010000
git init -q "$HOME/repos/other"
git -C "$HOME/repos/other" remote add origin https://h/o/other.git
mkdir -p "$HOME/repos/other/.git" && touch -t 203001010000 "$HOME/repos/other/.git/FETCH_HEAD"
clone "$HOME/repos/deep/node_modules/r"
fetched "$HOME/repos/deep/node_modules/r" 203001010000
clone "$HOME/repos/x.reviews/r"
fetched "$HOME/repos/x.reviews/r" 203001010000

check "scan: newest FETCH_HEAD wins" "$(pick h o r)" "scan $HOME/repos/b/c/r2"
check "scan: shallow clone skipped, with the reason" "$(grep -c "skipping $HOME/repos/shallow: shallow clone" "$t/notes")" 1
check "scan: partial clone skipped, with the reason" "$(grep -c "skipping $HOME/repos/partial: partial clone" "$t/notes")" 1
check "scan: the pick goes to clones.json" "$(jq -r '."h/o/r"' "$XDG_STATE_HOME/gh-pr-review/clones.json")" "$HOME/repos/b/c/r2"
check "scan: host, owner and repo are case-insensitive" "$(pick H O R)" "scan $HOME/repos/b/c/r2"

fetched "$HOME/repos/a/r" 202201010000
check "clones.json: kept while its remote matches" "$(pick h o r)" "scan $HOME/repos/b/c/r2"
git -C "$HOME/repos/b/c/r2" remote set-url origin https://h/o/other.git
check "clones.json: dropped when the remote no longer matches" "$(pick h o r)" "scan $HOME/repos/a/r"

# A clone whose matching remote is not origin (a fork setup).
clone "$HOME/repos/fork"
git -C "$HOME/repos/fork" remote rename origin upstream
git -C "$HOME/repos/fork" remote add origin git@h:me/r.git
fetched "$HOME/repos/fork" 202501010000
rm "$XDG_STATE_HOME/gh-pr-review/clones.json"
check "scan: matching remote not called origin" "$(pick h o r)" "scan $HOME/repos/fork"

# ── config ──
# shellcheck disable=SC2088 # a literal ~ in the config file
jq -n '{clones: {"H/O/R": "~/repos/a/r"}}' >"$XDG_CONFIG_HOME/gh-pr-review/config.json"
check "config: the clones entry wins" "$(pick h o r)" "config $HOME/repos/a/r"
jq -n '{clones: {"h/o/r": "~/repos/shallow"}}' >"$XDG_CONFIG_HOME/gh-pr-review/config.json"
check "config: a shallow entry is skipped" "$(pick h o r)" "scan $HOME/repos/fork"
check "config: the skip names the reason" "$(grep -c "skipping the configured clone $HOME/repos/shallow: shallow clone" "$t/notes")" 1
echo '{' >"$XDG_CONFIG_HOME/gh-pr-review/config.json"
check "config: an invalid file is an error" "$(pick h o r)" error
check "config: the error names the file" "$(grep -c "invalid config file: $XDG_CONFIG_HOME/gh-pr-review/config.json" "$t/notes")" 1

clone "$t/old-partial"
git -C "$t/old-partial" config extensions.partialClone origin
check "partial clone by extensions.partialClone (older git)" "$(clone_problem "$t/old-partial")" "partial clone"
check "a plain clone has no problem" "$(clone_problem "$HOME/repos/a/r")" ""
check "a missing folder is not a repo" "$(clone_problem "$t/nope")" "not a git repository"

# ── override ──
# shellcheck disable=SC2034 # read by find_clone
rm "$XDG_CONFIG_HOME/gh-pr-review/config.json"
CLONE_OVERRIDE="$HOME/repos/a/r/"
check "override wins" "$(pick h o r)" "override $HOME/repos/a/r"
export CLONE_OVERRIDE="$HOME/repos/shallow"
check "override: a shallow clone is an error" "$(pick h o r)" error
check "override: the error says why" "$(grep -c "shallow clone" "$t/notes")" 1
unset CLONE_OVERRIDE

# ── roots without a match: the cache clone ──
mkdir -p "$t/roots2/deep/node_modules" "$t/roots2/y.reviews"
git -C "$HOME/repos/a/r" worktree add -q --detach "$t/roots2/linked"
clone "$t/roots2/deep/node_modules/r"
clone "$t/roots2/y.reviews/r"
clone "$t/roots2/shallow" --depth 1
jq -n --arg r "$t/roots2" '{roots: [$r]}' >"$XDG_CONFIG_HOME/gh-pr-review/config.json"
rm "$XDG_STATE_HOME/gh-pr-review/clones.json"
cache="$HOME/.cache/gh-pr-review/clones/h/o/r"
check "no main clone in roots: the cache clone" "$(pick h o r)" "cache $cache"
check "cache clone is bare" "$(git -C "$cache" rev-parse --is-bare-repository)" true
check "cache clone has the remote's branches" "$(git -C "$cache" rev-parse main)" "$(git -C "$t/seed" rev-parse main)"
check "the shallow skip is noted before the fallback" "$(grep -c "skipping $t/roots2/shallow: shallow clone" "$t/notes")" 1
check "the cache clone is not remembered" "$(jq -r '."h/o/r" // "none"' "$XDG_STATE_HOME/gh-pr-review/clones.json" 2>/dev/null || echo none)" none
check "cache clone reused" "$(GIT_CONFIG_VALUE_0=https://nowhere/x.git pick h o r)" "cache $cache"
jq -n '{roots: ["~/nope"]}' >"$XDG_CONFIG_HOME/gh-pr-review/config.json"
check "missing root: the cache clone" "$(pick h o r)" "cache $cache"
exit "$fail"
