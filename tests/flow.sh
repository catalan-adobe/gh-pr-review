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
	# The PR head the Nth "pr view" returns: line N of heads, or its last line. The clone checks out line 1.
	echo head1 >"$stub/heads"
	cat >"$stub/bin/gh" <<S
#!/usr/bin/env bash
case "\$*" in
*"--method POST"*pulls/1/reviews*)
	[[ -f "$stub/post.fail" ]] && exit 1
	while [[ \$# -gt 0 ]]; do [[ "\$1" == --input ]] && cp "\$2" "$stub/posted.json"; shift; done
	# post.lost: the request fails, and the reviews change as this jq program says (\$p[0]: the request; lost_as).
	if [[ -f "$stub/post.lost" ]]; then
		jq --slurpfile p "$stub/posted.json" -f "$stub/post.lost" "$stub/rest-reviews.json" >"$stub/rest-reviews.tmp"
		mv "$stub/rest-reviews.tmp" "$stub/rest-reviews.json"
		exit 1
	fi ;;
*pulls/1/reviews*)
	# reviews.fail: how many reads of the reviews fail from now on.
	n=\$(cat "$stub/reviews.fail" 2>/dev/null || echo 0)
	[[ "\$n" -gt 0 ]] && { echo "\$((n - 1))" >"$stub/reviews.fail"; exit 1; }
	# Reviews by members unless a fixture says otherwise.
	jq 'map(.author_association //= "MEMBER")' "$stub/rest-reviews.json" ;;
*issues/1/comments*) cat "$stub/rest-comments.json" ;;
*pulls/1/comments*) echo '[]' ;;
*"auth status"*) exit 0 ;;
*"api"*user*)
	# user.fail: how many reads of this account's login fail from now on.
	n=\$(cat "$stub/user.fail" 2>/dev/null || echo 0)
	[[ "\$n" -gt 0 ]] && { echo "\$((n - 1))" >"$stub/user.fail"; exit 1; }
	echo me ;;
*graphql*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
*"--json comments,reviews"*) [[ "${3:-0}" == 0 ]] || exit ${3:-0}; cat "$stub/discussion.json" ;;
*"pr view"*)
	# record.vanish: the preview round.json, once written, is emptied (the head check right before the post).
	if [[ -f "$stub/record.vanish" ]]; then
		for f in "$stub"/work/pr-review-sessions/pr-review-*/round.json; do [[ -f "\$f" ]] && : >"\$f"; done
	fi
	n=\$((\$(cat "$stub/heads.n" 2>/dev/null || echo 0) + 1))
	echo "\$n" >"$stub/heads.n"
	head=\$(sed -n "\${n}p" "$stub/heads")
	[[ -n "\$head" ]] || head=\$(tail -1 "$stub/heads")
	echo '{"title":"T","body":"B","headRefName":"h","baseRefName":"main","author":{"login":"bob"},"additions":1,"deletions":0,"changedFiles":1,"headRefOid":"'"\$head"'"}' ;;
esac
S
	cat >"$stub/bin/git" <<S
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == clone ]] && mkdir -p "\${@: -1}"; done
case "\$*" in *rev-parse*) head -1 "$stub/heads" ;; *merge-base*) echo bbbb ;; esac
S
	cat >"$stub/bin/pi" <<S
#!/usr/bin/env bash
echo call >>"$stub/pi.calls"
if [[ "\${*: -1}" == *"long-time maintainer"* ]]; then [[ "${4:-}" == owner ]] && exit 7
	printf '%s' "\${*: -1}" >"$stub/owner-prompt.txt"; cat "$stub/approach.out"; else
	[[ "${4:-}" == code ]] && exit 7
	# A round someone else posts while this review runs.
	[[ -f "$stub/reviews.after" ]] && cp "$stub/reviews.after" "$stub/rest-reviews.json"
	# GitHub failing the reads of the history from now on.
	[[ -f "$stub/reviews.fail.after" ]] && cp "$stub/reviews.fail.after" "$stub/reviews.fail"
	# The stub jq breaking from now on (bash keeps the path of a command it ran: the stub is there from the start).
	[[ -f "$stub/jq.fail.after" ]] && touch "$stub/jq.fail"
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

# Runs a command on a pseudo-terminal: util-linux or BSD script.
in_tty() { # command...
	local cmd
	printf -v cmd '%q ' "$@"
	if script --version >/dev/null 2>&1; then script -qec "$cmd" /dev/null; else script -q /dev/null "$@"; fi
}

