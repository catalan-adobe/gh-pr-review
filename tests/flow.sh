#!/usr/bin/env bash
# Runs the whole gh-pr-review script with stub git, gh and pi, and checks the orchestration:
# how many model calls run, what the code review gets, and what is posted.
# Conditions are single-quoted on purpose: expect() evals them after each run sets rc, calls, body and flag.
# shellcheck disable=SC2016,SC2034,SC2329 # SC2329: helpers such as no_session run inside expect's eval
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fail=0

setup() { # approach-output code-review-output [discussion-exit-code] [failing-pass: owner|code]
	stub=$(mktemp -d)
	mkdir -p "$stub/bin" "$stub/home/.pi/agent" "$stub/work"
	: >"$stub/pi.calls"
	echo '{"github-copilot":{}}' >"$stub/home/.pi/agent/auth.json"
	printf '%s' "$1" >"$stub/approach.out"
	printf '%s' "$2" >"$stub/review.out"
	echo '{"comments":[],"reviews":[]}' >"$stub/discussion.json"
	echo '[]' >"$stub/rest-reviews.json"
	echo '[]' >"$stub/rest-comments.json"
	cat >"$stub/bin/gh" <<S
#!/usr/bin/env bash
case "\$*" in
*pulls/1/reviews*) cat "$stub/rest-reviews.json" ;;
*issues/1/comments*) cat "$stub/rest-comments.json" ;;
*pulls/1/comments*) echo '[]' ;;
*"auth status"*) exit 0 ;;
*"api"*user*) echo me ;;
*graphql*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
*"--json comments,reviews"*) [[ "${3:-0}" == 0 ]] || exit ${3:-0}; cat "$stub/discussion.json" ;;
*"pr view"*) echo '{"title":"T","body":"B","headRefName":"h","baseRefName":"main","author":{"login":"bob"},"additions":1,"deletions":0,"changedFiles":1,"headRefOid":"head1"}' ;;
*"pr review"*) printf '%s\n' "\$@" >"$stub/posted.args" ;;
esac
S
	cat >"$stub/bin/git" <<'S'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == clone ]] && mkdir -p "${@: -1}"; done
case "$*" in *rev-parse*) echo aaaa ;; *merge-base*) echo bbbb ;; esac
S
	cat >"$stub/bin/pi" <<S
#!/usr/bin/env bash
echo call >>"$stub/pi.calls"
if [[ "\${*: -1}" == *"long-time maintainer"* ]]; then [[ "${4:-}" == owner ]] && exit 7
	printf '%s' "\${*: -1}" >"$stub/owner-prompt.txt"; cat "$stub/approach.out"; else
	[[ "${4:-}" == code ]] && exit 7
	printf '%s' "\${*: -1}" >"$stub/code-prompt.txt"; cat "$stub/review.out"; fi
S
	chmod +x "$stub/bin/"*
}

