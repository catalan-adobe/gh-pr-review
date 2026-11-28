#!/usr/bin/env bash
# Find the local clone of a repo, or make a cache clone. Functions only.
# Uses config_get (lib/config.sh) and state_root (lib/state.sh).

# Git against a clone, with the clone's hooks off. rgit_net adds GIT_AUTH, the per-command credential helper
# that the review run defines (unset: no extra options, as with file:// remotes in the tests).
rgit() {
	git -c core.hooksPath=/dev/null "$@"
}
rgit_net() {
	git -c core.hooksPath=/dev/null ${GIT_AUTH[@]+"${GIT_AUTH[@]}"} "$@"
}

# "~" and "~/x" in config paths and --clone, relative to $HOME.
expand_home() { # <path>
	# shellcheck disable=SC2088 # matching a literal ~, not expanding it
	case "$1" in
	"~") printf '%s\n' "$HOME" ;;
	"~/"*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
	*) printf '%s\n' "$1" ;;
	esac
}

# host/owner/repo, lowercase, for https://h/o/r(.git), git@h:o/r(.git) and ssh://git@h(:port)/o/r(.git).
# Anything else prints nothing and fails.
normalize_remote() { # <url>
	local url="${1%/}" host path
	if [[ "$url" =~ ^(https?|ssh|git)://([^@/]+@)?([^/:]+)(:[0-9]+)?/([^/]+/[^/]+)$ ]]; then
		host="${BASH_REMATCH[3]}"
		path="${BASH_REMATCH[5]}"
	elif [[ "$url" =~ ^([^@/:]+@)?([^/:]+):/?([^/]+/[^/]+)$ ]]; then
		host="${BASH_REMATCH[2]}"
		path="${BASH_REMATCH[3]}"
	else
		return 1
	fi
	tr '[:upper:]' '[:lower:]' <<<"$host/${path%.git}"
}

# True when some remote of the clone points at host/owner/repo (any remote name).
clone_matches() { # <dir> <host/owner/repo, lowercase>
	local _name url
	while read -r _name url; do
		[[ "$(normalize_remote "$url" || true)" == "$2" ]] && return 0
	done < <(rgit -C "$1" config --get-regexp '^remote\..*\.url$' 2>/dev/null || true)
	return 1
}

# Why a folder cannot serve as the review clone, or nothing. Shallow and partial clones fetch on demand
# from inside `git show`, which needs the credentials that the reviewer's sandbox removes.
clone_problem() { # <dir>
	if [[ ! -d "$1" ]] || ! rgit -C "$1" rev-parse --git-dir >/dev/null 2>&1; then
		echo "not a git repository"
	elif [[ "$(rgit -C "$1" rev-parse --is-shallow-repository)" == true ]]; then
		echo "shallow clone"
	elif is_partial_clone "$1"; then
		echo "partial clone"
	fi
}

# Older git sets extensions.partialClone, newer git a promisor remote with a filter.
is_partial_clone() { # <dir>
	local key value
	while read -r key value; do
		case "$key" in
		extensions.partialclone | remote.*.partialclonefilter) [[ -n "$value" ]] && return 0 ;;
		remote.*.promisor) [[ "$value" == true ]] && return 0 ;;
		esac
	done < <(rgit -C "$1" config --get-regexp '^(extensions\.partialclone|remote\..*\.(promisor|partialclonefilter))$' || true)
	return 1
}

# Remembers a scan's pick in <state_root>/clones.json.
remember_clone() { # <host/owner/repo> <dir>
	local file tmp
	file="$(state_root)/clones.json"
	mkdir -p "$(dirname "$file")"
	tmp=$(mktemp "$file.XXXXXX")
	if { jq -e 'objects' "$file" 2>/dev/null || echo '{}'; } |
		jq --arg k "$1" --arg v "$2" '.[$k] = $v' >"$tmp"; then
		mv "$tmp" "$file"
	else
		rm -f "$tmp"
	fi
}