# Types each answer once its prompt shows in the log (10 s at most each), then holds the terminal's input open until
# the run is done, so script never sends an end of file the run could read as an answer.
answer() { # log done-file prompt answer [prompt answer]...
	local log="$1" done="$2" i
	shift 2
	while [[ $# -ge 2 ]]; do
		for ((i = 0; i < 100; i++)); do
			grep -qF -- "$1" "$log" 2>/dev/null && break
			sleep 0.1
		done
		printf '%s\n' "$2"
		shift 2
	done
	for ((i = 0; i < 600; i++)); do
		[[ -f "$done" ]] && return 0
		sleep 0.1
	done
}

run_tty() { # prompt answer [prompt answer]...: the interactive path, on a terminal, without -y
	fresh
	: >"$stub/out.log"
	rm -f "$stub/tty.done"
	answer "$stub/out.log" "$stub/tty.done" "$@" | (
		cd "$stub/work" || exit 1
		code=0
		HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
			in_tty bash "$root/gh-pr-review" https://github.com/o/r/pull/1 >"$stub/out.log" 2>&1 || code=$?
		touch "$stub/tty.done"
		exit "$code"
	) && rc=0 || rc=$?
	collect
}

fresh() { # each run starts with no model calls, nothing posted and no session
	: >"$stub/pi.calls"
	rm -rf "$stub/posted.json" "$stub/heads.n" "$stub/work/pr-review-sessions"
}

collect() {
	calls=$(wc -l <"$stub/pi.calls" | tr -d ' ')
	# What the review API got: the body, the event as the old gh pr review flag, and the commit it is bound to.
	body=$(jq -r '.body' "$stub/posted.json" 2>/dev/null || true)
	flag=$(jq -r '{APPROVE: "--approve", COMMENT: "--comment", REQUEST_CHANGES: "--request-changes"}[.event] // "?"' \
		"$stub/posted.json" 2>/dev/null || true)
	commit=$(jq -r '.commit_id' "$stub/posted.json" 2>/dev/null || true)
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

# The bullet has no location: a located one must match a block entry's location (block_covers_markdown).
block=$'```json findings\n[{"severity":"important","file":"secret/plan.md","line":3,"title":"SECRET note from the instructions"}]\n```'
setup $'**Approach:** Sound' $'### Issues\n#### ⚠️ Important (Should Fix)\n- **Thing breaks.**\n\n**Ready to merge?** No\n\n'"$block"
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

# Room for the minimal marker, not for the counts: the marker says the findings are missing, and the counts come back
# from the Markdown.
setup $'**Approach:** Sound' $'#### 🚨 Critical (Must Fix Before Merge)\n- **`a.js:1` — boom.**\n\n'"$(head -c 59600 /dev/zero | tr '\0' x)"$'\n\n**Ready to merge?** No'
run
expect "records: no room for the counts posts the minimal marker" \
	'[[ $rc == 0 && $(sed -n 2p <<<"$body") == "<!-- gh-pr-review:round {\"schema\":1,\"round\":1,\"findings_dropped\":true,\"last_ids\":{\"F\":1,\"L\":0}} -->" ]] &&
		! grep -q "no room for its round marker" "$stub/out.log"'
jq -n --arg body "$body" '[{id: 1, user: {login: "me", type: "User"}, state: "CHANGES_REQUESTED", commit_id: "head1",
	submitted_at: "2026-05-01T10:00:00Z", body: $body}]' >"$stub/rest-reviews.json"
(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
	bash "$root/gh-pr-review" rounds https://github.com/o/r/pull/1 --json >"$stub/rounds.json" 2>"$stub/out.log") && rc=0 || rc=$?
expect "records: a minimal marker reads back with the Markdown's counts and findings_dropped" \
	'[[ $rc == 0 && $(jq -c ".records[0] | [.round, .findings_dropped, .counts.critical, .counts.open_blocking, .last_ids.F, has(\"findings\")]" "$stub/rounds.json") == "[1,true,1,1,1,false]" ]]'

setup $'**Approach:** Sound' $'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **`b.js:9` — data loss.**\n\n**Ready to merge?** No'
run
expect "records: no block falls back to parsing" '[[ $rc == 0 && $(jq -r ".source, .findings[0].severity, .counts.open_blocking" <<<"$record" | paste -sd, -) == "parsed,critical,1" ]]'

setup $'**Approach:** Sound' $'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **`b.js:9` — data loss.**\n\n**Ready to merge?** Yes with fixes\n\n```json findings\n[{"level":"critical","file":"b.js","line":9,"title":"data loss"}]\n```'
run
expect "records: an unusable block entry falls back to parsing the whole round" \
	'[[ $rc == 0 && $(jq -r ".source, .counts.critical, .findings[0].file" <<<"$record" | paste -sd, -) == "parsed,1,b.js" ]]'

setup $'**Approach:** Sound' $'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **`b.js:9` — data loss.**\n\n**Ready to merge?** Yes with fixes\n\n```json findings\n[]\n```'
run
expect "records: an empty block next to a Critical bullet falls back to the Markdown" \
	'[[ $rc == 0 && $(jq -r ".source, .counts.critical, .counts.open_blocking, .findings[0].file" <<<"$record" | paste -sd, -) == "parsed,1,1,b.js" ]] &&
		grep -q "does not match the review" "$stub/out.log"'

# Two JSON values in one fence: not one array, so the Markdown is the record, and the marker is posted.
block=$'```json findings\n[]\n[{"severity":"critical","file":"b.js","line":9,"title":"data loss"}]\n```'
setup $'**Approach:** Sound' $'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **`b.js:9` — data loss.**\n\n**Ready to merge?** No\n\n'"$block"
run
expect "records: two JSON values in the findings block fall back to the Markdown, with a record and a marker" \
	'[[ $rc == 0 && $(jq -r ".source, .counts.critical, .preview" <<<"$record" | paste -sd, -) == "parsed,1,false" &&
		$body == *"gh-pr-review:round"* ]] && grep -q "does not match the review" "$stub/out.log"'

