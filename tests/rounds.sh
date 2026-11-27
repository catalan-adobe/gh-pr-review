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
*pulls/1/reviews*) jq 'map(.author_association //= "MEMBER")' "$stub/reviews.json" ;; # members unless set
*" user --jq"*)
	# user.fail: how many reads of this account's login fail from now on.
	n=\$(cat "$stub/user.fail" 2>/dev/null || echo 0)
	[[ "\$n" -gt 0 ]] && { echo "\$((n - 1))" >"$stub/user.fail"; exit 1; }
	echo me ;;
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

# A code-review marker without counts: never 0. The counts come from its findings when they show the Markdown's
# blockers, else from the Markdown; when neither can say, the round's blocking is unknown, and it is never ready.
cp "$stub/reviews.json" "$stub/reviews.saved"
nocounts() { # findings-json review-markdown -> a generated review whose marker has no counts
	jq -n --argjson f "$1" --arg md "$2" '{schema: 1, round: 1, code_review: true, approach: "sound",
		ready: "yes-with-fixes", findings: $f} | {commit_id: "c1", submitted_at: "2026-03-01T00:00:00Z", user: {login: "me"},
		body: ("<!-- gh-pr-review generated -->\n<!-- gh-pr-review:round " + tojson + " -->\n" + $md)}'
}
crit_md="#### 🚨 Critical (Must Fix Before Merge)${nl}- **\`a.js:1\` — boom.**${nl}${nl}### Assessment${nl}**Ready to merge?** Yes, with fixes"
f1='[{"id":"F1","severity":"critical","status":"new","file":"a.js","line":1,"title":"boom"}]'
jq -s . <(nocounts "$f1" "$crit_md") >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "no counts in a code-review marker: rebuilt from its findings, not ready" \
	'[[ $rc == 0 && $(jq -c "[.decision.series, .decision.label, .records[0].counts.critical]" <<<"$out") == "[[1],\"early\",1]" ]]'
jq -s . <(nocounts '[]' "$crit_md") >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "no counts, findings missing the Markdown's Critical: counted from the Markdown" \
	'[[ $rc == 0 && $(jq -c "[.decision.series, .decision.label]" <<<"$out") == "[[1],\"early\"]" ]]'
expect "no counts, findings missing the Markdown's Critical: the list that failed the check is dropped" \
	'[[ $(jq -c ".records[0] | [has(\"findings\"), .findings_dropped, .counts.critical]" <<<"$out") == "[false,true,1]" ]]'
plain_md="#### 🚨 Critical (Must Fix Before Merge)${nl}- \`a.js:1\` — boom.${nl}${nl}### Assessment${nl}**Ready to merge?** Yes"
jq -s . <(nocounts '[]' "$plain_md") >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "no counts: a plain bullet under Critical counts from the Markdown" \
	'[[ $rc == 0 && $(jq -c "[.records[0].counts.critical, .decision.series, .decision.label]" <<<"$out") == "[1,[1],\"early\"]" ]]'
jq -s '.[0].body |= sub("\"findings\":\\[\\]"; "\"findings\":[],\"counts\":{\"critical\":1,\"important\":0}")' \
	<(nocounts '[]' "$plain_md") >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "no open_blocking but critical and important: their sum, not the Markdown; the list that can't account for it is dropped" \
	'[[ $rc == 0 && $(jq -c ".records[0] | [.counts.critical, .counts.open_blocking, has(\"findings\"), .findings_dropped]" <<<"$out") == "[1,1,false,true]" &&
		$(jq -r .decision.label <<<"$out") == early ]]'
# Counts that contradict a Critical both the marker's findings and the Markdown show (critical 0, important 0): the
# sum is not used, the findings are, and the round is not ready.
a7_md="#### 🚨 Critical (Must Fix Before Merge)${nl}- **\`a.go:7\` — boom.**${nl}${nl}### Assessment${nl}**Ready to merge?** Yes with fixes"
jq -s '.[0].body |= sub("\"findings\":\\["; "\"counts\":{\"critical\":0,\"important\":0},\"findings\":[")' \
	<(nocounts '[{"id":"F1","severity":"critical","status":"new","file":"a.go","line":7}]' "$a7_md") >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "no open_blocking, critical and important 0 next to a visible Critical: 1 blocker, not ready" \
	'[[ $rc == 0 && $(jq -c "[.records[0].counts.open_blocking, .records[0].counts.critical, .decision.label]" <<<"$out") == "[1,1,\"early\"]" ]]'
