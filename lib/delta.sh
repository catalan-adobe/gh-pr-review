#!/usr/bin/env bash
# What changed since the last round: how to show it (pick_delta) and which files it touched (changed_files).
# Functions only. Git runs quietly in the review checkout: stdout carries the JSON or the paths, nothing else.

# Prints `{mode, reason, commands, prev_head, prev_base, head, base}` as one compact JSON line. Modes:
#   incremental  the previous head is an ancestor of the head: `git diff --stat` and `git diff` from it. When the
#                author merged the base branch in since, the diff starts from the previous head merged onto the new
#                base (a tree, in the extra field `from`), so what the base brought is left out.
#   rebased      the previous head is not an ancestor (rebase or force-push): a `git range-diff` of the two ranges.
#   full         anything else, with a short human reason, a base merge with conflicts included. The round then
#                reviews the whole PR.
# The previous head and base come from a marker on the PR, which anyone can edit: they count only as full object IDs
# (40 or 64 hex digits), checked before git sees them. A name (HEAD, main), a short SHA or an option is `full`.
# The four SHA fields are full SHAs when the checkout has the commit, else as given ("" when unknown); changed_files
# reads them. Never fails: every git error ends in `full`.
pick_delta() { # <repo-dir> <prev-head> <prev-base> <head> <base>
	local repo=$1 prev_head=$2 prev_base=$3 head=$4 base=$5 sha old new reason tree
	if [[ -z "$prev_head" ]]; then
		delta_json full "no previous round" "$prev_head" "$prev_base" "$head" "$base"
		return 0
	fi
	if ! delta_object_id "$prev_head"; then
		delta_json full "previous head is not a full commit ID" "$prev_head" "$prev_base" "$head" "$base"
		return 0
	fi
	if [[ -n "$prev_base" ]] && ! delta_object_id "$prev_base"; then
		delta_json full "previous base is not a full commit ID" "$prev_head" "$prev_base" "$head" "$base"
		return 0
	fi
	if sha=$(delta_resolve "$repo" "$head"); then head=$sha; else
		delta_json full "head ${head:0:12} not in the checkout" "$prev_head" "$prev_base" "$head" "$base"
		return 0
	fi
	if sha=$(delta_find "$repo" "$prev_head"); then prev_head=$sha; else
		delta_json full "previous head ${prev_head:0:12} not found after fetch" "$prev_head" "$prev_base" "$head" "$base"
		return 0
	fi
	delta_connect "$repo" "$prev_head" "$head"

	if git -C "$repo" merge-base --is-ancestor "$prev_head" "$head" >/dev/null 2>&1; then
		# The author merged the base branch in since: a plain diff would show everything the base brought. Compare with
		# the previous head merged onto the new base instead, which leaves the author's own changes.
		if sha=$(delta_resolve "$repo" "$base") &&
			! git -C "$repo" merge-base --is-ancestor "$sha" "$prev_head" >/dev/null 2>&1; then
			if tree=$(git -C "$repo" -c core.hooksPath=/dev/null merge-tree --write-tree "$prev_head" "$sha" 2>/dev/null); then
				tree=${tree%%$'\n'*}
				delta_json incremental "the base branch was merged in: compared with the previous head merged onto the new base" \
					"$prev_head" "$prev_base" "$head" "$sha" "git diff --stat ${tree} ${head}" "git diff ${tree} ${head}" |
					jq -c --arg from "$tree" '. + {from: $from}'
				return 0
			fi
			# A merge with conflicts: the author's resolution lives in the merge commit, which range-diff skips. Only
			# the whole PR shows it.
			delta_json full "the base branch was merged in with conflicts" "$prev_head" "$prev_base" "$head" "$sha"
			return 0
		else
			reason="previous head is an ancestor of the head"
			[[ "$prev_head" != "$head" ]] || reason="no new commits since the previous round"
			delta_json incremental "$reason" "$prev_head" "$prev_base" "$head" "$base" \
				"git diff --stat ${prev_head}..${head}" "git diff ${prev_head}..${head}"
			return 0
		fi
	fi

	# Rebase or force-push: a plain diff would mix in what the base branch did, so compare the two ranges instead.
	if [[ -z "$prev_base" ]]; then
		delta_json full "previous base unknown" "$prev_head" "$prev_base" "$head" "$base"
		return 0
	fi
	if sha=$(delta_find "$repo" "$prev_base"); then prev_base=$sha; else
		delta_json full "previous base ${prev_base:0:12} not found after fetch" "$prev_head" "$prev_base" "$head" "$base"
		return 0
	fi
	if sha=$(delta_resolve "$repo" "$base"); then base=$sha; else
		delta_json full "base ${base:0:12} not in the checkout" "$prev_head" "$prev_base" "$head" "$base"
		return 0
	fi
	old="${prev_base}..${prev_head}"
	new="${base}..${head}"
	# Try it before handing it to the reviewer: a range it cannot walk (shallow history, odd ranges) fails here.
	if git -C "$repo" range-diff --no-color "$old" "$new" >/dev/null 2>&1; then
		delta_json rebased "previous head is not an ancestor of the head (rebase or force-push)" \
			"$prev_head" "$prev_base" "$head" "$base" "git range-diff $old $new"
	else
		reason="range-diff failed on ${prev_base:0:12}..${prev_head:0:12} ${base:0:12}..${head:0:12}"
		delta_json full "$reason" "$prev_head" "$prev_base" "$head" "$base"
	fi
	return 0
}