block=$'```json findings\n[{"severity":"critical","file":"a.go","line":10,"title":"one"},{"severity":"critical","file":"a.go","line":10,"title":"two"}]\n```'
setup $'**Approach:** Sound' $'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **`a.go:10` — one.**\n- **`b.go:11` — two.**\n\n**Ready to merge?** No\n\n'"$block"
run
expect "records: a block repeating one blocker's location falls back to the Markdown" \
	'[[ $rc == 0 && $(jq -c "[.source, [.findings[] | .file]]" <<<"$record") == "[\"parsed\",[\"a.go\",\"b.go\"]]" ]]'

# A real reply (PR #8, round 4): the Markdown gives ranges (gh-pr-review:974–977), the block a line inside each.
setup $'### Approach\n**Approach:** Questionable' "$(cat "$root/tests/fixtures/reviews/pr8-round4-model.md")"
run
expect "records: Markdown ranges match the block's lines inside them, so the block is the record" \
	'[[ $rc == 0 && $(jq -c "[.source, (.findings | length), [.findings[].line], .counts.open_blocking]" <<<"$record") == \
		"[\"model\",7,[976,1031,260,88,885,173,129],4]" ]] && ! grep -q "does not match the review" "$stub/out.log"'

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

# A jq that breaks the record: it fails, or prints a non-record, when asked to build one; or (posted) it fails the
# final build of the posted record. Other calls pass through.
break_record() { # fail | junk | posted
	local real
	real=$(PATH="${PATH#"$stub/bin:"}" command -v jq)
	cat >"$stub/bin/jq" <<S
#!/usr/bin/env bash
for a in "\$@"; do
	if [[ $1 != posted && "\$a" == *'build_record(\$meta'* ]]; then [[ $1 == fail ]] && exit 5; echo '{"round":"x"}'; exit 0; fi
	if [[ $1 == posted && "\$a" == *'.preview = false'* ]]; then exit 5; fi
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

setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
break_record posted
run_tty "Post as review" ""
expect "posted record fails, default approve taken at the prompt: posts as comment, without a marker" \
	'[[ $rc == 0 && $flag == --comment && $body != *"gh-pr-review:round"* ]] &&
		grep -q "posting as comment, not approve" "$stub/out.log" && grep -q "Enter = approve" "$stub/out.log"'
run_tty "Post as review" a
expect "posted record fails, approve typed at the prompt: stays an approval" '[[ $rc == 0 && $flag == --approve ]]'

# A valid preview that is gone by the time the review is posted: no posted record, so no marker and no automatic
# approval; an approval chosen at the prompt stays.
setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
touch "$stub/record.vanish"
run
expect "preview emptied before posting: a bare yes posts as comment, without a marker" \
	'[[ $rc == 0 && $flag == --comment && $body == *"Ready to merge?"* && $body != *"gh-pr-review:round"* ]] &&
		grep -q "could not write the posted round record" "$stub/out.log" && grep -q "posting as comment, not approve" "$stub/out.log"'
run_tty "Post as review" a
expect "preview emptied before posting, approve typed at the prompt: stays an approval" '[[ $rc == 0 && $flag == --approve ]]'

# ── loop check
rounds_with() { # blocking per earlier round... -> REST reviews whose markers carry those counts
	local i=0 b out='[]' rec
	for b in "$@"; do
		i=$((i + 1))
		rec=$(jq -cn --argjson r "$i" --argjson b "$b" '{schema: 1, source: "model", round: $r, head_sha: "h\($r)",
			posted_at: "2026-01-0\($r)T00:00:00Z", approach: "sound", ready: "no", code_review: true, findings: [],
			counts: {open_blocking: $b, critical: 0, important: $b, minor: 0}}')
		out=$(jq -c --arg rec "$rec" --argjson r "$i" '. + [{id: $r, user: {login: "me", type: "User"}, commit_id: "h\($r)",
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
run_tty "anyway?" n
expect "no new commits, in a terminal: asks, and no exits 5" \
	'[[ $rc == 5 && $calls == 0 ]] && grep -q "Run round 2 anyway? \[y/N\]" "$stub/out.log" && no_session'
run_tty "anyway?" y "Post as review" ""
expect "no new commits, in a terminal: yes runs the round, marked forced" \
	'[[ $rc == 0 && $calls == 2 && $(jq -r ".round, .forced" <<<"$record" | paste -sd, -) == "2,true" ]]'
run --force-round
expect "no new commits: --force-round runs" '[[ $rc == 0 && $calls == 2 && $(jq -r ".forced" <<<"$record") == true ]]'

# The last round on this head was a Rethink: the code was never reviewed.
setup 'unused' $'**Ready to merge?** Yes'
jq -n '[{schema: 1, round: 1, head_sha: "head1", approach: "rethink", code_review: false,
	counts: {open_blocking: null}}] | map({user: {login: "ann", type: "User"}, commit_id: "head1",
	submitted_at: "2026-01-01T00:00:00Z", body: ("<!-- gh-pr-review generated -->\n<!-- gh-pr-review:round " + tojson + " -->\nx")})' \
	>"$stub/rest-reviews.json"
run --skip-approach
expect "after a Rethink on this head: --skip-approach runs the code review" \
	'[[ $rc == 0 && $calls == 1 && $(jq -r ".round, .forced" <<<"$record" | paste -sd, -) == "2,false" ]]'
run --skip-approach --check
expect "after a Rethink on this head: --skip-approach --check exits 0" '[[ $rc == 0 && $calls == 0 ]]'
run
expect "after a Rethink on this head: a full run has nothing new" '[[ $rc == 5 && $calls == 0 ]]'

# Overlapping runs: round 2, by ann, lands while this review runs. This one never posts on top of it.
overlap() {
	setup $'**Approach:** Sound' $'**Ready to merge?** Yes\n\n```json findings\n[{"severity":"minor","title":"nit"}]\n```'
	rounds_with 2 >"$stub/rest-reviews.json"
	rounds_with 2 3 | jq -c '.[1].user.login = "ann" | .[1].body |= sub("\"findings\":\\[\\]"; "\"findings\":[{\"id\":\"F5\"}]")' \
		>"$stub/reviews.after"
}
overlap
run
expect "overlap, -y: nothing posted, exit 6, session kept" \
	'[[ $rc == 6 && -z $flag && $(jq -r .preview <<<"$record") == true ]] && grep -q "round 2 by ann" "$stub/out.log"'
overlap
run_tty "Post as review" ""
expect "overlap, in a terminal: no prompt, nothing posted, exit 6" \
	'[[ $rc == 6 && -z $flag ]] && grep -q "round 2 by ann" "$stub/out.log" && ! grep -q "Post anyway" "$stub/out.log"'

# Same count, other rounds: review 10 was the history; at the recheck its generated header is edited out and review 11,
# a new round by ann, is there. One round then, one round now, but not the same one.
setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
rounds_with 2 | jq -c '.[0].id = 10' >"$stub/rest-reviews.json"
jq -c '.[0].body |= sub("^<!-- gh-pr-review generated -->\n"; "") | . + [{id: 11, user: {login: "ann", type: "User"},
	state: "COMMENTED", commit_id: "h1", submitted_at: "2026-01-05T00:00:00Z",
	body: "<!-- gh-pr-review generated -->\n**Ready to merge?** No"}]' "$stub/rest-reviews.json" >"$stub/reviews.after"