jq -s '.[0].body |= sub("\"findings\":\\[\\]"; "\"counts\":{\"critical\":0,\"important\":0},\"findings\":[]")' \
	<(nocounts '[]' "$a7_md") >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "the same with no findings: the Markdown's 1 blocker, not ready" \
	'[[ $rc == 0 && $(jq -c "[.records[0].counts.open_blocking, .records[0].findings_dropped, .decision.label]" <<<"$out") == "[1,true,\"early\"]" ]]'
# An older marker (no last_ids) whose F1 is a Critical the Markdown says it has none of: its list is dropped, but F1
# stays reserved: the next new finding is F2.
jq -s . <(nocounts '[{"id":"F1","severity":"critical","status":"new"}]' \
	"#### 🚨 Critical (Must Fix Before Merge)${nl}*(none found)*${nl}${nl}### Assessment${nl}**Ready to merge?** Yes") >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "a dropped list keeps its highest ID: the next new finding is F2" \
	'[[ $rc == 0 && $(jq -c -L "$root/lib" "include \"records\"; [.records[0] | has(\"findings\"), .findings_dropped, .last_ids.F, .counts.open_blocking] + [.decision.label, (.records | id_floor.F + 1)]" <<<"$out") == "[false,true,1,0,\"ready\",2]" ]]'
jq -s . <(nocounts '[]' "Looks fine.${nl}${nl}**Ready to merge?** Yes, with fixes") >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "no counts, no findings and no severity heading: blocking unknown, not ready" \
	'[[ $rc == 0 && $(jq -c "[.decision.series, .decision.label, .records[0].counts.open_blocking]" <<<"$out") == "[[null],\"unknown\",null]" ]]'