run() { # extra args... (always -y; run_no_y for the interactive path, with no terminal on stdin)
	fresh
	(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
		bash "$root/gh-pr-review" https://github.com/o/r/pull/1 -y "$@" >"$stub/out.log" 2>&1) && rc=0 || rc=$?
	collect
}

run_no_y() { # no extra args: the interactive path, with no terminal on stdin
	fresh
	(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
		bash "$root/gh-pr-review" https://github.com/o/r/pull/1 </dev/null >"$stub/out.log" 2>&1) && rc=0 || rc=$?
	collect
}

fresh() { # each run starts with no model calls, nothing posted and no session
	: >"$stub/pi.calls"
	rm -rf "$stub/posted.args" "$stub/work/pr-review-sessions"
}

collect() {
	calls=$(wc -l <"$stub/pi.calls" | tr -d ' ')
	body=$(sed -n '/^--body$/,$p' "$stub/posted.args" 2>/dev/null | sed 1d || true)
	flag=$(grep -x -- '--\(comment\|approve\|request-changes\)' "$stub/posted.args" 2>/dev/null || true)
	record=$(cat "$stub"/work/pr-review-sessions/pr-review-*/round.json 2>/dev/null || true)
}

expect() { # name condition
	if eval "$2"; then echo "ok   $1"; else
		echo "FAIL $1 ($2): rc=$rc calls=$calls flag=$flag"
		tail -5 "$stub/out.log"
		fail=1
	fi
}

setup $'### Approach\n**Approach:** Sound' $'### Issues\n**Ready to merge?** Yes'
run
expect "sound: two model calls" '[[ $calls == 2 ]]'
expect "sound: code prompt gets the approach notes" 'grep -q "Maintainer.s approach notes" "$stub/code-prompt.txt"'
expect "sound: code prompt points to the discussion" 'grep -q "context/pr-discussion.md" "$stub/code-prompt.txt"'
expect "sound: code prompt says not to re-raise settled points" 'grep -q "new evidence" "$stub/code-prompt.txt"'
expect "sound: posts approach then review" '[[ $body == *"**Approach:** Sound"*"**Ready to merge?** Yes"* ]]'
expect "sound: approves on bare yes" '[[ $flag == --approve ]]'

setup $'### Approach\n**Approach:** Rethink — use lib/http' 'never used'
run
expect "rethink: one model call" '[[ $calls == 1 ]]'
expect "rethink: posts the approach only" '[[ $body == *"**Approach:** Rethink"* && $body != *"never used"* ]]'
expect "rethink: requests changes" '[[ $flag == --request-changes ]]'

setup $'### Approach\n**Approach:** Rethink\n\nApproach notes: use the shared client.' 'never used'
run
expect "rethink then prose: still one model call" '[[ $calls == 1 ]]'
expect "rethink then prose: requests changes" '[[ $flag == --request-changes ]]'

setup 'no verdict here' $'**Ready to merge?** Yes, with fixes'
run
expect "missing verdict: code review still runs" '[[ $calls == 2 ]]'
expect "qualified yes: comment, not approve" '[[ $flag == --comment ]]'

setup $'**Approach:** Sound' $' \n'
run
expect "empty code review: fails" '[[ $rc != 0 ]]'
expect "empty code review: nothing posted" '[[ -z $flag ]]'
expect "empty code review: names the session" 'grep -q "pr-review-sessions/pr-review-" "$stub/out.log"'

setup 'unused' $'**Ready to merge?** No' 5
run --skip-approach
expect "skip-approach: discussion fetch failure fails the run" '[[ $rc != 0 && -z $flag ]]'

setup 'unused' $'**Ready to merge?** No'
run --skip-approach
expect "skip-approach: one model call" '[[ $calls == 1 ]]'
expect "skip-approach: code prompt points to the discussion" 'grep -q "context/pr-discussion.md" "$stub/code-prompt.txt"'
expect "skip-approach: no approach in body" '[[ $rc == 0 && $body != *"Approach"* ]]'
expect "skip-approach: posts the code review and its decision" '[[ $flag == --request-changes && $body == *"**Ready to merge?** No"* ]]'
setup $'**Approach:** Sound' $'**Ready to merge?** Yes' 0 owner
run
expect "owner pass fails: run fails" '[[ $rc != 0 ]]'
expect "owner pass fails: no code review" '[[ $calls == 1 ]]'
expect "owner pass fails: nothing posted" '[[ -z $flag ]]'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes' 0 code
run
expect "code review fails: run fails" '[[ $rc != 0 ]]'
expect "code review fails: nothing posted" '[[ -z $flag ]]'
expect "code review fails: names the session" 'grep -q "pr-review-sessions/pr-review-" "$stub/out.log"'
setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
run --instructions 'Focus on db/ and $(skip) nits'
expect "instructions: owner prompt gets them" 'grep -qF "Focus on db/ and \$(skip) nits" "$stub/owner-prompt.txt"'
expect "instructions: code prompt gets them" 'grep -qF "Focus on db/ and \$(skip) nits" "$stub/code-prompt.txt"'
expect "instructions: owner prompt has them before the steps" '[[ $(grep -n -e "Reviewer instructions" -e "^## Steps" "$stub/owner-prompt.txt" | head -1) == *instructions* ]]'
expect "instructions: both prompts say not to quote them" 'grep -q "do not quote" "$stub/owner-prompt.txt" && grep -q "do not quote" "$stub/code-prompt.txt"'
expect "instructions: not posted" '[[ $rc == 0 && $body != *"Focus on db/"* ]]'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
run
expect "no instructions: no section in either prompt" '! grep -q "Reviewer instructions" "$stub/owner-prompt.txt" "$stub/code-prompt.txt"'

setup 'unused' 'unused'
run --instructions
expect "instructions without a value: fails before any model call" '[[ $rc != 0 && $calls == 0 ]] && grep -q "requires" "$stub/out.log"'
setup 'unused' 'unused'
run --instructions --no-post
expect "instructions followed by a flag: fails, nothing posted" '[[ $rc != 0 && $calls == 0 && -z $flag ]]'
setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
run --instructions $'- focus on db/\n- skip nits'
expect "instructions as a bullet list: accepted" '[[ $rc == 0 ]] && grep -qF -- "- skip nits" "$stub/code-prompt.txt"'
setup 'unused' 'unused'
run --instructions ' '
expect "blank instructions: fails before any model call" '[[ $rc != 0 && $calls == 0 ]]'

# ── round records
block=$'```json findings\n[{"severity":"important","file":"a.js","line":3,"title":"thing breaks"}]\n```'
setup $'**Approach:** Sound' $'### Issues\n#### ⚠️ Important (Should Fix)\n- **`a.js:3` — thing breaks.**\n\n**Ready to merge?** Yes with fixes\n\n'"$block"
run
expect "records: the code prompt asks for the findings block" 'grep -q "json findings" "$stub/code-prompt.txt"'
expect "records: the findings block is not posted" '[[ $rc == 0 && $body != *"json findings"* && $body == *"thing breaks"* ]]'
expect "records: one round marker is posted" '[[ $(grep -c "gh-pr-review:round" <<<"$body") == 1 ]]'
expect "records: the marker follows the generated marker" '[[ $body == "<!-- gh-pr-review generated -->"$'"'"'\n'"'"'"<!-- gh-pr-review:round "* ]]'
expect "records: round.json has the model findings" '[[ $(jq -r ".source, .round, .findings[0].id, .findings[0].file, .preview, .decision" <<<"$record" | paste -sd, -) == "model,1,F1,a.js,false,comment" ]]'
expect "records: posted.md is the posted body" '[[ -f $(ls -d "$stub"/work/pr-review-sessions/pr-review-*)/posted.md ]]'

block=$'```json findings\n[{"severity":"important","file":"secret/plan.md","line":3,"title":"SECRET note from the instructions"}]\n```'
setup $'**Approach:** Sound' $'### Issues\n#### ⚠️ Important (Should Fix)\n- **`a.js:3` — thing breaks.**\n\n**Ready to merge?** No\n\n'"$block"
run
expect "records: text only in the findings block is not posted" \
	'[[ $rc == 0 && $body == *"gh-pr-review:round"* && $body != *SECRET* && $body != *secret/plan.md* ]]'
expect "records: round.json keeps it" '[[ $(jq -r ".source, .findings[0].title" <<<"$record" | paste -sd, -) == "model,SECRET note from the instructions" ]]'

setup $'**Approach:** Sound' "$(head -c 59990 /dev/zero | tr '\0' x)"$'\n\n**Ready to merge?** No'
run
expect "records: no room for the marker posts the header only, with a warning" \
	'[[ $rc == 0 && $body == "<!-- gh-pr-review generated -->"$'"'"'\n'"'"'"**Approach:** Sound"* && $body != *"gh-pr-review:round"* ]] &&
		grep -q "no room for its round marker" "$stub/out.log"'
expect "records: round.json keeps the posted record" '[[ $(jq -r ".round, .preview, .decision" <<<"$record" | paste -sd, -) == "1,false,request-changes" ]]'

setup $'**Approach:** Sound' $'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **`b.js:9` — data loss.**\n\n**Ready to merge?** No'
run
expect "records: no block falls back to parsing" '[[ $rc == 0 && $(jq -r ".source, .findings[0].severity, .counts.open_blocking" <<<"$record" | paste -sd, -) == "parsed,critical,1" ]]'

setup $'**Approach:** Sound' $'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **`b.js:9` — data loss.**\n\n**Ready to merge?** Yes with fixes\n\n```json findings\n[{"level":"critical","file":"b.js","line":9,"title":"data loss"}]\n```'
run
expect "records: an unusable block entry falls back to parsing the whole round" \
	'[[ $rc == 0 && $(jq -r ".source, .counts.critical, .findings[0].file" <<<"$record" | paste -sd, -) == "parsed,1,b.js" ]]'

setup $'### Approach\n**Approach:** Rethink' 'never used'
run
expect "records: a Rethink has no code review" '[[ $(jq -r ".code_review, .counts.open_blocking" <<<"$record" | paste -sd, -) == "false,null" ]]'
expect "records: a Rethink posts its marker" '[[ $body == *"gh-pr-review:round"* ]]'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes\n\n```json findings\n[{"severity":"minor","file":"c.js","line":1,"title":"nit"}]\n```'
prev='{"schema":1,"round":2,"head_sha":"old","findings":[{"id":"F1","severity":"minor","status":"new"},{"id":"F3","severity":"important","status":"new"}]}'
jq -n --arg prev "<!-- gh-pr-review:round $prev -->" '[
	{user: {login: "x", type: "User"}, state: "COMMENTED", commit_id: "c1", submitted_at: "2026-01-01T00:00:00Z", body: "<!-- gh-pr-review generated -->\nold round"},
	{user: {login: "y", type: "User"}, state: "COMMENTED", commit_id: "c2", submitted_at: "2026-01-02T00:00:00Z", body: "a human review"},
	{user: {login: "x", type: "User"}, state: "COMMENTED", commit_id: "old", submitted_at: "2026-01-03T00:00:00Z", body: ("<!-- gh-pr-review generated -->\n" + $prev + "\nround two")}]' >"$stub/rest-reviews.json"
run
expect "records: earlier generated reviews count as rounds" '[[ $(jq -r ".round" <<<"$record") == 3 ]]'
expect "records: finding IDs continue from the previous record" '[[ $(jq -r ".findings[0].id, .previous_head_sha" <<<"$record" | paste -sd, -) == "F4,old" ]]'

# F7 two rounds back; the last marker was compacted (no findings) by an older version (no last_ids).
compacted='{"schema":1,"round":2,"head_sha":"old","findings_dropped":true,"counts":{"open_blocking":0}}'
jq -n --arg r1 '<!-- gh-pr-review:round {"schema":1,"round":1,"findings":[{"id":"F7","severity":"minor"}]} -->' \
	--arg r2 "<!-- gh-pr-review:round $compacted -->" '[
	{user: {login: "x"}, commit_id: "c1", submitted_at: "2026-01-01T00:00:00Z", body: ("<!-- gh-pr-review generated -->\n" + $r1)},
	{user: {login: "x"}, commit_id: "old", submitted_at: "2026-01-02T00:00:00Z", body: ("<!-- gh-pr-review generated -->\n" + $r2)}]' \
	>"$stub/rest-reviews.json"
