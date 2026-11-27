#!/usr/bin/env bash
# Round records: findings block, findings parser, record builder, hidden marker and backfill. Functions only.
# The jq lives in lib/records.jq; callers set LIB_DIR.

# Copies a review to <body-out> without its last "```json findings" block, and writes that block's content to
# <findings-out>. No block: the whole review, and an empty <findings-out>. A block left open runs to the end.
cut_findings_block() { # <review-file> <body-out> <findings-out>
	local open='^[[:space:]]*(```+|~~~+)[[:space:]]*json[[:space:]]+findings[[:space:]]*$'
	local close='^[[:space:]]*(```+|~~~+)[[:space:]]*$'
	local range start end
	range=$(awk -v o="$open" -v c="$close" '
		!inside && $0 ~ o { inside = 1; s = NR; next }
		inside && $0 ~ c { inside = 0; ls = s; le = NR }
		END { if (inside) { ls = s; le = NR + 1 }; print ls + 0, le + 0 }' "$1")
	read -r start end <<<"$range"
	: >"$3"
	if [[ "$start" == 0 ]]; then
		cp "$1" "$2"
		return 0
	fi
	# Blank lines are held back, so the cut leaves no double blank line and no trailing blank lines.
	awk -v s="$start" -v e="$end" -v f="$3" '
		function out(l) {
			if (l ~ /^[[:space:]]*$/) { held = held l "\n"; return }
			printf "%s%s\n", held, l; held = ""; printed = 1
		}
		NR < s { out($0); next }
		NR == s || NR == e { next }
		NR < e { print > f; next }
		NR > e && !resumed && $0 ~ /^[[:space:]]*$/ && (held != "" || !printed) { next }
		{ if ($0 !~ /^[[:space:]]*$/) resumed = 1; out($0) }' "$1" >"$2"
}

# The findings in a review's Markdown, its code-review part (code_review_part in records.jq), as a JSON array of
# {severity, file, line, title}.
parse_findings() { # <markdown-file>
	jq -c -Rs -L "${LIB_DIR:?}" 'include "records"; code_review_part | parse_findings' "$1"
}

# A "Ready to merge?" value as yes, yes-with-fixes (any qualified yes), no, or unknown.
normalize_ready() { # <text>
	local v
	v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[*_`]//g; s/^[[:space:]]*//; s/[[:space:]]*$//')
	v=${v%.}
	case "$v" in
	yes | yes!) echo yes ;;
	yes[[:space:],\;:\(—–-]*) echo yes-with-fixes ;;
	no | no!) echo no ;;
	no[[:space:],\;:\(—–-]*) echo no ;;
	*) echo unknown ;;
	esac
}

# round.json from the run's facts (meta JSON), the findings JSON and the previous record JSON (or null).
build_record() { # <meta-json> <findings-json> <previous-record-json-or-null>
	jq -L "${LIB_DIR:?}" -n --argjson meta "$1" --argjson findings "${2:-[]}" --argjson prev "${3:-null}" \
		'include "records"; build_record($meta; $findings; $prev)'
}

# The hidden marker line for a record file, for the review posted below it: a file, or the text itself. Prints
# nothing when even the minimal marker would push the body past the size cap (see marker_line in records.jq).
marker_line() { # <record-file> <review-file | review-text>
	# shellcheck disable=SC2016 # $body and $record are jq variables
	local program='include "records"; . as $body | $record[0] | marker_line($body)'
	if [[ -f "$2" ]]; then
		jq -r -Rs -L "${LIB_DIR:?}" --slurpfile record "$1" "$program" "$2"
	else
		printf '%s' "$2" | jq -r -Rs -L "${LIB_DIR:?}" --slurpfile record "$1" "$program"
	fi
}

# The record of a generated review: the valid marker right below its first line, or nothing.
marker_record() { # <body>
	printf '%s' "$1" | jq -c -Rs -L "${LIB_DIR:?}" 'include "records"; marker_record'
}

# A record rebuilt from an old review: a GitHub REST review object ({body, commit_id, submitted_at, user, state}).
# No Approach section: approach "skipped". An Approach section without a "Ready to merge?" line or any severity
# section (_sections in records.jq) is a Rethink: no code review.
backfill_record() { # <review-json> <previous-record-or-null> <round> <pr-json>
	local body approach ready code_review=true has_approach=false
	body=$(jq -r '.body // ""' <<<"$1") || return 1
	approach=$(last_verdict 'approach' "$body")
	approach=${approach%%[^a-z]*}
	if [[ -n "$approach" ]] || grep -qiE '^#{1,6}[[:space:]]+approach[[:space:]]*$' <<<"$body"; then
		has_approach=true
	fi
	case "$approach" in
	sound | questionable | rethink) ;;
	*) if [[ "$has_approach" == true ]]; then approach=unknown; else approach=skipped; fi ;;
	esac
	ready=$(normalize_ready "$(last_verdict 'ready to merge' "$body")")
	if [[ "$has_approach" == true ]] &&
		! grep -qiE '^[[:space:]*_>-]*ready to merge[*_]*[?:]' <<<"$body" &&
		[[ $(jq -Rs -L "${LIB_DIR:?}" 'include "records"; _sections | length' <<<"$body") == 0 ]]; then
		code_review=false
	fi
	jq -L "${LIB_DIR:?}" --argjson prev "${2:-null}" --argjson round "$3" \
		--argjson pr "$4" --arg approach "$approach" --arg ready "$ready" --argjson code_review "$code_review" \
		'include "records"; backfill_record(.; $prev; $round; $pr; $approach; $ready; $code_review)' <<<"$1"
}
