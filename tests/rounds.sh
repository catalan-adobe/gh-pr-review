#!/usr/bin/env bash
# Runs `gh pr-review rounds` against a stub gh: rows, commits between rounds, sources, labels and the decision line.
# Conditions are single-quoted on purpose: expect() evals them after each run sets out and rc.
# shellcheck disable=SC2016,SC2034,SC2329
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
stub=$(mktemp -d)
# The script must reach its end: Bash 3.2 can stop on an error inside an EXIT trap with status 0.
finished=false
trap '[[ $finished == true ]] || { echo "FAIL stopped before the end"; exit 1; }' EXIT
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

# Rounds posted at once, all marked round 1, each with its new finding F1. One has neither commit_id nor submitted_at
# on GitHub (it sorts first), one has no commit_id, and a pending review is not a round. The last one claims its
# right round, 4, but reuses F2, which an earlier round already gave out.
one='{"schema":1,"round":1,"head_sha":"m1","posted_at":"2026-03-01T00:00:00Z","code_review":true,"counts":{"open_blocking":1},'
one+='"findings":[{"id":"F1","severity":"important","status":"new","first_round":1,"title":"a"}],"last_ids":{"F":1,"L":0}}'
four='{"schema":1,"round":4,"code_review":true,"counts":{"open_blocking":0},"last_ids":{"F":2,"L":0},'
four+='"findings":[{"id":"F2","severity":"minor","status":"new","first_round":4}]}'
cp "$stub/reviews.json" "$stub/reviews.saved"
jq -n --arg m "<!-- gh-pr-review generated -->${nl}<!-- gh-pr-review:round ${one} -->${nl}x" \
	--arg four "<!-- gh-pr-review generated -->${nl}<!-- gh-pr-review:round ${four} -->${nl}x" '[
	{body: $m, commit_id: "c1", submitted_at: "2026-03-01T00:00:00Z", user: {login: "me"}},
	{body: $m, commit_id: null, submitted_at: "2026-03-01T00:00:05Z", user: {login: "ann"}},
	{body: $m, commit_id: null, submitted_at: null, user: null},
	{body: $m, commit_id: "c9", submitted_at: null, user: {login: "me"}, state: "PENDING"},
	{body: $four, commit_id: "c4", submitted_at: "2026-03-02T00:00:00Z", user: {login: "me"}}]' >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "rounds: duplicate marker rounds are numbered by submission order" \
	'[[ $(jq -c "[.records[] | .round]" <<<"$out") == "[1,2,3,4]" ]]'
expect "rounds: the marker's head and time stay when GitHub has none" \
	'[[ $(jq -r ".records[0] | .head_sha, .posted_at" <<<"$out" | paste -sd, -) == "m1,2026-03-01T00:00:00Z" &&
		$(jq -r ".records[1:3][] | .head_sha, .reviewer" <<<"$out" | paste -sd, -) == "c1,me,m1,ann" ]]'
expect "rounds: rounds posted at once get their own new IDs, first_round and last_ids" \
	'[[ $(jq -c "[.records[] | [.findings[0].id, .findings[0].first_round, .last_ids.F]]" <<<"$out") == \
		"[[\"F1\",1,1],[\"F2\",2,2],[\"F3\",3,3],[\"F4\",4,4]]" ]]'
expect "rounds: reconciling keeps the rest of the finding" \
	'[[ $(jq -c "[.records[2].findings[0] | .severity, .status, .title]" <<<"$out") == "[\"important\",\"new\",\"a\"]" ]]'
cp "$stub/reviews.saved" "$stub/reviews.json"

# Two runs claim round 1 with one new finding each, F1; the later marker was compacted (findings_dropped, counts kept).
# Its F1 is the floor's next ID, F2, so round 3 numbers from F3.
cp "$stub/reviews.json" "$stub/reviews.saved"
dropped='{"schema":1,"round":1,"code_review":true,"findings_dropped":true,"last_ids":{"F":1,"L":0},'
dropped+='"counts":{"open_blocking":1,"critical":0,"important":1,"minor":0,"new":1}}'
jq -n --arg m "<!-- gh-pr-review generated -->${nl}<!-- gh-pr-review:round ${one} -->${nl}x" \
	--arg d "<!-- gh-pr-review generated -->${nl}<!-- gh-pr-review:round ${dropped} -->${nl}x" '[
	{body: $m, commit_id: "c1", submitted_at: "2026-03-01T00:00:00Z", user: {login: "me"}},
	{body: $d, commit_id: "c1", submitted_at: "2026-03-01T00:00:01Z", user: {login: "ann"}}]' >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "rounds: a compacted round posted at once takes the floor's next IDs" \
	'[[ $rc == 0 && $(jq -c "[.records[] | [.round, .last_ids.F]]" <<<"$out") == "[[1,1],[2,2]]" ]]'
expect "rounds: after it, round 3 numbers from F3" \
	'[[ $(jq -c -L "$root/lib" "include \"records\"; .records | id_floor.F + 1" <<<"$out") == 3 ]]'
cp "$stub/reviews.saved" "$stub/reviews.json"

# A processing step that fails inside fetch_round_records (here: reconciling a record) fails the whole read: no
# output, status 1. Callers run it in conditions, where errexit would not stop it.
real_jq=$(command -v jq)
mkdir -p "$stub/brokenjq"
cat >"$stub/brokenjq/jq" <<S
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == *'reconcile_record('* ]] && exit 5; done
exec "$real_jq" "\$@"
S
chmod +x "$stub/brokenjq/jq"
out=$(PATH="$stub/brokenjq:$stub:$PATH" LIB_DIR="$root/lib" bash -c '
	for f in "$LIB_DIR"/*.sh; do source "$f"; done
	if records=$(fetch_round_records h o r 1); then echo "status 0: $records"; else echo "status $?: $records"; fi' 2>/dev/null)
rc=0
expect "fetch_round_records: a failing step fails the read, with no output" '[[ $out == "status 1: " ]]'

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
finished=true
exit "$fail"