out=$(rounds https://h/o/r/pull/1) && rc=0 || rc=$?
expect "no counts: the table shows dashes and the unknown label" '[[ $rc == 0 && $(row 1) == *" – – – unknown –" ]]'
minimal='{"schema":1,"round":1,"findings_dropped":true,"last_ids":{"F":0,"L":0}}'
jq -n --arg b "<!-- gh-pr-review generated -->${nl}<!-- gh-pr-review:round ${minimal} -->${nl}Looks fine.${nl}${nl}**Ready to merge?** Yes" \
	'[{body: $b, commit_id: "c1", submitted_at: "2026-03-01T00:00:00Z", user: {login: "me"}}]' >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "a minimal marker and no severity heading: blocking unknown, not ready, as without counts" \
	'[[ $rc == 0 && $(jq -c "[.decision.series, .decision.label, .records[0].counts.open_blocking, .records[0].findings_dropped]" <<<"$out") == "[[null],\"unknown\",null,true]" ]]'
# A later round's Markdown leaves out the findings it carried: with a minimal marker, its blocking count is the
# progress line's (backfill_record), not the Markdown's.
later_md="### Round 2 · since round 1${nl}1 still open · 1 not re-checked · open blocking: 2 (was 2)${nl}${nl}#### 🚨 Critical${nl}*(none found)*${nl}"
later_md+="#### ⚠️ Important${nl}- **F1 · \`a.js:1\`** — boom.${nl}${nl}**Ready to merge?** No"
jq -n --arg b "<!-- gh-pr-review generated -->${nl}<!-- gh-pr-review:round ${minimal/\"round\":1/\"round\":2} -->${nl}${later_md}" \
	'[{body: $b, commit_id: "c2", submitted_at: "2026-03-01T00:00:00Z", user: {login: "me"}}]' >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "a minimal marker on a later round: blocking from its progress line, not the Markdown" \
	'[[ $rc == 0 && $(jq -c ".records[0] | [.counts.open_blocking, .findings_dropped]" <<<"$out") == "[2,true]" ]]'
jq -n --arg b "<!-- gh-pr-review generated -->${nl}<!-- gh-pr-review:round ${minimal} -->${nl}### Approach${nl}**Approach:** Rethink" \
	'[{body: $b, commit_id: "c1", submitted_at: "2026-03-01T00:00:00Z", user: {login: "me"}}]' >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "a minimal Rethink marker keeps a counts object, all null, as any Rethink record" \
	'[[ $rc == 0 && $(jq -c "[.records[0] | .code_review, (.counts | type), .counts.open_blocking] + [.decision.labels[0]]" <<<"$out") == "[false,\"object\",null,\"rethink\"]" ]]'
cp "$stub/reviews.saved" "$stub/reviews.json"

# This PR's round 5, as posted (tests/fixtures/reviews/pr8-round5.md), after rounds 1–4 with 8, 6, 4 and 4 blockers.
# pr8 <filter> changes its marker with a jq filter. Read back, its findings keep the statuses it stored: F21 and F22
# stay fixed, never open, so the round keeps its 3 blockers, 5 fixed and its label, nit-loop.
cp "$stub/reviews.json" "$stub/reviews.saved"
pr8() { # jq filter on round 5's marker -> reviews.json: rounds 1–4, then round 5 with that marker
	local marker
	marker=$(sed -n 2p "$root/tests/fixtures/reviews/pr8-round5.md" | sed 's/^<!-- gh-pr-review:round //; s/ -->$//' |
		jq -c "$1" | sed 's/--/-\\u002d/g')
	jq -n --rawfile b "$root/tests/fixtures/reviews/pr8-round5.md" --arg m "<!-- gh-pr-review:round ${marker} -->" '
		[[8, 0], [6, 1], [4, 0], [4, 0]] as $c
		| [range(4) as $i | {schema: 1, round: ($i + 1), code_review: true, approach: "sound", ready: "no",
			counts: {open_blocking: $c[$i][0], critical: $c[$i][1], important: ($c[$i][0] - $c[$i][1])}}
			| {body: ("<!-- gh-pr-review generated -->\n<!-- gh-pr-review:round " + tojson + " -->\nx"),
				commit_id: "c\($i + 1)", submitted_at: "2026-11-2\($i + 1)T00:00:00Z", user: {login: "me"}}]
		+ [{body: ($b | split("\n") | .[1] = $m | join("\n")), commit_id: "c5", submitted_at: "2026-11-27T11:57:47Z",
			user: {login: "me"}}]' >"$stub/reviews.json"
}
round5() { jq -c '[.records[4] | .counts.open_blocking, .counts.fixed, ([.findings[]? | select(.id == "F21" or .id == "F22") | .status] | join(" "))] + [.decision.labels[4]]' <<<"$out"; }
pr8 .
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "PR 8 round 5 as posted: 3 blockers, 5 fixed, nit-loop" \
	'[[ $rc == 0 && $(round5) == "[3,5,\"fixed fixed\",\"nit-loop\"]" ]]'
pr8 'del(.counts)'
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "PR 8 round 5 without counts: its fixed findings stay fixed, not open: 3 blockers, 5 fixed, nit-loop" \
	'[[ $rc == 0 && $(round5) == "[3,5,\"fixed fixed\",\"nit-loop\"]" ]]'
# The same round with its counts and lists damaged in other ways. Whatever is missing, the round read back never shows
# fewer blockers than its Markdown (3 Important), never counts F21 or F22 (fixed) as open, and never lowers the ID
# floor below round 5's F30, even with last_ids gone and the list dropped. Each line: the marker filter, "~", then
# [open_blocking, fixed, the statuses of F21 and F22 when the list is kept, the label, the ID floor].
while IFS='~' read -r filter want; do
	pr8 "$filter"
	out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
	expect "PR 8 round 5, $filter: $want" \
		'[[ $rc == 0 && $(jq -c -L "$root/lib" "include \"records\"; [.records[4] | .counts.open_blocking, .counts.fixed, ([.findings[]? | select(.id == \"F21\" or .id == \"F22\") | .status] | join(\" \"))] + [.decision.labels[4], (.records | id_floor.F)]" <<<"$out") == "$want" ]]'
done <<'T'
del(.counts.open_blocking)~[3,5,"fixed fixed","nit-loop",30]
.counts = {critical: 0, important: 0}~[3,5,"fixed fixed","nit-loop",30]
.counts = {critical: 0, important: 2}~[3,5,"fixed fixed","nit-loop",30]
del(.last_ids) | .counts = {critical: 0, important: 5}~[5,null,"","churning",30]
del(.last_ids, .counts) | .findings |= map(if .id == "F28" then .status = "fixed" else . end)~[3,5,"","nit-loop",30]
T

# A later round's marker read back without counts (#9): its findings keep the statuses round 2 stored. F1 (Critical)
# is fixed and F2 declined with a reason: not open. F3 (Important) and F4 (Critical) are carried, open and unverified:
# the Markdown leaves them out (its Critical section says none), yet they still count, and the list is kept: it shows
# the Markdown's F5 and the progress line's 3 blockers.
r1_marker='{"schema":1,"round":1,"code_review":true,"approach":"sound","ready":"no","last_ids":{"F":4,"L":0},
	"counts":{"open_blocking":4,"critical":2,"important":2,"minor":0,"new":4,"fixed":0,"declined":0,"regressed":0}}'