run
expect "overlap, same count but another round: nothing posted, exit 6, the new round named" \
	'[[ $rc == 6 && -z $flag && $(jq -r .preview <<<"$record") == true ]] && grep -q "round 1 by ann" "$stub/out.log"'
rounds_with 2 | jq -c '.[0].id = 10' >"$stub/rest-reviews.json"
jq -c '.[0].body |= sub("^<!-- gh-pr-review generated -->\n"; "")' "$stub/rest-reviews.json" >"$stub/reviews.after"
run
expect "overlap, a round that is no longer one: nothing posted, exit 6" \
	'[[ $rc == 6 && -z $flag ]] && grep -q "rounds changed while this review ran" "$stub/out.log"'

# Only trusted reviews are rounds: an owner's, member's or collaborator's, or this account's.
untrusted() { # login association commit -> one generated review
	jq -n --arg login "$1" --arg assoc "$2" --arg commit "$3" '[{id: 7, user: {login: $login, type: "User"},
		author_association: $assoc, state: "COMMENTED", commit_id: $commit, submitted_at: "2026-01-05T00:00:00Z",
		body: "<!-- gh-pr-review generated -->\n**Ready to merge?** No"}]'
}
setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
untrusted eve CONTRIBUTOR head1 >"$stub/rest-reviews.json"
run --check
expect "trust: an outsider's generated review on this head is not a round: --check runs, and names it" \
	'[[ $rc == 0 ]] && grep -q "Loop check for round 1: run" "$stub/out.log" &&
		[[ $(grep -c "ignored: 1 generated review by @eve (not a member or collaborator of the repo)" "$stub/out.log") == 1 ]]'
run
expect "trust: an outsider's generated review on this head: the review runs as round 1 and is posted" \
	'[[ $rc == 0 && $calls == 2 && $flag == --approve && $(jq -r .round <<<"$record") == 1 ]] &&
		[[ $(grep -c "ignored: 1 generated review by @eve" "$stub/out.log") == 1 ]]'