run
expect "records: IDs continue after the highest in the whole history" \
	'[[ $(jq -c "[.round, .findings[0].id, .last_ids.F]" <<<"$record") == "[3,\"F8\",8]" ]]'
expect "records: the marker keeps last_ids" '[[ $body == *"\"last_ids\":{\"F\":8,\"L\":0}"* ]]'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes\n\n```json findings\n[]\n```'
run --no-post
expect "records: --no-post keeps a preview record and posts nothing" '[[ -z $flag && $(jq -r ".preview, .decision" <<<"$record" | paste -sd, -) == "true,null" ]]'

# A jq that breaks the record: it fails, or prints a non-record, when asked to build one. Other calls pass through.
break_record() { # fail | junk
	local real
	real=$(PATH="${PATH#"$stub/bin:"}" command -v jq)
	cat >"$stub/bin/jq" <<S
#!/usr/bin/env bash
for a in "\$@"; do
	if [[ "\$a" == *'build_record(\$meta'* ]]; then [[ $1 == fail ]] && exit 5; echo '{"round":"x"}'; exit 0; fi
done
exec "$real" "\$@"
S
	chmod +x "$stub/bin/jq"
}
for mode in fail junk; do
	setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
	break_record "$mode"
	run
	expect "record $mode: the review is still posted, without a marker" \
		'[[ $rc == 0 && $body == *"Ready to merge?"* && $body != *"gh-pr-review:round"* ]] &&
			grep -q "could not write the round record" "$stub/out.log"'
	expect "record $mode: no record, so a bare yes comments instead of approving" \
		'[[ $flag == --comment && -z $record ]] && grep -q "posting as comment, not approve" "$stub/out.log"'