r2_marker='{"schema":1,"round":2,"mode":"incremental","code_review":true,"approach":"sound","ready":"no","findings":[
	{"id":"F1","severity":"critical","status":"fixed","first_round":1,"in_delta":false,"file":"a.go","line":1},
	{"id":"F2","severity":"important","status":"declined","first_round":1,"in_delta":false,"file":"b.go","line":2},
	{"id":"F3","severity":"important","status":"open","first_round":1,"in_delta":false,"file":"c.go","line":3,"unverified":true},
	{"id":"F4","severity":"critical","status":"open","first_round":1,"in_delta":false,"file":"d.go","line":4,"unverified":true},
	{"id":"F5","severity":"important","status":"new","first_round":2,"in_delta":true,"file":"e.go","line":5}],
	"later":[{"id":"L1","severity":"minor","file":"z.go","line":9}],"last_ids":{"F":5,"L":1},
	"counts":{"open_blocking":3,"critical":1,"important":2,"minor":0,"new":1,"fixed":1,"declined":1,"regressed":0,"later":1,"unverified":2}}'
r2_md="### Round 2 · since round 1${nl}1 fixed · 1 new · 1 declined · 1 for later · 2 not re-checked · open blocking: 3 (was 4)"
r2_md+=" · loop: converging${nl}${nl}### Issues${nl}${nl}#### 🚨 Critical (Must Fix Before Merge)${nl}*(none found)*${nl}${nl}"
r2_md+="#### ⚠️ Important (Should Fix)${nl}${nl}- **\`e.go:5\`** — five.${nl}${nl}#### 💡 Minor (Nice to Have)${nl}"
r2_md+="*(none found)*${nl}${nl}<details><summary>Fixed since the last round (2)</summary>${nl}${nl}- **F1** — fixed.${nl}"
r2_md+="- **F2** — declined: \"by design\"${nl}${nl}</details>${nl}${nl}<details><summary>Later (1)</summary>${nl}${nl}"
r2_md+="- **\`z.go:9\`** — later.${nl}${nl}</details>${nl}${nl}**Ready to merge?** No"
later2() { # jq filter on round 2's marker -> reviews.json: round 1 (4 blockers), then round 2
	jq -n --argjson m1 "$r1_marker" --argjson m2 "$(jq -c "$1" <<<"$r2_marker")" --arg md "$r2_md" '
		def review($m; $md; $c; $t): {commit_id: $c, submitted_at: $t, user: {login: "me"},
			body: ("<!-- gh-pr-review generated -->\n<!-- gh-pr-review:round " + ($m | tojson) + " -->\n" + $md)};
		[review($m1; "x"; "c1"; "2026-03-01T00:00:00Z"), review($m2; $md; "c2"; "2026-03-02T00:00:00Z")]' \
		>"$stub/reviews.json"
}
round2() { # [open_blocking, critical, important, fixed, declined, findings_dropped, statuses F1–F5, last_ids.L, floor]
	jq -c -L "$root/lib" 'include "records"; [.records[1] | .counts.open_blocking, .counts.critical, .counts.important,
		.counts.fixed, .counts.declined, (.findings_dropped // false), ([.findings[]?.status] | join(" ")), .last_ids.L]
		+ [(.records | id_floor | [.F, .L])]' <<<"$out"
}
# Without the carried findings (or with counts below the progress line's 3 blockers) the list can't account for the
# progress line: it is dropped, keeping its F and L IDs (in last_ids, or from the later list), and the counts come from
# the Markdown (1 Important, 1 fixed, 1 declined) with the progress line's open blocking count.
# Each line: the marker filter, "~", then round2's output.
while IFS='~' read -r filter want; do
	later2 "$filter"
	out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
	expect "later round 2, $filter: $want" '[[ $rc == 0 && $(round2) == "$want" ]]'
done <<'T'
.~[3,1,2,1,1,false,"fixed declined open open new",1,[5,1]]
del(.counts)~[3,1,2,1,1,false,"fixed declined open open new",1,[5,1]]
del(.counts.open_blocking)~[3,1,2,1,1,false,"fixed declined open open new",1,[5,1]]
.counts = {critical: 0, important: 1}~[3,1,2,1,1,false,"fixed declined open open new",1,[5,1]]
del(.counts, .last_ids)~[3,1,2,1,1,false,"fixed declined open open new",null,[5,1]]
del(.counts) | .findings |= map(select(.unverified | not))~[3,0,1,1,1,true,"",1,[5,1]]
del(.counts, .last_ids) | .findings |= map(select(.unverified | not))~[3,0,1,1,1,true,"",1,[5,1]]
del(.counts, .later) | .findings |= map(select(.unverified | not))~[3,0,1,1,1,true,"",1,[5,1]]
.counts = {critical: 0, important: 1} | .findings = []~[3,0,1,1,1,true,"",1,[5,1]]
T
cp "$stub/reviews.saved" "$stub/reviews.json"

# Only trusted reviews are rounds. eve, a contributor, posts a generated review on the PR's head: not a round, so the
# decision is not nothing-new, and the table says it was left out. My own review counts even as a contributor.
cp "$stub/reviews.json" "$stub/reviews.saved"
jq --arg b "<!-- gh-pr-review generated -->${nl}**Ready to merge?** No" '. + [
	{body: $b, commit_id: "eeeeeee5", submitted_at: "2026-01-05T10:00:00Z", user: {login: "eve"}, author_association: "CONTRIBUTOR"},
	{body: $b, commit_id: "eeeeeee5", submitted_at: "2026-01-05T11:00:00Z", user: {login: "eve"}, author_association: "NONE"}]' \
	"$stub/reviews.saved" >"$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1) && rc=0 || rc=$?