untrusted me CONTRIBUTOR head1 >"$stub/rest-reviews.json"
run
expect "trust: this account's review counts where it is only a contributor: nothing new" '[[ $rc == 5 && $calls == 0 ]]'
# This account's login can't be read: its own rounds would be missed, so nothing runs (one retry first).
echo 1 >"$stub/user.fail"
run
expect "trust: the login read fails once: the retry reads it, and its own review still means nothing new" \
	'[[ $rc == 5 && $calls == 0 ]]'
login_error="could not read the account running the tool, so the round history can't be checked; check gh auth and network"
echo 2 >"$stub/user.fail"
run --check
expect "trust: the login read fails twice: --check exits 1 and says why" \
	'[[ $rc == 1 && $calls == 0 ]] && no_session && grep -qF "$login_error" "$stub/out.log" && ! grep -q "Loop check" "$stub/out.log"'
echo 2 >"$stub/user.fail"
run
expect "trust: the login read fails twice: the review exits 1, with no clone and no model call" \
	'[[ $rc == 1 && $calls == 0 && -z $flag ]] && no_session && grep -qF "$login_error" "$stub/out.log"'
echo 2 >"$stub/user.fail"
(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
	bash "$root/gh-pr-review" rounds https://github.com/o/r/pull/1 >"$stub/out.log" 2>&1) && rc=0 || rc=$?
expect "trust: the login read fails twice: rounds exits 1 and says why" \
	'[[ $rc == 1 ]] && grep -qF "$login_error" "$stub/out.log" && ! grep -q "^next round" "$stub/out.log"'
rm -f "$stub/user.fail"
untrusted eve NONE head1 | jq '.[0].user.login = "eve2"' >"$stub/reviews.after"
echo '[]' >"$stub/rest-reviews.json"
run
expect "trust: an outsider's generated review during the review is no overlap: posted" '[[ $rc == 0 && $flag == --approve ]]'

# The history can't be read again before posting: one retry, then nothing is posted.
setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
echo 1 >"$stub/reviews.fail.after"
run
expect "final history read fails once: the retry reads it, and the review is posted" '[[ $rc == 0 && $flag == --approve ]]'
echo 2 >"$stub/reviews.fail.after"
run
expect "final history read fails twice: exit 1, nothing posted, the session kept" \
	'[[ $rc == 1 && -z $flag && $(jq -r .preview <<<"$record") == true ]] &&
		grep -q "history could not be verified; nothing was posted" "$stub/out.log" && ! grep -q "exit 6" "$stub/out.log"'
echo 2 >"$stub/reviews.fail.after"
run_tty "Post as review" ""
expect "final history read fails twice, in a terminal: exit 1, nothing posted" '[[ $rc == 1 && -z $flag ]]'

# The history is read again, but rebuilding a round from it fails (the reconciling jq): that is a failed read too.
setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
rounds_with 2 >"$stub/rest-reviews.json"
cat >"$stub/bin/jq" <<S
#!/usr/bin/env bash
if [[ -f "$stub/jq.fail" ]]; then for a in "\$@"; do [[ "\$a" == *'reconcile_record('* ]] && exit 5; done; fi
exec "$(command -v jq)" "\$@"
S
chmod +x "$stub/bin/jq"
touch "$stub/jq.fail.after"
run
expect "final history read cannot rebuild a round: exit 1, nothing posted" \
	'[[ $rc == 1 && -z $flag && $(jq -r .preview <<<"$record") == true ]] &&
		grep -q "history could not be verified; nothing was posted" "$stub/out.log"'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
run
expect "first round: round 1, no loop line" '[[ $rc == 0 && $(jq -r ".round, .loop.decision, .forced" <<<"$record" | paste -sd, -) == "1,run,false" && $body != *"**Loop:**"* ]]'
run --check
expect "--check: no rounds yet exits 0" '[[ $rc == 0 ]]'
run --json
expect "--json without --check: fails" '[[ $rc == 1 && $calls == 0 ]]'
# ── producer to consumer: a posted round, returned as GitHub returns it, read back by rounds --json and --check
block=$'```json findings\n[{"severity":"important","file":"a.js","line":3,"title":"thing breaks"}]\n```'
setup $'**Approach:** Sound' $'### Issues\n#### ⚠️ Important (Should Fix)\n- **`a.js:3` — thing breaks.**\n\n**Ready to merge?** Yes with fixes\n\n'"$block"
run
expect "round trip: round 1 posted, on the reviewed commit" '[[ $rc == 0 && $flag == --comment && $commit == head1 ]]'
# GitHub's copy of what was posted: the body and the commit the review API got.
landed() { # id state time -> appends the last posted review to the stub's history
	jq --arg body "$body" --arg commit "$commit" --argjson id "$1" --arg state "$2" --arg at "$3" '. + [{id: $id,
		user: {login: "me", type: "User"}, state: $state, commit_id: $commit, submitted_at: $at, body: $body}]' \
		"$stub/rest-reviews.json" >"$stub/r.json"
	mv "$stub/r.json" "$stub/rest-reviews.json"
}
landed 11 COMMENTED 2026-05-01T10:00:00Z
(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
	bash "$root/gh-pr-review" rounds https://github.com/o/r/pull/1 --json >"$stub/rounds.json" 2>"$stub/out.log") && rc=0 || rc=$?
expect "round trip: rounds --json reads the posted record back" \
	'[[ $rc == 0 && $(jq -c ".records | length" "$stub/rounds.json") == 1 && $(jq -r ".records[0] | .round, .source,
		.counts.open_blocking, .counts.important, .findings[0].id, .head_sha, .posted_at, .decision, .ready" "$stub/rounds.json" |
		paste -sd, -) == "1,model,1,1,F1,head1,2026-05-01T10:00:00Z,comment,yes-with-fixes" ]]'