# Prints the paths the delta touched, one per line, sorted and unique: the code that counts as "touched".
#   incremental  the files changed between the previous head (or `from`) and the head.
#   rebased      the files whose change in the PR differs between the old and the new version (index lines and
#                hunk line numbers ignored, so the base moving under an unchanged patch does not count), plus the
#                files the PR newly touches or no longer touches.
#   full         nothing.
changed_files() { # <repo-dir> <delta-json>
	local repo=$1 mode prev_head prev_base head base from path old new
	{
		IFS= read -r mode
		IFS= read -r prev_head
		IFS= read -r prev_base
		IFS= read -r head
		IFS= read -r base
		IFS= read -r from
	} < <(jq -r '.mode, .prev_head // "", .prev_base // "", .head // "", .base // "", .from // ""' <<<"$2")
	case "$mode" in
	incremental)
		# from: the previous head merged onto the new base, when the author merged the base in.
		git -C "$repo" diff --name-only --no-renames -z "${from:-$prev_head}" "$head" | tr '\0' '\n' | LC_ALL=C sort -u
		;;
	rebased)
		{
			git -C "$repo" diff --name-only --no-renames -z "$base" "$head"
			git -C "$repo" diff --name-only --no-renames -z "$prev_base" "$prev_head"
		} | tr '\0' '\n' | LC_ALL=C sort -u | while IFS= read -r path; do
			old=$(delta_file_patch "$repo" "$prev_base" "$prev_head" "$path")
			new=$(delta_file_patch "$repo" "$base" "$head" "$path")
			[[ "$old" == "$new" ]] || printf '%s\n' "$path"
		done
		;;
	esac
}

# ── helpers ──────────────────────────────────────────────────────────────────

delta_json() { # <mode> <reason> <prev-head> <prev-base> <head> <base> [command...]
	jq -cn --arg mode "$1" --arg reason "$2" --arg prev_head "$3" --arg prev_base "$4" --arg head "$5" \
		--arg base "$6" '{mode: $mode, reason: $reason, commands: $ARGS.positional,
		prev_head: $prev_head, prev_base: $prev_base, head: $head, base: $base}' --args "${@:7}"
}

# A full hexadecimal object ID: 40 digits (SHA-1) or 64 (SHA-256).
delta_object_id() { # <value>
	[[ "$1" =~ ^[0-9a-f]{40}$ || "$1" =~ ^[0-9a-f]{64}$ ]]
}

# Prints the full SHA of a commit the checkout has. Fails when it is missing (or the SHA is empty).
delta_resolve() { # <repo-dir> <sha>
	[[ -n "$2" ]] || return 1
	git -C "$1" rev-parse --verify --quiet --end-of-options "${2}^{commit}" 2>/dev/null
}

# Like delta_resolve, but a missing commit gets one fetch by SHA first. GitHub serves commits that are still in the
# repository (refs/pull/* keeps many alive), so a commit older than the clone's depth usually comes back.
delta_find() { # <repo-dir> <sha>
	delta_resolve "$1" "$2" && return 0
	local depth=()
	# --depth only in a shallow clone: in a full one it would cut the history short.
	if delta_shallow "$1"; then depth=(--depth 50); fi
	# Same credentials as the clone (GIT_AUTH, when the script set it), no hooks, quiet; errors only mean "missing".
	git -C "$1" ${GIT_AUTH[@]+"${GIT_AUTH[@]}"} -c core.hooksPath=/dev/null \
		fetch --quiet --no-tags ${depth[@]+"${depth[@]}"} --end-of-options origin "$2" >/dev/null 2>&1 || true
	delta_resolve "$1" "$2"
}

# In a shallow clone the previous head can be an ancestor of the head yet sit below the head's shallow boundary:
# the histories then share no commit and --is-ancestor says no. Deepen the head's history once, so the check can
# see the link. Connected histories, or a full clone, need nothing.
delta_connect() { # <repo-dir> <prev-head> <head>
	delta_shallow "$1" || return 0
	git -C "$1" merge-base "$2" "$3" >/dev/null 2>&1 && return 0
	git -C "$1" ${GIT_AUTH[@]+"${GIT_AUTH[@]}"} -c core.hooksPath=/dev/null \
		fetch --quiet --no-tags --deepen 50 --end-of-options origin "$3" >/dev/null 2>&1 || true
}

delta_shallow() { # <repo-dir>
	[[ "$(git -C "$1" rev-parse --is-shallow-repository 2>/dev/null)" == true ]]
}

# One file's patch between two commits, without what moves when the base moves: the `index` line (blob SHAs) and
# the line numbers of the `@@` hunk headers. Literal pathspec: a path is a name, never a glob.
delta_file_patch() { # <repo-dir> <from> <to> <path>
	git --literal-pathspecs -C "$1" diff --no-color --no-ext-diff --no-textconv --no-renames "$2" "$3" -- "$4" |
		sed -e '/^index /d' -e 's/^@@ -[0-9,]* +[0-9,]* @@/@@ @@/'
}
