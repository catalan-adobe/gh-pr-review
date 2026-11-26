#!/usr/bin/env bash
# Runs `gh pr-review rounds` against a stub gh: rows, commits between rounds, sources, labels and the decision line.
# Conditions are single-quoted on purpose: expect() evals them after each run sets out and rc.
# shellcheck disable=SC2016,SC2034,SC2329
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
stub=$(mktemp -d)
fail=0

nl=$'\n'
backfill_body="<!-- gh-pr-review generated -->${nl}### Approach${nl}**Approach:** Questionable${nl}${nl}### Issues${nl}"
backfill_body+="#### 🚨 Critical (Must Fix Before Merge)${nl}- **\`a.js:1\` — crit.**${nl}"
backfill_body+="#### ⚠️ Important (Should Fix)${nl}- **\`b.js:2\` — imp one.**${nl}- **\`c.js:3\` — imp two.**${nl}"
backfill_body+="#### 💡 Minor (Nice to Have)${nl}*(none found)*${nl}### Assessment${nl}**Ready to merge?** No"
# The marker's round, head and time are stale on purpose: GitHub's position, commit_id and submitted_at win.
marker='{"schema":1,"source":"model","round":7,"head_sha":"stale00","posted_at":"2030-01-01T00:00:00Z",'
marker+='"approach":"sound","ready":"yes-with-fixes","code_review":true,"findings":[],'
marker+='"counts":{"open_blocking":1,"critical":0,"important":1,"minor":1}}'
marker_body="<!-- gh-pr-review generated -->${nl}<!-- gh-pr-review:round ${marker} -->${nl}**Ready to merge?** Yes with fixes"
rethink_body="<!-- gh-pr-review generated -->${nl}### Approach${nl}**Approach:** Rethink"

jq -n --arg b "$backfill_body" --arg m "$marker_body" --arg r "$rethink_body" '[
	{body: "plain human review", commit_id: "x", submitted_at: "2026-01-01T08:00:00Z", user: {login: "carol"}},
	{body: $r, commit_id: "ddddddd4", submitted_at: "2026-01-04T10:00:00Z", user: {login: "me"}},
	{body: $b, commit_id: "aaaaaaa1", submitted_at: "2026-01-02T10:00:00Z", user: {login: "me"}, state: "CHANGES_REQUESTED"},
	{body: $m, commit_id: "bbbbbbb2", submitted_at: "2026-01-03T10:00:00Z", user: {login: "me"}}]' >"$stub/reviews.json"
jq -n '[{commit: {committer: {date: "2026-01-01T09:00:00Z"}}}, {commit: {committer: {date: "2026-01-02T12:00:00Z"}}},
	{commit: {committer: {date: "2026-01-02T13:00:00Z"}}}, {commit: {committer: {date: "2026-01-03T12:00:00Z"}}}]' \
	>"$stub/commits.json"
cat >"$stub/gh" <<S
#!/usr/bin/env bash
case "\$*" in
*pulls/1/reviews*) cat "$stub/reviews.json" ;;
*pulls/1/commits*) cat "$stub/commits.json" ;;
*issues/1/comments*) cat "$stub/comments.json" ;;
*pulls/1/comments*) echo '[]' ;;
*"pr view"*) echo '{"additions":10,"deletions":2,"changedFiles":3,"headRefOid":"eeeeeee5","author":{"login":"bob"}}' ;;
*) echo "unexpected gh call: \$*" >&2; exit 9 ;;
esac
S
chmod +x "$stub/gh"
echo '[]' >"$stub/comments.json"