expect "round trip: the decision sees round 1 on this head" \
	'[[ $(jq -r ".decision | .decision, .next_round" "$stub/rounds.json" | paste -sd, -) == "nothing-new,2" ]]'
(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
	bash "$root/gh-pr-review" https://github.com/o/r/pull/1 --check --json >"$stub/check.json" 2>"$stub/out.log") && rc=0 || rc=$?
expect "round trip: --check exits 5 on the same head" \
	'[[ $rc == 5 && $(jq -r ".decision, .next_round, .series[0]" "$stub/check.json" | paste -sd, -) == "nothing-new,2,1" ]]'

# The head and the history change on their own between and during the rounds.
check_json() {
	fresh
	(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
		bash "$root/gh-pr-review" https://github.com/o/r/pull/1 --check --json >"$stub/check.json" 2>"$stub/out.log") && rc=0 || rc=$?
	check=$(jq -r '.decision + "," + (.next_round | tostring)' "$stub/check.json" 2>/dev/null || true)
}
echo head2 >"$stub/heads"
check_json
expect "round trip: a push makes head2 eligible" '[[ $rc == 0 && $check == run,2 ]]'
printf '%s' $'**Ready to merge?** Yes' >"$stub/review.out"
printf 'head2\nhead3\n' >"$stub/heads"
run
expect "round trip: round 2 reads head2 while head3 lands: posted on head2, not approved" \
	'[[ $rc == 0 && $commit == head2 && $flag == --comment &&
		$(jq -r ".round, .head_sha, .previous_head_sha" <<<"$record" | paste -sd, -) == "2,head2,head1" ]]'
landed 12 COMMENTED 2026-05-02T10:00:00Z
echo head3 >"$stub/heads"
check_json
expect "round trip: head3 stays eligible after round 2" '[[ $rc == 0 && $check == run,3 ]]'
echo 2 >"$stub/reviews.fail.after"
run
expect "round trip: the final history read fails: nothing posted, exit 1" '[[ $rc == 1 && -z $flag && -z $commit ]]'
rm -f "$stub/reviews.fail.after" "$stub/reviews.fail"
check_json
expect "round trip: head3 is still eligible after the failed run" '[[ $rc == 0 && $check == run,3 ]]'
jq '. + [{id: 13, user: {login: "ann", type: "User"}, state: "APPROVED", commit_id: "head3",
	submitted_at: "2026-05-03T10:00:00Z", body: "<!-- gh-pr-review generated -->\n**Ready to merge?** Yes"}]' \
	"$stub/rest-reviews.json" >"$stub/reviews.after"
run
expect "round trip: ann's round on head3 lands during round 3: nothing posted, exit 6" \
	'[[ $rc == 6 && -z $flag ]] && grep -q "round 3 by ann" "$stub/out.log"'
rm -f "$stub/reviews.after"
check_json
expect "round trip: ann's round covers head3: nothing new" '[[ $rc == 5 && $check == nothing-new,4 ]]'
(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
	bash "$root/gh-pr-review" rounds https://github.com/o/r/pull/1 --json >"$stub/rounds.json" 2>"$stub/out.log") && rc=0 || rc=$?
expect "round trip: the history has each round on the commit it read" \
	'[[ $(jq -c "[.records[] | [.round, .head_sha, .reviewer]]" "$stub/rounds.json") == \
		"[[1,\"head1\",\"me\"],[2,\"head2\",\"me\"],[3,\"head3\",\"ann\"]]" ]]'

# Two runs post round 1 at once, and the second one's marker was compacted (findings dropped, counts kept): read
# back, its 40 new IDs come after the first run's F1, so round 3 numbers from F42.
block=$'```json findings\n[{"severity":"important","file":"a.js","line":3,"title":"thing breaks"}]\n```'
setup $'**Approach:** Sound' $'### Issues\n#### ⚠️ Important (Should Fix)\n- **`a.js:3` — thing breaks.**\n\n**Ready to merge?** No\n\n'"$block"
run
expect "at once: the first run posts round 1 with F1" '[[ $rc == 0 && $(jq -c "[.round, .last_ids.F]" <<<"$record") == "[1,1]" ]]'
first_body="$body" first_commit="$commit"
many=$(jq -nc '[range(40) | {severity: "minor", file: null, line: null, title: "nit \(.)"}]')
printf '%s' "$(head -c 58000 /dev/zero | tr '\0' x)"$'\n\n**Ready to merge?** Yes with fixes\n\n```json findings\n'"$many"$'\n```' \
	>"$stub/review.out"
run
expect "at once: the second run also claims round 1, and its marker drops the findings but keeps the counts" \
	'[[ $rc == 0 && $(sed -n 2p <<<"$body" | sed "s/^<!-- gh-pr-review:round //; s/ -->$//" |
		jq -c "[.round, .findings_dropped, has(\"findings\"), .counts.new, .last_ids.F]") == "[1,true,false,40,40]" ]]'
