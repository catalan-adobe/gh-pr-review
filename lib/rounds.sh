#!/usr/bin/env bash
# A PR's review rounds, read from GitHub, and the `gh pr-review rounds` subcommand. Functions only.

# Prints the PR's round records as a JSON array, oldest first: the hidden marker of each gh-pr-review review, or a
# record rebuilt from the review's Markdown (backfill) when the review predates the markers. A generated review is one
# whose first line is the generated marker (is_generated_review in lib/records.jq). GitHub's facts win over the
# marker's: the round is the review's position in submission order, posted_at its submission time, head_sha the
# commit it was posted on, reviewer its author and review_id its GitHub review ID, so two reviews posted at once can't
# both be round K, nor both give out the same new finding IDs (reconcile_record in lib/records.jq).
# Only trusted reviews are rounds (trusted_review in lib/records.jq): by an owner, member or collaborator of the repo,
# or by <me>, the account running the tool (empty when unknown). The other generated reviews are left out, and listed
# in <ignored-out> when given: a JSON array of {login, association} (ignored_line prints it for a person).
# Callers run it in conditions, where errexit is off: every step checks its own status, and the result is checked
# (an array of records, each with a round number) before it is printed. Any failure prints nothing and returns 1.
fetch_round_records() { # <host> <owner> <repo> <N> [<me>] [<ignored-out>]
	local me="${5:-}" generated reviews pr records='[]' previous=null round=0 review record body facts minimal dropped
	generated=$(gh api --hostname "$1" --paginate "repos/$2/$3/pulls/$4/reviews" | jq -cs -L "${LIB_DIR:?}" '
		include "records";
		add // [] | map(select((.body | is_generated_review) and .state != "PENDING"))
		| sort_by([.submitted_at // "", .id // 0])
		| map({id, body, state, commit_id, submitted_at, author_association, user: {login: .user.login?}})') || {
		echo "Error: could not fetch the reviews of $2/$3#$4 (check gh auth and network)." >&2
		return 1
	}
	reviews=$(jq -c -L "${LIB_DIR:?}" --arg me "$me" 'include "records"; .[] | select(trusted_review($me))' \
		<<<"$generated") || return 1
	if [[ -n "${6:-}" ]]; then
		jq -c -L "${LIB_DIR:?}" --arg me "$me" 'include "records";
			map(select(trusted_review($me) | not) | {login: .user.login, association: .author_association})' \
			<<<"$generated" >"$6" || return 1
	fi
	pr=$(jq -cn --arg host "$1" --arg owner "$2" --arg repo "$3" --argjson number "$4" \
		'{host: $host, owner: $owner, repo: $repo, number: $number}') || return 1
	while IFS= read -r review; do
		[[ -n "$review" ]] || continue
		round=$((round + 1))
		body=$(jq -r '.body' <<<"$review") || return 1
		record=$(marker_record "$body") || return 1
		minimal=""
		# A minimal marker (no room for the counts) says only that the findings are missing: the counts come from the
		# Markdown, as for a marker without counts, and the record keeps findings_dropped and the marker's last_ids.
		if [[ -n "$record" ]]; then
			dropped=$(jq '.findings_dropped == true and (has("counts") | not)' <<<"$record") || return 1
			if [[ "$dropped" == true ]]; then
				minimal="$record"
				record=""
			else
				# A code-review marker without its blocking count: rebuilt, or unknown, never 0 (with_counts).
				record=$(printf '%s\n%s\n' "$record" "$review" | jq -cs -L "${LIB_DIR:?}" \
					'include "records"; .[1].body as $body | .[0] | with_counts($body)') || return 1
			fi
		fi
		if [[ -z "$record" ]]; then
			# The previous record carries the history's ID floor, so backfilled IDs never restart either.
			if [[ "$previous" != null ]]; then
				previous=$(printf '%s\n%s\n' "$records" "$previous" |
					jq -cs -L "${LIB_DIR:?}" 'include "records"; .[1] + {last_ids: (.[0] | id_floor)}') || return 1
			fi
			record=$(backfill_record "$review" "$previous" "$round" "$pr") || return 1
			if [[ -n "$minimal" ]]; then
				# Its counts come from the Markdown as with_counts reads them: null, so unknown, when it has no severity
				# heading, exactly as for a marker without counts. A Rethink keeps the backfill's counts, all null, so
				# the record has the same shape whatever the marker's size. A later round's Markdown leaves out the
				# findings it carried: its counts stay the backfill's, with the open blocking count of its progress line.
				record=$(printf '%s\n%s\n' "$record" "$review" | jq -cs -L "${LIB_DIR:?}" --argjson m "$minimal" '
					include "records";
					.[1].body as $body | .[0] as $b | $b + ($m | del(.last_ids)) | del(.findings)
					| .last_ids = {F: ([$b.last_ids.F, $m.last_ids.F?] | map(numbers) | max // 0),
						L: ([$b.last_ids.L, $m.last_ids.L?] | map(numbers) | max // 0)}
					| if .code_review == false or ($body | later_round_body) then .
					else del(.counts) | with_counts($body) end') || return 1
			fi
		fi
		facts=$(jq -c '({posted_at: .submitted_at, head_sha: .commit_id, reviewer: .user.login}
			| with_entries(select(.value | type == "string" and . != "")))
			+ (if .id | type == "number" then {review_id: .id} else {} end)' <<<"$review") || return 1
		# Two runs posted at once: the later one's new IDs and first_round follow its position (reconcile_record).
		record=$(printf '%s\n%s\n' "$records" "$record" | jq -cs -L "${LIB_DIR:?}" --argjson round "$round" \
			--argjson facts "$facts" 'include "records"; .[0] as $earlier | .[1] | reconcile_record($earlier; $round)
				+ $facts + {round: $round}') || return 1
		# Records and history go through stdin: a long history must never be one process argument.
		records=$(printf '%s\n%s\n' "$records" "$record" | jq -cs '.[0] + [.[1]]') || return 1
		previous="$record"
	done <<<"$reviews"
	if ! jq -e 'type == "array" and all(.[]; type == "object" and (.round | type == "number"))' \
		<<<"$records" >/dev/null 2>&1; then
		echo "Error: could not read the rounds of $2/$3#$4 from their reviews." >&2
		return 1
	fi
	printf '%s\n' "$records"
}

# One line for a person about the generated reviews fetch_round_records left out (what it wrote to <ignored-out>), or
# nothing:  ignored: 1 generated review by @x (not a member or collaborator of the repo)
ignored_line() { # <ignored-json>
	[[ -n "$1" ]] || return 0
	jq -r 'select(type == "array" and length > 0)
		| ([.[].login | "@\(. // "ghost")"] | unique) as $who
		| "ignored: \(length) generated review\(if length == 1 then "" else "s" end) by \($who | join(", "))"
			+ (if ($who | length) == 1 then " (not a member or collaborator of the repo)"
			else " (not members or collaborators of the repo)" end)' <<<"$1"
}

# The PR's size, head and author, as `{lines, files, head, author}`.
fetch_pr_shape() { # <host> <owner> <repo> <N>
	gh pr view "$4" --repo "$1/$2/$3" --json additions,deletions,changedFiles,headRefOid,author |
		jq -c '{lines: (.additions + .deletions), files: .changedFiles, head: .headRefOid, author: .author.login}'
}

# Prints true when a person other than the PR author reviewed or commented after <time>: that lifts a loop-check
# stop. Only an identified person counts: no login (user null), GitHub's deleted-account placeholder ("ghost"), bots
# (user.type "Bot", or a login ending in [bot]) and gh-pr-review rounds do not, and neither does the PR author: on my
# own PRs, fix agents post as me and must not lift their own stop.
lifted_since() { # <host> <owner> <repo> <N> <time> <pr-author>
	local out
	# Captured first: a gh failure half-way must print one answer, not jq's partial one and then "false".
	if out=$({
		gh api --hostname "$1" --paginate "repos/$2/$3/issues/$4/comments" &&
			gh api --hostname "$1" --paginate "repos/$2/$3/pulls/$4/reviews" &&
			gh api --hostname "$1" --paginate "repos/$2/$3/pulls/$4/comments"
	} | jq -s -L "${LIB_DIR:?}" --arg since "$5" --arg author "$6" '
		include "records";
		[.[] | .[]?] | any(.[];
			((.submitted_at // .created_at // "") > $since)
			and ((.user.type // "") != "Bot")
			and ((.user.login // "") as $login
				| $login != "" and $login != "ghost" and $login != $author and ($login | endswith("[bot]") | not))
			and ((.body | is_generated_review) | not))'); then
		printf '%s\n' "$out"
	else
		echo "Warning: could not read the PR's comments; the loop check ignores them." >&2
		echo false
	fi
}

# The login of the account running the tool, read with one retry. Its own rounds count even where it is only a
# contributor (fetch_round_records), so the history can't be checked without it: when both reads fail, it says so and
# fails.
operator_login() { # <host>
	local login try
	for try in 1 2; do
		if login=$(gh api --hostname "$1" user --jq .login 2>/dev/null) && [[ -n "$login" ]]; then
			printf '%s\n' "$login"
			return 0
		fi
		[[ "$try" == 2 ]] || sleep 1
	done
	echo "Error: could not read the account running the tool, so the round history can't be checked; check gh auth and network." >&2
	return 1
}

cmd_rounds() { # <PR-URL | PR-number> [--json] [-u <login>]
	local target="" as_json=false user="${GH_PR_REVIEW_USER:-}" records shape commits decision lifted me ignored_file ignored
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
			echo "+COMMITS: the commits dated between the previous round's review and this one's (a date window:"
			echo "a commit pushed while a review ran can count toward that review)."
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

	# Your own rounds count even where you are only a contributor (fetch_round_records).
	me=$(operator_login "$GH_HOST_NAME") || return 1
	ignored_file=$(mktemp)
	if ! records=$(fetch_round_records "$GH_HOST_NAME" "$OWNER" "$REPO" "$PR_NUM" "$me" "$ignored_file"); then
		rm -f "$ignored_file"
		return 1
	fi
	ignored=$(cat "$ignored_file")
	rm -f "$ignored_file"
	[[ -n "$ignored" ]] || ignored='[]'
	shape=$(fetch_pr_shape "$GH_HOST_NAME" "$OWNER" "$REPO" "$PR_NUM")
	lifted=false
	if [[ $(jq 'length' <<<"$records") -gt 0 ]]; then
		lifted=$(lifted_since "$GH_HOST_NAME" "$OWNER" "$REPO" "$PR_NUM" \
			"$(jq -r 'last.posted_at // ""' <<<"$records")" "$(jq -r '.author // ""' <<<"$shape")")
	fi
	decision=$(loop_decide_json "$records" "$shape" "$(jq -r '.head // ""' <<<"$shape")" "$lifted")

	if [[ "$as_json" == true ]]; then
		jq --argjson decision "$decision" --argjson ignored "$ignored" \
			'{records: ., decision: $decision, ignored: $ignored}' <<<"$records"
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
	ignored_line "$ignored"
	jq -r '"next round: " + ([.decision, .label, (.flags | join(" ")), .suggestion]
		| map(select(. != null and . != "")) | join(" · "))' <<<"$decision"
}