rounds() { # args... -> stdout of cmd_rounds
	PATH="$stub:$PATH" LIB_DIR="$root/lib" GH_PR_REVIEW_USER='' bash -c '
		set -euo pipefail
		for f in "$LIB_DIR"/*.sh; do source "$f"; done
		cmd_rounds "$@"' _ "$@" 2>&1
}

expect() { # name condition
	if eval "$2"; then echo "ok   $1"; else
		echo "FAIL $1 ($2)"
		printf '%s\n' "$out" | sed 's/^/     | /'
		fail=1
	fi
}

out=$(rounds https://h/o/r/pull/1) && rc=0 || rc=$?
row() { grep -E "^$1 " <<<"$out" | tr -s ' '; }
expect "rounds: runs" '[[ $rc == 0 ]]'
expect "rounds: header" 'grep -q "^ROUND .*LABEL .*SOURCE" <<<"$out"'
expect "rounds: the plain review is not a round" '[[ $(grep -cE "^[0-9]+ " <<<"$out") == 3 ]]'
expect "rounds: round 1 is backfilled from the Markdown" '[[ $(row 1) == "1 01-02 10:00 aaaaaaa 1 questionable no 1 2 0 early backfill" ]]'
expect "rounds: round 2 comes from its marker" '[[ $(row 2) == "2 01-03 10:00 bbbbbbb 2 sound yes-with-fixes 0 1 1 early model" ]]'
expect "rounds: a Rethink round has no counts" '[[ $(row 3) == "3 01-04 10:00 ddddddd 1 rethink unknown – – – rethink backfill" ]]'
expect "rounds: the next-round line" 'grep -q "^next round: run · early" <<<"$out"'

out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "rounds --json: records and decision" '[[ $rc == 0 && $(jq -r "(.records | length), .decision.decision, .decision.next_round" <<<"$out" | paste -sd, -) == "3,run,4" ]]'

expect "rounds --json: backfill keeps the review state as the decision" \
	'[[ $(jq -r ".records[0] | .source, .decision" <<<"$out" | paste -sd, -) == "backfill,request-changes" ]]'
expect "rounds --json: GitHub's position, commit and time win over the marker's" \
	'[[ $(jq -r ".records[1] | .round, .head_sha, .posted_at" <<<"$out" | paste -sd, -) == "2,bbbbbbb2,2026-01-03T10:00:00Z" ]]'
expect "rounds --json: a backfilled round keeps the history's ID floor" \
	'[[ $(jq -c "[.records[0].last_ids.F, .records[2].last_ids.F]" <<<"$out") == "[3,3]" ]]'

# Rounds posted at once, all marked round 1. One has neither commit_id nor submitted_at on GitHub (it sorts first),
# one has no commit_id, and a pending review is not a round.
one='{"schema":1,"round":1,"head_sha":"m1","posted_at":"2026-03-01T00:00:00Z","code_review":true,"counts":{"open_blocking":0}}'
cp "$stub/reviews.json" "$stub/reviews.saved"
jq -n --arg m "<!-- gh-pr-review generated -->${nl}<!-- gh-pr-review:round ${one} -->${nl}x" '[
	{body: $m, commit_id: "c1", submitted_at: "2026-03-01T00:00:00Z", user: {login: "me"}},
	{body: $m, commit_id: null, submitted_at: "2026-03-01T00:00:05Z", user: {login: "ann"}},
	{body: $m, commit_id: null, submitted_at: null, user: null},
	{body: $m, commit_id: "c9", submitted_at: null, user: {login: "me"}, state: "PENDING"}]' >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "rounds: duplicate marker rounds are numbered by submission order" \
	'[[ $(jq -c "[.records[] | .round]" <<<"$out") == "[1,2,3]" ]]'
expect "rounds: the marker's head and time stay when GitHub has none" \
	'[[ $(jq -r ".records[0] | .head_sha, .posted_at" <<<"$out" | paste -sd, -) == "m1,2026-03-01T00:00:00Z" &&
		$(jq -r ".records[1:][] | .head_sha, .reviewer" <<<"$out" | paste -sd, -) == "c1,me,m1,ann" ]]'
cp "$stub/reviews.saved" "$stub/reviews.json"

# A history far past the argument limits (128 KiB per argument on Linux, 1 MiB in all on macOS): 20 rounds of
# about 60,000 characters each.
cp "$stub/reviews.json" "$stub/reviews.saved"
jq -n '[range(1; 21) as $r | {schema: 1, round: $r, head_sha: "h\($r)", code_review: true,
		counts: {open_blocking: 0}, findings: [range(500) | {id: "F\(.)", severity: "minor", title: ("t" * 100)}]}
	| {body: ("<!-- gh-pr-review generated -->\n<!-- gh-pr-review:round " + tojson + " -->\nx"), commit_id: .head_sha,
		submitted_at: "2026-04-\(if .round < 10 then "0" else "" end)\(.round)T00:00:00Z", user: {login: "me"}}]' \
	>"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "rounds --json: a history past the argument limit" \
	'[[ $rc == 0 && $(jq -r ".records | length, (.[19].findings | length)" <<<"$out" | paste -sd, -) == "20,500" ]]'
cp "$stub/reviews.saved" "$stub/reviews.json"

lifted() { # comments-json -> lifted_since's answer for a stop after 2026-01-04
	printf '%s' "$1" >"$stub/comments.json"
	PATH="$stub:$PATH" LIB_DIR="$root/lib" bash -c 'for f in "$LIB_DIR"/*.sh; do source "$f"; done
		lifted_since h o r 1 2026-01-04T10:00:00Z bob' 2>&1
}
late='"created_at": "2026-02-01T00:00:00Z", "body": "x"'
out=$(lifted "[{\"user\": {\"login\": \"dave\", \"type\": \"User\"}, $late}]")
expect "lifted_since: another person lifts" '[[ $out == true ]]'
out=$(lifted "[{\"user\": null, $late}]")
expect "lifted_since: a comment with no user does not lift" '[[ $out == false ]]'
out=$(lifted "[{\"user\": {\"login\": \"\", \"type\": \"User\"}, $late}]")
expect "lifted_since: an empty login does not lift" '[[ $out == false ]]'
out=$(lifted "[{\"user\": {\"login\": \"ghost\", \"type\": \"User\"}, $late}]")
expect "lifted_since: GitHub's deleted-account placeholder (ghost) does not lift" '[[ $out == false ]]'
echo '[]' >"$stub/comments.json"

out=$(rounds) && rc=0 || rc=$?
expect "rounds: a PR is required" '[[ $rc != 0 && $out == *Usage* ]]'
exit "$fail"