second_body="$body"
body="$first_body" commit="$first_commit"
landed 21 CHANGES_REQUESTED 2026-06-01T10:00:00Z
body="$second_body"
landed 22 COMMENTED 2026-06-01T10:00:00Z
echo head2 >"$stub/heads"
printf '%s' $'**Ready to merge?** No\n\n```json findings\n[{"severity":"minor","title":"one more"}]\n```' >"$stub/review.out"
run
expect "at once: round 3 numbers its new finding after both runs' IDs" \
	'[[ $rc == 0 && $(jq -c "[.round, .findings[0].id, .last_ids.F]" <<<"$record") == "[3,\"F42\",42]" ]]'

# The Markdown says there is nothing to fix; the block claims four Criticals. The reader's version wins: the record
# is parsed, with no blockers, the bare yes approves, and the round reads back as ready.
none=$'*(none found)*\n\n'
block=$'```json findings\n'"$(jq -nc '[range(4) | {severity: "critical", file: "a.js", line: (. + 1), title: "c\(.)"}]')"$'\n```'
setup $'**Approach:** Sound' $'### Issues\n\n#### 🚨 Critical (Must Fix Before Merge)\n\n'"$none"$'#### ⚠️ Important (Should Fix)\n\n'"$none"$'#### 💡 Minor (Nice to Have)\n\n'"$none"$'### Assessment\n\n**Ready to merge?** Yes\n\n'"$block"
run
expect "records: blockers in the block under empty Markdown sections: parsed, none blocking, approved" \
	'[[ $rc == 0 && $flag == --approve && $(jq -c "[.source, .counts.open_blocking, .counts.critical, (.findings | length)]" <<<"$record") == "[\"parsed\",0,0,0]" ]] &&
		grep -q "does not match the review" "$stub/out.log"'
landed 31 APPROVED 2026-07-01T10:00:00Z
echo head2 >"$stub/heads"
check_json
expect "records: that round reads back with no blockers, as ready" \
	'[[ $rc == 0 && $(jq -c "[.decision, .label, .series]" "$stub/check.json") == "[\"run\",\"ready\",[0]]" ]]'

# The same, with the four Criticals marked fixed in the block. This version stores every entry as new, so the checks
# judge them open too: the record is parsed, not the block's four open blockers, and the approval is not theirs. Read
# back, the excluded entries do not come back as blockers.
block=$'```json findings\n'"$(jq -nc '[range(4) | {severity: "critical", status: "fixed", file: "a.js", line: (. + 1), title: "c\(.)"}]')"$'\n```'
setup $'**Approach:** Sound' $'### Issues\n\n#### 🚨 Critical (Must Fix Before Merge)\n\n'"$none"$'#### ⚠️ Important (Should Fix)\n\n'"$none"$'#### 💡 Minor (Nice to Have)\n\n'"$none"$'### Assessment\n\n**Ready to merge?** Yes\n\n'"$block"
run
expect "records: fixed blockers in the block under empty Markdown sections: parsed, none blocking, approved" \
	'[[ $rc == 0 && $flag == --approve && $(jq -c "[.source, .counts.open_blocking, (.findings | length)]" <<<"$record") == "[\"parsed\",0,0]" ]] &&
		grep -q "does not match the review" "$stub/out.log"'
landed 32 APPROVED 2026-07-01T10:00:00Z
echo head2 >"$stub/heads"
check_json
expect "round trip: the excluded entries do not come back as blockers" \
	'[[ $rc == 0 && $(jq -c "[.decision, .label, .series]" "$stub/check.json") == "[\"run\",\"ready\",[0]]" ]]'
