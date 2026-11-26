#!/usr/bin/env bash
# A PR's review rounds, read from GitHub, and the `gh pr-review rounds` subcommand. Functions only.

# Prints the PR's round records as a JSON array, oldest first: the hidden marker of each gh-pr-review review, or a
# record rebuilt from the review's Markdown (backfill) when the review predates the markers.
fetch_round_records() { # <host> <owner> <repo> <N>
	local reviews pr records='[]' previous=null round=0 review record body
	reviews=$(gh api --hostname "$1" --paginate "repos/$2/$3/pulls/$4/reviews" | jq -cs '
		add // [] | map(select((.body // "") | contains("<!-- gh-pr-review generated -->")))
		| sort_by(.submitted_at) | .[] | {body, commit_id, submitted_at, user: {login: .user.login}}') || {
		echo "Error: could not fetch the reviews of $2/$3#$4 (check gh auth and network)." >&2
		return 1
	}
	pr=$(jq -cn --arg host "$1" --arg owner "$2" --arg repo "$3" --argjson number "$4" \
		'{host: $host, owner: $owner, repo: $repo, number: $number}')
	while IFS= read -r review; do
		[[ -n "$review" ]] || continue
		round=$((round + 1))
		body=$(jq -r '.body' <<<"$review")
		record=$(marker_record "$body" || true)
		if [[ -z "$record" ]]; then
			record=$(backfill_record "$review" "$previous" "$round" "$pr")
		fi
		records=$(jq -c --argjson record "$record" '. + [$record]' <<<"$records")
		previous="$record"
	done <<<"$reviews"
	printf '%s\n' "$records"
}

# The PR's size, head and author, as `{lines, files, head, author}`.
fetch_pr_shape() { # <host> <owner> <repo> <N>
	gh pr view "$4" --repo "$1/$2/$3" --json additions,deletions,changedFiles,headRefOid,author |
		jq -c '{lines: (.additions + .deletions), files: .changedFiles, head: .headRefOid, author: .author.login}'
}

# Prints true when a person other than the PR author reviewed or commented after <time>: that lifts a loop-check
# stop. Bots (user.type "Bot", or a login ending in [bot]) and gh-pr-review rounds do not count, and neither does
# the PR author: on my own PRs, fix agents post as me and must not lift their own stop.
lifted_since() { # <host> <owner> <repo> <N> <time> <pr-author>
	{
		gh api --hostname "$1" --paginate "repos/$2/$3/issues/$4/comments" &&
			gh api --hostname "$1" --paginate "repos/$2/$3/pulls/$4/reviews" &&
			gh api --hostname "$1" --paginate "repos/$2/$3/pulls/$4/comments"
	} | jq -s --arg since "$5" --arg author "$6" '
		[.[] | .[]?] | any(.[];
			((.submitted_at // .created_at // "") > $since)
			and ((.user.type // "") != "Bot")
			and ((.user.login // "") as $login | $login != $author and ($login | endswith("[bot]") | not))
			and (((.body // "") | contains("<!-- gh-pr-review generated -->")) | not))' || {
		echo "Warning: could not read the PR's comments; the loop check ignores them." >&2
		echo false
	}
}

cmd_rounds() { # <PR-URL | PR-number> [--json] [-u <login>]
	local target="" as_json=false user="${GH_PR_REVIEW_USER:-}" records shape commits decision lifted
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			as_json=true
			shift
			;;
		-u | --user)
			[[ $# -ge 2 ]] || {
				echo "Error: --user requires a gh login" >&2
				return 1
			}
			user="$2"
			shift 2
			;;
		-h | --help)
			echo "Usage: gh pr-review rounds <PR-URL | PR-number> [--json] [-u <login>]"
			return 0
			;;
		-*)
			echo "Unknown option for rounds: $1" >&2
			return 1
			;;
		*)
			[[ -z "$target" ]] || {
				echo "Extra argument: $1" >&2
				return 1
			}
			target="$1"
			shift
			;;
		esac
	done
	[[ -n "$target" ]] || {
		echo "Usage: gh pr-review rounds <PR-URL | PR-number> [--json] [-u <login>]" >&2
		return 1
	}
	use_gh_user "$user"
	resolve_target "$target"

	records=$(fetch_round_records "$GH_HOST_NAME" "$OWNER" "$REPO" "$PR_NUM")
	shape=$(fetch_pr_shape "$GH_HOST_NAME" "$OWNER" "$REPO" "$PR_NUM")
	lifted=false
	if [[ $(jq 'length' <<<"$records") -gt 0 ]]; then
		lifted=$(lifted_since "$GH_HOST_NAME" "$OWNER" "$REPO" "$PR_NUM" \
			"$(jq -r 'last.posted_at // ""' <<<"$records")" "$(jq -r '.author // ""' <<<"$shape")")
	fi
	decision=$(loop_decide_json "$records" "$shape" "$(jq -r '.head // ""' <<<"$shape")" "$lifted")

	if [[ "$as_json" == true ]]; then
		jq -n --argjson records "$records" --argjson decision "$decision" '{records: $records, decision: $decision}'
		return 0
	fi

	commits=$(gh api --hostname "$GH_HOST_NAME" --paginate "repos/$OWNER/$REPO/pulls/$PR_NUM/commits" |
		jq -cs '[add // [] | .[].commit.committer.date]')
	echo "${OWNER}/${REPO}#${PR_NUM}"
	if [[ $(jq 'length' <<<"$records") == 0 ]]; then
		echo "No gh pr-review rounds yet."
	else
		# Columns are padded here, not with column(1): no extra tool, and no locale mangling of "–".
		jq -r --argjson commits "$commits" --argjson decision "$decision" '
			def dash: if . == null or . == "" then "–" else tostring end;
			def pad($w): if $w > length then . + ([range($w - length) | " "] | add) else . end;
			. as $records
			| [["ROUND", "DATE", "COMMIT", "+COMMITS", "APPROACH", "READY", "CRIT", "IMP", "MINOR", "LABEL", "SOURCE"]]
			  + [range(0; length) as $i | $records[$i] as $r
				| (if $i == 0 then "" else ($records[$i - 1].posted_at // "") end) as $since
				| [($r.round | dash), (($r.posted_at // "") | .[5:16] | sub("T"; " ") | dash),
				   (($r.head_sha // "") | .[0:7] | dash),
				   ([$commits[] | select(. > $since and . <= ($r.posted_at // ""))] | length | tostring),
				   ($r.approach | dash), ($r.ready | dash),
				   ($r.counts.critical | dash), ($r.counts.important | dash), ($r.counts.minor | dash),
				   ($decision.labels[$i] | dash), ($r.source | dash)]]
			| (transpose | map(map(length) | max)) as $widths
			| .[] | [range(0; length) as $c | .[$c] | pad($widths[$c])] | join("  ") | sub(" +$"; "")' <<<"$records"
	fi
	jq -r '"next round: " + ([.decision, .label, (.flags | join(" ")), .suggestion]
		| map(select(. != null and . != "")) | join(" · "))' <<<"$decision"
}