expect "trust: an outsider's generated reviews are not rounds" '[[ $rc == 0 && $(grep -cE "^[0-9]+ " <<<"$out") == 3 ]]'
expect "trust: the line under the table names them" \
	'grep -qx "ignored: 2 generated reviews by @eve (not a member or collaborator of the repo)" <<<"$out" &&
		[[ $(grep -A1 "^3 " <<<"$out" | tail -1) == "ignored: "* ]]'
expect "trust: the decision does not see them" 'grep -q "^next round: run" <<<"$out"'
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "trust: --json lists them" \
	'[[ $(jq -c "[(.records | length), .decision.decision, .ignored]" <<<"$out") == "[3,\"run\",[{\"login\":\"eve\",\"association\":\"CONTRIBUTOR\"},{\"login\":\"eve\",\"association\":\"NONE\"}]]" ]]'
jq '.[-1].user.login = "me" | .[-1].author_association = "CONTRIBUTOR"' "$stub/reviews.json" >"$stub/r.json"
mv "$stub/r.json" "$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "trust: my own review counts where I am only a contributor" \
	'[[ $(jq -c "[(.records | length), .decision.decision, (.ignored | length)]" <<<"$out") == "[4,\"nothing-new\",1]" ]]'
echo 1 >"$stub/user.fail"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "trust: the login read fails once: the retry reads it, and my review still counts" \
	'[[ $rc == 0 && $(jq -c "[(.records | length), .decision.decision]" <<<"$out") == "[4,\"nothing-new\"]" ]]'
echo 2 >"$stub/user.fail"
out=$(rounds https://h/o/r/pull/1 --json) && rc=0 || rc=$?
expect "trust: the login read fails twice: rounds fails and says why" \
	'[[ $rc == 1 && $out == *"could not read the account running the tool, so the round history can'"'"'t be checked"* &&
		$out != *records* ]]'
rm -f "$stub/user.fail"
out=$(rounds https://h/o/r/pull/1) && rc=0 || rc=$?
expect "trust: one left out, one author" 'grep -qx "ignored: 1 generated review by @eve (not a member or collaborator of the repo)" <<<"$out"'
cp "$stub/reviews.saved" "$stub/reviews.json"
out=$(rounds https://h/o/r/pull/1) && rc=0 || rc=$?
expect "trust: no ignored line when none is left out" '! grep -q "^ignored" <<<"$out"'

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