(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
	bash "$root/gh-pr-review" rounds https://github.com/o/r/pull/1 --json >"$stub/rounds.json" 2>"$stub/out.log") && rc=0 || rc=$?
expect "round trip: the round read back keeps no findings and no blockers" \
	'[[ $rc == 0 && $(jq -c ".records[0] | [.source, .findings, .counts.open_blocking, .counts.critical]" "$stub/rounds.json") == "[\"parsed\",[],0,0]" ]]'

# ── the review is bound to the commit it read
setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
run
expect "commit: the review is posted on the reviewed commit, through the review API" '[[ $rc == 0 && $commit == head1 && $flag == --approve ]]'
printf 'head1\nhead2\n' >"$stub/heads"
run
expect "head moved during the review: posted on the reviewed commit, as a comment, not an approval" \
	'[[ $rc == 0 && $commit == head1 && $flag == --comment && $(jq -r .head_sha <<<"$record") == head1 ]]'
expect "head moved during the review: the run and the review say so" \
	'grep -q "The PR moved to head2 during the review; this review covers head1." "$stub/out.log" &&
		[[ $body == *"**Note:** The PR moved to head2 during the review; this review covers head1."* ]]'
run --decision approve
expect "head moved during the review: an explicit approve is a comment too" '[[ $rc == 0 && $commit == head1 && $flag == --comment ]]'
printf 'head1\nhead2\n' >"$stub/heads"
run
jq -n --arg body "$body" --arg commit "$commit" '[{id: 1, user: {login: "me", type: "User"}, state: "COMMENTED",
	commit_id: $commit, submitted_at: "2026-05-01T10:00:00Z", body: $body}]' >"$stub/rest-reviews.json"
echo head2 >"$stub/heads"
run --check
expect "head moved during the review: --check on the new head runs" '[[ $rc == 0 ]] && grep -q "Loop check for round 2: run" "$stub/out.log"'

# A loop warning and a head that moved: the loop line stays the review's first line, the note comes right after it.
setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
rounds_with 9 12 8 >"$stub/rest-reviews.json"
printf 'head1\nhead2\n' >"$stub/heads"
run
expect "loop line and moved head: the loop line first, then the note" \
	'[[ $rc == 0 && $flag == --comment && $(sed -n 3p <<<"$body") == "**Loop:** Churning"* && -z $(sed -n 4p <<<"$body") &&
		$(sed -n 5p <<<"$body") == "**Note:** The PR moved to head2 during the review; this review covers head1." &&
		-z $(sed -n 6p <<<"$body") && $(sed -n 7p <<<"$body") == "**Approach:** Sound" ]]'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
touch "$stub/post.fail"
run
expect "the review API fails and no review landed: exit 1, unconfirmed, the record still a preview" \
	'[[ $rc == 1 && $(jq -r .preview <<<"$record") == true ]] &&
		grep -q "could not confirm whether the review was posted; run .gh pr-review rounds https://github.com/o/r/pull/1. before retrying" "$stub/out.log" &&
		! grep -q "nothing was posted" "$stub/out.log"'
# The post request fails; then the reviews change as <program> says, with $p[0] the request and $state its review state.
lost_as() { # jq-program (the history starts empty again)
	echo '[]' >"$stub/rest-reviews.json"
	printf '({APPROVE: "APPROVED", REQUEST_CHANGES: "CHANGES_REQUESTED", COMMENT: "COMMENTED"}[$p[0].event]) as $state\n| %s' \
		"$1" >"$stub/post.lost"
}
# Submitted now: inside the time window the old check trusted, so only the ID, state and body tell them apart.
review_by_me='{id: 99, user: {login: "me", type: "User"}, state: $state, commit_id: $p[0].commit_id,
	submitted_at: (now | todate), body: $p[0].body}'
unconfirmed() { # rc, output and record of a failed post that could not be confirmed
	[[ $rc == 1 && $(jq -r .preview <<<"$record") == true ]] && grep -q "could not confirm whether the review was posted" "$stub/out.log" &&
		! grep -q "Posted →" "$stub/out.log"
}
setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
lost_as ". + [$review_by_me]"
run
expect "the review API fails but the review landed: posted, the record finished as posted" \
	'[[ $rc == 0 && $flag == --approve && $(jq -r ".preview, .decision" <<<"$record" | paste -sd, -) == "false,approve" ]] &&
		grep -q "the review is on the PR: it was posted" "$stub/out.log" && grep -q "Posted →" "$stub/out.log"'
lost_as ". + [$review_by_me | .body |= (gsub(\"\\n\"; \"  \\r\\n\") + \"\\n\")]"
run
expect "the review landed, read back with CRLF and trailing spaces: posted" '[[ $rc == 0 ]] && grep -q "it was posted" "$stub/out.log"'
lost_as ". + [$review_by_me | .body = \"<!-- gh-pr-review generated -->\\nanother run's review\"]"
run
expect "another review by this account on this commit, another body: unconfirmed, exit 1, still a preview" 'unconfirmed'
lost_as ". + [$review_by_me | .state = \"COMMENTED\"]"
run
expect "the posted body in another state than the event's: unconfirmed" 'unconfirmed'
lost_as ". + [$review_by_me, ($review_by_me | .id = 100)]"
run
expect "two reviews match: unconfirmed" 'unconfirmed'
lost_as "map(if .id == 1 then . + {state: \$state, commit_id: \$p[0].commit_id, body: \$p[0].body,
	submitted_at: (now | todate)} else . end)"
rounds_with 2 >"$stub/rest-reviews.json"
run
expect "the matching review was already a round before the post: unconfirmed" 'unconfirmed'
exit "$fail"