done

# ── loop check
rounds_with() { # blocking per earlier round... -> REST reviews whose markers carry those counts
	local i=0 b out='[]' rec
	for b in "$@"; do
		i=$((i + 1))
		rec=$(jq -cn --argjson r "$i" --argjson b "$b" '{schema: 1, source: "model", round: $r, head_sha: "h\($r)",
			posted_at: "2026-01-0\($r)T00:00:00Z", approach: "sound", ready: "no", code_review: true, findings: [],
			counts: {open_blocking: $b, critical: 0, important: $b, minor: 0}}')
		out=$(jq -c --arg rec "$rec" --argjson r "$i" '. + [{user: {login: "me", type: "User"}, commit_id: "h\($r)",
			submitted_at: "2026-01-0\($r)T00:00:00Z",
			body: ("<!-- gh-pr-review generated -->\n<!-- gh-pr-review:round " + $rec + " -->\nround")}]' <<<"$out")
	done
	echo "$out"
}
comment_by() { # login type -> one issue comment after the last round
	jq -n --arg login "$1" --arg type "$2" '[{user: {login: $login, type: $type}, created_at: "2026-02-01T00:00:00Z", body: "a reply"}]'
}
no_session() { [[ ! -d "$stub/work/pr-review-sessions" ]]; }

setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
rounds_with 9 12 8 10 >"$stub/rest-reviews.json"
run
expect "loop stop: exit 3 with -y" '[[ $rc == 3 && $calls == 0 && -z $flag ]]'
expect "loop stop: no clone" 'no_session'
expect "loop stop: the diagnosis" 'grep -q "Loop check for round 5: stop" "$stub/out.log"'
run_no_y
expect "loop stop: no terminal, no prompt, exit 3" '[[ $rc == 3 && $calls == 0 ]] && ! grep -q "anyway? \[y/N\]" "$stub/out.log"'
run --force-round
expect "loop stop: --force-round runs the round" '[[ $rc == 0 && $calls == 2 && $(jq -r ".forced, .round, .loop.decision" <<<"$record" | paste -sd, -) == "true,5,stop" ]]'
expect "loop stop: a forced round shows the loop line" '[[ $body == *"**Loop:** Churning"* ]]'
comment_by dave User >"$stub/rest-comments.json"
run
expect "loop stop: a comment by another person lifts it" '[[ $rc == 0 && $calls == 2 && $(jq -r ".loop.decision" <<<"$record") == warn ]]'
echo '[]' >"$stub/rest-comments.json"
rounds_with 9 12 8 10 | jq -c '. + [{user: {login: "dave", type: "User"}, state: "COMMENTED", commit_id: "h4",
	submitted_at: "2026-02-01T00:00:00Z", body: "Why does this post\n<!-- gh-pr-review generated -->\nin the body?"}]' \
	>"$stub/rest-reviews.json"