# Sets CLONE_DIR and CLONE_KIND (override, config, scan or cache) for a repo. The order: CLONE_OVERRIDE
# (--clone), the config `clones` map, clones.json, a scan of the config `roots`, then the cache clone.
# Notes go to stderr. Globals, not output, because the run needs both values.
# shellcheck disable=SC2034 # the globals are the result, read by the caller
find_clone() { # <host> <owner> <repo>
	local key clones roots path problem root gitdir dir time best="" best_time=-1
	key=$(tr '[:upper:]' '[:lower:]' <<<"$1/$2/$3")
	CLONE_DIR=""
	CLONE_KIND=""

	if [[ -n "${CLONE_OVERRIDE:-}" ]]; then
		path=$(expand_home "$CLONE_OVERRIDE")
		problem=$(clone_problem "$path")
		if [[ -n "$problem" ]]; then
			echo "Error: --clone $path: $problem" >&2
			return 1
		fi
		CLONE_DIR=$(cd "$path" && pwd)
		CLONE_KIND=override
		clone_matches "$CLONE_DIR" "$key" || echo "Note: no remote of $CLONE_DIR points at $key" >&2
		return 0
	fi

	# A value of the wrong type prints nothing: no clones, no roots.
	clones=$(config_get '.clones | objects' '{}') || return 1
	roots=$(config_get '.roots | if type == "string" then [.] else arrays end' '["~/repos"]') || return 1
	path=$(jq -r --arg k "$key" 'to_entries[] | select((.key | ascii_downcase) == $k) | .value | strings' \
		<<<"${clones:-"{}"}" | head -n1)
	if [[ -n "$path" ]]; then
		path=$(expand_home "$path")
		problem=$(clone_problem "$path")
		if [[ -z "$problem" ]]; then
			CLONE_DIR=$(cd "$path" && pwd)
			CLONE_KIND=config
			return 0
		fi
		echo "Note: skipping the configured clone $path: $problem" >&2
	fi

	path=$(jq -r --arg k "$key" '.[$k] // empty' "$(state_root)/clones.json" 2>/dev/null || true)
	if [[ -n "$path" && -z "$(clone_problem "$path")" ]] && clone_matches "$path" "$key"; then
		CLONE_DIR="$path"
		CLONE_KIND=scan
		return 0
	fi

	# A linked worktree's .git is a file, so -type d finds main clones only.
	while IFS= read -r root; do
		root=$(expand_home "$root")
		[[ -d "$root" ]] || continue
		while IFS= read -r gitdir; do
			dir=$(dirname "$gitdir")
			clone_matches "$dir" "$key" || continue
			problem=$(clone_problem "$dir")
			if [[ -n "$problem" ]]; then
				echo "Note: skipping $dir: $problem" >&2
				continue
			fi
			time=0
			[[ -f "$gitdir/FETCH_HEAD" ]] && time=$(date -r "$gitdir/FETCH_HEAD" +%s)
			if [[ "$time" -gt "$best_time" ]]; then
				best="$dir"
				best_time="$time"
			fi
		done < <(find "$root" -maxdepth 5 \( -name node_modules -o -name '*.reviews' \) -prune \
			-o -type d -name .git -print -prune 2>/dev/null | LC_ALL=C sort)
	done < <(jq -r '.[] | strings' <<<"${roots:-"[]"}")
	if [[ -n "$best" ]]; then
		CLONE_DIR=$(cd "$best" && pwd)
		CLONE_KIND=scan
		remember_clone "$key" "$CLONE_DIR"
		return 0
	fi

	path="${XDG_CACHE_HOME:-$HOME/.cache}/gh-pr-review/clones/$key"
	if [[ ! -d "$path" ]]; then
		echo "Note: no local clone of $key; making a cache clone: $path" >&2
		mkdir -p "$(dirname "$path")"
		rgit_net clone --bare --quiet --end-of-options "https://$1/$2/$3.git" "$path" || {
			echo "Error: could not clone https://$1/$2/$3.git (check gh auth and network)." >&2
			return 1
		}
	fi
	CLONE_DIR="$path"
	CLONE_KIND=cache
}
