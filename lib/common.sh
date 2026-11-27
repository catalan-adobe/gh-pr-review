#!/usr/bin/env bash
# Helpers shared by the review run and the subcommands. Functions only.

# Sets GH_HOST_NAME, OWNER, REPO and PR_NUM from a PR URL, or from a bare number inside a repo clone.
# shellcheck disable=SC2034 # the globals are the result, read by the caller
resolve_target() { # <URL | number>
	local target="$1" repo_json
	if [[ "$target" =~ ^[0-9]+$ ]]; then
		repo_json=$(gh repo view --json owner,name,url 2>/dev/null) || {
			echo "Error: a bare PR number only works inside a repo clone." >&2
			echo "cd into the repository, or pass the full PR URL." >&2
			exit 1
		}
		OWNER=$(jq -r '.owner.login' <<<"$repo_json")
		REPO=$(jq -r '.name' <<<"$repo_json")
		PR_NUM="$target"
		GH_HOST_NAME=$(jq -r '.url | split("/")[2]' <<<"$repo_json")
	elif [[ "$target" =~ ^https?://([^/]+)/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
		GH_HOST_NAME="${BASH_REMATCH[1]}"
		OWNER="${BASH_REMATCH[2]}"
		REPO="${BASH_REMATCH[3]}"
		PR_NUM="${BASH_REMATCH[4]}"
	else
		echo "Error: expected a GitHub PR URL or PR number, got: $target" >&2
		exit 1
	fi
}

# Uses another logged-in gh account for this run only: an env token, never `gh auth switch`.
use_gh_user() { # <login> (empty: keep the active account)
	[[ -z "$1" ]] && return 0
	GH_TOKEN=$(gh auth token --user "$1") || {
		echo "Error: no gh login for '$1' — see: gh auth status" >&2
		exit 1
	}
	export GH_TOKEN GITHUB_TOKEN="$GH_TOKEN"
}
