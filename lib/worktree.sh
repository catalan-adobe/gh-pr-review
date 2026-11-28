#!/usr/bin/env bash
# Private refs per PR and the review worktree next to the clone. Functions only.
# Uses rgit and rgit_net (lib/clones.sh), pr_json_get and pr_json_set (lib/state.sh) and delta_object_id (lib/delta.sh).

# Fetches the PR head and its base branch into refs/pr-review/<N>/head and …/base. It never touches the clone's
# branches, remote-tracking refs, tags, FETCH_HEAD or submodules. A failure on a ref lock is retried once.
fetch_pr() { # <clone> <url> <N> <base-branch> [<depth>]
	local depth=() err try
	if [[ ! "$3" =~ ^[0-9]+$ ]] || ! git check-ref-format "refs/heads/$4"; then
		echo "Error: not a PR number and base branch: '$3' '$4'" >&2
		return 1
	fi
	[[ -n "${5:-}" ]] && depth=(--depth "$5")
	for try in 1 2; do
		if err=$(rgit_net -C "$1" fetch --quiet --no-tags --no-write-fetch-head --recurse-submodules=no \
			${depth[@]+"${depth[@]}"} --end-of-options "$2" \
			"+refs/pull/$3/head:refs/pr-review/$3/head" "+refs/heads/$4:refs/pr-review/$3/base" 2>&1); then
			return 0
		fi
		[[ "$try" == 1 && "$err" == *lock* ]] || break
		sleep 1
	done
	printf '%s\n' "$err" >&2
	echo "Error: could not fetch PR #$3 and $4 from $2" >&2
	return 1
}

# A folder name for a head branch: [A-Za-z0-9._-] only, no runs of "-", no leading "-" or ".", at most 60
# characters, and "pr" when nothing is left.
branch_slug() { # <name>
	local s
	s=$(printf '%s\n' "$1" | LC_ALL=C sed -e 's/[^A-Za-z0-9._-]/-/g' -e 's/--*/-/g' -e 's/^[-.]*//')
	s=${s:0:60}
	while [[ "$s" == *- ]]; do s=${s%-}; done
	printf '%s\n' "${s:-pr}"
}