run
expect "loop stop: a human review quoting the marker is not a round, and lifts it" \
	'[[ $rc == 0 && $calls == 2 && $(jq -r ".round, .loop.decision" <<<"$record" | paste -sd, -) == "5,warn" ]]'
rounds_with 9 12 8 10 >"$stub/rest-reviews.json"
comment_by bob User >"$stub/rest-comments.json"
run
expect "loop stop: the PR author's comment does not lift it" '[[ $rc == 3 && $calls == 0 ]]'
comment_by ci-helper Bot >"$stub/rest-comments.json"
run
expect "loop stop: a bot's comment does not lift it" '[[ $rc == 3 && $calls == 0 ]]'
echo 'not json' >"$stub/rest-comments.json"
run
expect "loop stop: unreadable comments keep the stop, with a warning" '[[ $rc == 3 && $calls == 0 ]] && grep -q "could not read the PR" "$stub/out.log"'
echo '[]' >"$stub/rest-comments.json"
run --check
expect "--check: stop exits 3 without clone or pi" '[[ $rc == 3 && $calls == 0 ]] && no_session && grep -q "Loop check for round 5: stop" "$stub/out.log"'
(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
	bash "$root/gh-pr-review" https://github.com/o/r/pull/1 --check --json >"$stub/check.json" 2>/dev/null) && rc=0 || rc=$?
expect "--check --json: stdout is the decision JSON only" '[[ $rc == 3 && $(jq -r ".decision, .label, .next_round" "$stub/check.json" | paste -sd, -) == "stop,churning,5" ]]'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
rounds_with 9 12 8 >"$stub/rest-reviews.json"
run
expect "loop warn: the round runs" '[[ $rc == 0 && $calls == 2 ]]'
expect "loop warn: the loop line comes right after the markers" '[[ $(sed -n 3p <<<"$body") == "**Loop:** Churning · blocking 9, 12, 8 · "* ]]'
expect "loop warn: the decision still comes from Ready to merge" '[[ $flag == --approve ]]'
run --check
expect "--check: warn exits 0, no model call" '[[ $rc == 0 && $calls == 0 ]]'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
rounds_with 2 >"$stub/rest-reviews.json"
jq '.[0].commit_id = "head1" | .[0].body |= sub("\"head_sha\":\"h1\""; "\"head_sha\":\"head1\"")' "$stub/rest-reviews.json" >"$stub/r.json"
mv "$stub/r.json" "$stub/rest-reviews.json"
run
expect "no new commits: exit 5, no clone" '[[ $rc == 5 && $calls == 0 ]] && no_session'
run --check
expect "--check: no new commits exits 5" '[[ $rc == 5 ]]'
run --force-round
expect "no new commits: --force-round runs" '[[ $rc == 0 && $calls == 2 && $(jq -r ".forced" <<<"$record") == true ]]'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
run
expect "first round: round 1, no loop line" '[[ $rc == 0 && $(jq -r ".round, .loop.decision, .forced" <<<"$record" | paste -sd, -) == "1,run,false" && $body != *"**Loop:**"* ]]'
run --check
expect "--check: no rounds yet exits 0" '[[ $rc == 0 ]]'
run --json
expect "--json without --check: fails" '[[ $rc == 1 && $calls == 0 ]]'
exit "$fail"