# True when <path> is a linked worktree of <clone> (never the main one).
is_worktree_of() { # <clone> <path>
	local want line first=true
	[[ -d "$2" ]] || return 1
	want=$(cd "$2" && pwd -P)
	while IFS= read -r line; do
		[[ "$line" == "worktree "* ]] || continue
		if [[ "$first" == true ]]; then
			first=false
			continue
		fi
		line=${line#worktree }
		[[ -d "$line" && "$(cd "$line" && pwd -P)" == "$want" ]] && return 0
	done < <(rgit -C "$1" worktree list --porcelain 2>/dev/null)
	return 1
}

# Sets WORKTREE_DIR: the PR's review worktree, detached at <sha>. Reused when pr.json names a worktree that is still
# registered, else made at <clone>.reviews/<slug>/<N>. A reused worktree is reset, with a warning when it was dirty.
# A folder in the way is never deleted. Saves clone, worktree, head_branch and user (GH_USER) in pr.json.
# shellcheck disable=SC2034 # the global is the result, read by the caller
review_worktree() { # <clone> <N> <head-branch> <sha>
	local clone path="" saved default
	WORKTREE_DIR=""
	delta_object_id "$4" || {
		echo "Error: not a commit ID: '$4'" >&2
		return 1
	}
	clone=$(cd "$1" && pwd) || return 1
	default="$(dirname "$clone")/$(basename "$clone").reviews/$(branch_slug "$3")/$2"
	saved=$(pr_json_get worktree) || return 1
	if [[ -n "$saved" ]] && is_worktree_of "$clone" "$saved"; then
		path="$saved"
	elif is_worktree_of "$clone" "$default"; then
		path="$default"
	fi

	if [[ -z "$path" ]]; then
		path="$default"
		rgit -C "$clone" worktree prune || return 1
		if [[ -e "$path" || -L "$path" ]]; then
			echo "Error: $path is in the way: it is not a worktree of $clone." >&2
			echo "    It was left as is. Move it away, or pass --fresh." >&2
			return 1
		fi
		mkdir -p "$(dirname "$path")" || return 1
		rgit -C "$clone" worktree add --quiet --detach --end-of-options "$path" "$4" || return 1
	else
		if [[ -n "$(rgit -C "$path" status --porcelain)" ]]; then
			echo "Warning: the review worktree was dirty; resetting it: $path" >&2
		fi
		# No --end-of-options: git 2.43's checkout takes it for a path. <sha> is a checked object ID, never an option.
		rgit -C "$path" checkout --quiet --detach --force "$4" || return 1
		rgit -C "$path" clean -fdq || return 1
	fi

	pr_json_set clone "$clone" && pr_json_set worktree "$path" && pr_json_set head_branch "$3" &&
		pr_json_set user "${GH_USER:-}" || return 1
	WORKTREE_DIR="$path"
}

# After a post: refs/pr-review/<N>/round-<K> keeps the reviewed head, and …/round-<K>-base the round's base
# (default: the merge-base of <sha> and refs/pr-review/<N>/base), so force-pushes cannot lose them.
mark_round() { # <clone> <N> <K> <sha> [<base-sha>]
	local base="${5:-}"
	if [[ ! "$2" =~ ^[0-9]+$ || ! "$3" =~ ^[0-9]+$ ]] || ! delta_object_id "$4"; then
		echo "Error: mark_round: not a PR number, round and commit ID: '$2' '$3' '$4'" >&2
		return 1
	fi
	[[ -n "$base" ]] || base=$(rgit -C "$1" merge-base "$4" "refs/pr-review/$2/base") || return 1
	delta_object_id "$base" || {
		echo "Error: mark_round: not a commit ID: '$base'" >&2
		return 1
	}
	rgit -C "$1" update-ref --end-of-options "refs/pr-review/$2/round-$3" "$4" &&
		rgit -C "$1" update-ref --end-of-options "refs/pr-review/$2/round-$3-base" "$base"
}

# The previous round's head and base, one per line: from refs/pr-review/<N>/round-<K> and …-base when the ref is
# there and agrees with the record's head (or the record has none), else the record's. The refs survive a force-push;
# a ref that disagrees is from an older history of the PR's rounds (a review deleted and posted again).
round_shas() { # <dir> <N> <K> <record-head> <record-base>
	local head base
	if [[ "$2" =~ ^[0-9]+$ && "$3" =~ ^[0-9]+$ ]] &&
		head=$(rgit -C "$1" rev-parse --verify --quiet "refs/pr-review/$2/round-$3^{commit}") &&
		[[ -z "$4" || "$4" == "$head" ]]; then
		base=$(rgit -C "$1" rev-parse --verify --quiet "refs/pr-review/$2/round-$3-base^{commit}") || base=$5
		printf '%s\n%s\n' "$head" "$base"
	else
		printf '%s\n%s\n' "$4" "$5"
	fi
}

# --fresh: a throwaway depth-50 clone at <dir>, detached at the PR head. No .reviews worktree.
fresh_checkout() { # <dir> <url> <N> <base-branch>
	rgit_net clone --quiet --depth 50 --end-of-options "$2" "$1" || return 1
	fetch_pr "$1" "$2" "$3" "$4" 50 || return 1
	rgit -C "$1" checkout --quiet --detach "refs/pr-review/$3/head"
}

# --fresh only: a PR branched off more than 50 commits back has no merge-base in the shallow clone. Deepens both
# histories once, one fetch per ref: in a single fetch, git can leave one of them as shallow as it was.
fresh_deepen() { # <dir> <url> <N> <base-branch>
	rgit_net -C "$1" fetch --quiet --no-tags --deepen 200 --end-of-options "$2" "+refs/pull/$3/head:refs/pr-review/$3/head" || true
	rgit_net -C "$1" fetch --quiet --no-tags --deepen 200 --end-of-options "$2" "+refs/heads/$4:refs/pr-review/$3/base" || true
}

# The review's base: the merge-base of HEAD and refs/pr-review/<N>/base. Fails when there is none.
review_base() { # <dir> <N>
	rgit -C "$1" merge-base HEAD "refs/pr-review/$2/base"
}
