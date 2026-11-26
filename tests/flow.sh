#!/usr/bin/env bash
# Runs the whole gh-pr-review script with stub git, gh and pi, and checks the orchestration:
# how many model calls run, what the code review gets, and what is posted.
# Conditions are single-quoted on purpose: expect() evals them after each run sets rc, calls, body and flag.
# shellcheck disable=SC2016,SC2034,SC2329 # SC2329: helpers such as no_session run inside expect's eval
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# The script must reach its end: Bash 3.2 can stop on an error inside an EXIT trap with status 0.
finished=false
trap '[[ $finished == true ]] || { echo "FAIL stopped before the end"; exit 1; }' EXIT
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
	rm -f "$stub/git.missing" "$stub/git.rebased" "$stub/git.diff-fails" "$stub/git.far-base" "$stub/git.deepened"
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
	# git: HEAD is aaaa and the merge-base bbbb. Any other SHA resolves to itself, unless listed in git.missing. The
	# previous head is an ancestor of the head unless git.rebased exists. git.diff-fails makes `git diff` fail.
	# git.far-base: no merge-base until a `fetch --deepen` (logged in git.deepened); "never": not even then.
	cat >"$stub/bin/git" <<'S'
#!/usr/bin/env bash
s=$(cd "$(dirname "$0")/.." && pwd)
for a in "$@"; do [[ "$a" == clone ]] && mkdir -p "${@: -1}"; done
case "$*" in
*"rev-parse --is-shallow-repository"*) echo false ;;
*"rev-parse --verify"*)
	sha=${*: -1}
	sha=${sha%^\{commit\}}
	if grep -qx -- "$sha" "$s/git.missing" 2>/dev/null; then exit 1; fi
	[[ $sha == HEAD ]] && sha=aaaa
	echo "$sha"
	;;
*rev-parse*) echo aaaa ;;
*"fetch "*--deepen*) printf '%s\n' "$*" >>"$s/git.deepened" ;;
*"merge-base --is-ancestor"*) [[ ! -f "$s/git.rebased" ]] ;;
*merge-base*)
	if [[ -f "$s/git.far-base" ]] && { [[ ! -f "$s/git.deepened" ]] || grep -qx never "$s/git.far-base"; }; then exit 1; fi
	echo bbbb
	;;
*"diff --name-only"*)
	[[ ! -f "$s/git.diff-fails" ]] || exit 1
	printf 'd.js\0'
	;;
esac
S
	cat >"$stub/bin/pi" <<S
#!/usr/bin/env bash
echo call >>"$stub/pi.calls"
if [[ "\${*: -1}" == *"long-time maintainer"* ]]; then [[ "${4:-}" == owner ]] && exit 7
	printf '%s' "\${*: -1}" >"$stub/owner-prompt.txt"; cat "$stub/approach.out"; else
	[[ "${4:-}" == code ]] && exit 7
	# A round someone else posts while this review runs.
	[[ -f "$stub/reviews.after" ]] && cp "$stub/reviews.after" "$stub/rest-reviews.json"
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

setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
touch "$stub/git.far-base"
run
expect "merge-base past the depth: deepens the PR and the base once, then reviews" '[[ $rc == 0 && $calls == 2 && $(grep -c -- "--deepen 200" "$stub/git.deepened") == 2 ]] && grep -q "pull/1/head" "$stub/git.deepened" && grep -q "main:refs/remotes/origin/main" "$stub/git.deepened"'
expect "merge-base past the depth: the deepen uses the credential helper" '[[ $(grep -c "credential.helper=!gh auth git-credential" "$stub/git.deepened") == 2 ]]'
setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
echo never >"$stub/git.far-base"
run
expect "merge-base still missing after the deepen: refuses, no review" '[[ $rc == 1 && $calls == 0 && -z $flag ]] && grep -q "Refusing to review a partial diff" "$stub/out.log"'

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

setup $'**Approach:** Sound' $'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **`n.go:4` — Nil dereference.**\n\n**Ready to merge?** No\n\n```json findings\n[{"id":"F999","status":"open","title":"Nil dereference"}]\n```'
run
expect "records: an invented ID without a severity falls back to the Markdown" \
	'[[ $rc == 0 && $(jq -r ".source, .counts.critical, .findings[0].id, .findings[0].file" <<<"$record" | paste -sd, -) == "parsed,1,F1,n.go" ]]'

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
expect "loop stop: a forced round shows the progress line, not the loop line" '[[ $body == *"### Round 5 · since round 4"*"loop: ready"* && $body != *"**Loop:**"* && $body != *"**Next:**"* ]]'
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
expect "loop warn: the progress line comes right after the markers" '[[ $(sed -n 3p <<<"$body") == "### Round 4 · since round 3" && $body != *"**Loop:**"* ]]'
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

# Overlapping runs: round 2, by ann, lands while this review runs.
overlap() {
	setup $'**Approach:** Sound' $'**Ready to merge?** Yes\n\n```json findings\n[{"severity":"minor","title":"nit"}]\n```'
	rounds_with 2 >"$stub/rest-reviews.json"
	rounds_with 2 3 | jq -c '.[1].user.login = "ann" | .[1].body |= sub("\"findings\":\\[\\]"; "\"findings\":[{\"id\":\"F5\"}]")' \
		>"$stub/reviews.after"
}
overlap
run
expect "overlap, -y: nothing posted, exit 6, session kept" \
	'[[ $rc == 6 && -z $flag && -n $record ]] && grep -q "round 2 by ann" "$stub/out.log"'
overlap
run_tty "Post as review" "" "Post anyway" n
expect "overlap, in a terminal: no posts nothing, exit 6" \
	'[[ $rc == 6 && -z $flag ]] && grep -q "Post anyway as round 3? \[y/N\]" "$stub/out.log"'
overlap
run_tty "Post as review" "" "Post anyway" y
# previous_head_sha stays the head this review compared against (round 1's), not the round that landed meanwhile.
expect "overlap, in a terminal: yes posts as round 3, IDs after the new round" \
	'[[ $rc == 0 && $flag == --approve && $(jq -r ".round, .findings[0].id, .findings[0].first_round, .previous_head_sha" <<<"$record" |
		paste -sd, -) == "3,F6,3,h1" && $body == *"\"round\":3"* ]]'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
run
expect "first round: round 1, no loop line" '[[ $rc == 0 && $(jq -r ".round, .loop.decision, .forced" <<<"$record" | paste -sd, -) == "1,run,false" && $body != *"**Loop:**"* ]]'
run --check
expect "--check: no rounds yet exits 0" '[[ $rc == 0 ]]'
run --json
expect "--json without --check: fails" '[[ $rc == 1 && $calls == 0 ]]'

# ── round 2 and later
# Markers carry full commit IDs: anything else makes a full round.
H1=$(printf 'c1%.0s' {1..20}) H2=$(printf 'c2%.0s' {1..20}) B1=$(printf 'b1%.0s' {1..20})
add_round() { # <record-json> <markdown> -> one more posted round, in the REST reviews and in the discussion
	local n
	n=$(($(jq length "$stub/rest-reviews.json") + 1))
	jq -c --arg rec "$1" --arg md "$2" --argjson n "$n" '. + [{user: {login: "me", type: "User"}, state: "COMMENTED",
		commit_id: ($rec | fromjson | .head_sha), submitted_at: "2026-01-0\($n)T00:00:00Z",
		body: ("<!-- gh-pr-review generated -->\n<!-- gh-pr-review:round " + $rec + " -->\n" + $md)}]' \
		"$stub/rest-reviews.json" >"$stub/r.tmp" && mv "$stub/r.tmp" "$stub/rest-reviews.json"
	jq -c --arg rec "$1" --arg md "$2" --argjson n "$n" '.reviews += [{author: {login: "me"}, state: "COMMENTED",
		submittedAt: "2026-01-0\($n)T00:00:00Z",
		body: ("<!-- gh-pr-review generated -->\n<!-- gh-pr-review:round " + $rec + " -->\n" + $md)}]' \
		"$stub/discussion.json" >"$stub/d.tmp" && mv "$stub/d.tmp" "$stub/discussion.json"
}
session_file() { cat "$stub"/work/pr-review-sessions/pr-review-*/context/"$1" 2>/dev/null; }
two_rounds() { # round 1 (F1, F2) and round 2 (F1 open, F2 fixed, F3 new), both Sound
	add_round '{"schema":1,"source":"model","round":1,"head_sha":"'"$H1"'","base_sha":"'"$B1"'","approach":"sound","ready":"no","code_review":true,"findings":[{"id":"F1","severity":"important","status":"new","first_round":1,"file":"a.js","line":3,"title":"thing breaks"},{"id":"F2","severity":"minor","status":"new","first_round":1,"file":"b.js","line":1,"title":"nit"}],"counts":{"open_blocking":1,"critical":0,"important":1,"minor":1}}' \
		$'### Approach\n\n**Approach:** Sound\n\n### Issues\n- round one'
	add_round '{"schema":1,"source":"model","round":2,"head_sha":"'"$H2"'","base_sha":"'"$B1"'","approach":"sound","ready":"no","code_review":true,"findings":[{"id":"F1","severity":"important","status":"open","first_round":1,"file":"a.js","line":3,"title":"thing breaks"},{"id":"F2","severity":"minor","status":"fixed","first_round":1,"file":"b.js","line":1,"title":"nit"},{"id":"F3","severity":"critical","status":"new","first_round":2,"file":"c.js","line":9,"title":"data loss"}],"counts":{"open_blocking":2,"critical":1,"important":1,"minor":0}}' \
		$'### Approach\n\n**What it does:** x\n\n**Approach:** Sound\n\n### Issues\n- **F3 · `c.js:9`** — data loss'
}
round3=$'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **F3 · `c.js:9`** — still loses data.\n'
round3+=$'#### ⚠️ Important (Should Fix)\n- **`d.js:2`** — retry loop has no bound.\n\n**Ready to merge?** No\n\n'
round3+=$'```json findings\n[{"id":"F1","status":"fixed","severity":"important","file":"a.js","line":3,"title":"thing breaks","in_delta":false,"later":false},\n'
round3+=$' {"id":"F3","status":"open","severity":"critical","file":"c.js","line":9,"title":"data loss","in_delta":false,"later":false},\n'
round3+=$' {"id":null,"status":"new","severity":"important","file":"d.js","line":2,"title":"retry loop has no bound","in_delta":true,"later":false},\n'
round3+=$' {"id":null,"status":"new","severity":"minor","file":"e.js","line":5,"title":"old helper is slow","in_delta":false,"later":true}]\n```'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes'
run
expect "round 1: no Previous round section" '[[ $rc == 0 ]] && ! grep -q "## Previous round" "$stub/code-prompt.txt"'
expect "round 1: no previous verdict for the owner" '! grep -q "Your previous verdict" "$stub/owner-prompt.txt"'
expect "round 1: a full round, no progress line" '[[ $(jq -r ".mode, .mode_reason" <<<"$record" | paste -sd, -) == "full,no previous round" && $body != *"### Round "* ]]'

setup $'### Approach\n\n**Approach:** Sound' "$round3"
two_rounds
run
expect "round 3: incremental since round 2" '[[ $rc == 0 && $(jq -r ".round, .mode, .previous_head_sha" <<<"$record" | paste -sd, -) == "3,incremental,$H2" ]] && grep -q "mode: incremental since round 2" "$stub/out.log"'
expect "round 3: open IDs are mandatory, fixed ones only if back" 'grep -q "Every open ID listed is mandatory" "$stub/code-prompt.txt" && grep -q "Those are not mandatory: report one only if the problem is back" "$stub/code-prompt.txt"'
expect "round 3: the code prompt has the three rules" 'grep -q "## Previous round" "$stub/code-prompt.txt" && grep -q "Check every earlier finding" "$stub/code-prompt.txt" && grep -q "Review what changed since round 2 in full" "$stub/code-prompt.txt" && grep -q "Outside what changed, raise only Critical" "$stub/code-prompt.txt"'
expect "round 3: the diff since the previous head" 'grep -qF "git diff --stat $H2..aaaa" "$stub/code-prompt.txt" && grep -qF "git diff $H2..aaaa" "$stub/code-prompt.txt"'
expect "round 3: the later-round output format" 'grep -q "Fixed since the last round" "$stub/code-prompt.txt" && grep -q "\"id\": \"F3\" or null" "$stub/code-prompt.txt"'
expect "round 3: the findings block asks for a decline's reason" 'grep -qF "\"reason\": \"<the quoted reason>\" or null" "$stub/code-prompt.txt" && grep -qF "Quote it, in \`\"reason\"\`" "$stub/code-prompt.txt"'
expect "round 3: previous-findings.md lists the open findings first" '[[ $(session_file previous-findings.md | sed -n 1,2p) == "F1 · important · a.js:3 · thing breaks"$'"'"'\n'"'"'"F3 · critical · c.js:9 · data loss" ]]'
expect "round 3: then the fixed ones, to catch a regression" '[[ $(session_file previous-findings.md | sed -n 4,5p) == "Fixed in round 2 (report one only if the problem is back, as open):"$'"'"'\n'"'"'"F2 · minor · b.js:1 · nit" ]]'
expect "round 3: previous-review.md is round 2 without markers" '[[ $(session_file previous-review.md) == *"F3 · \`c.js:9\`"* && $(session_file previous-review.md) != *"<!--"* ]]'
expect "round 3: delta-files.txt" '[[ $(session_file delta-files.txt) == d.js ]]'
expect "round 3: statuses and IDs" '[[ $(jq -r "([.findings[] | .id + \":\" + .status] | join(\" \")), (.later | map(.id) | join(\" \")), .counts.open_blocking" <<<"$record" | paste -sd, -) == "F1:fixed F3:open F4:new,L1,2" ]]'
expect "round 3: a churning loop adds the next move" '[[ $body == *"loop: churning"*"**Next:** "* ]]'
expect "round 3: the progress line opens the body" '[[ $(sed -n 3p <<<"$body") == "### Round 3 · since round 2" && $(sed -n 4p <<<"$body") == "1 fixed · 1 still open · 1 new (1 in the new commits) · 1 for later · open blocking: 2 (was 2)"* ]]'
expect "round 3: the owner starts from its previous verdict" 'grep -q "## Your previous verdict (round 2)" "$stub/owner-prompt.txt" && grep -q "Unchanged since round 2" "$stub/owner-prompt.txt" && grep -qF "git diff --stat $H2..aaaa" "$stub/owner-prompt.txt"'
expect "round 3: previous-approach.md is the Approach section" '[[ $(session_file previous-approach.md) == "### Approach"*"**Approach:** Sound" ]]'
expect "round 3: the record keeps the label of this round" '[[ $(jq -r ".loop.label" <<<"$record") == churning ]]'

setup $'### Approach\n\nUnchanged since round 2: it still fits.\n\n**Approach:** Sound' "$round3"
two_rounds
run
expect "owner short form: posted as is, and its verdict parses" '[[ $rc == 0 && $body == *"Unchanged since round 2: it still fits."* && $(jq -r ".approach" <<<"$record") == sound && $calls == 2 ]]'

setup $'### Approach\n\nUnchanged since round 2.\n\n**Approach:** Rethink' "$round3"
two_rounds
run
expect "owner: a changed verdict line wins over Unchanged" '[[ $(jq -r ".approach, .code_review" <<<"$record" | paste -sd, -) == "rethink,false" && $calls == 1 ]]'

# No findings block in round 3: the Markdown fallback reads the later-round format.
md3=$'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **F3 · `c.js:9`** — still loses data.\n'
md3+=$'#### ⚠️ Important (Should Fix)\n- **[d.js:2]** — retry loop has no bound.\n#### 💡 Minor (Nice to Have)\n*(none found)*\n\n'
md3+=$'<details><summary>Fixed since the last round (1)</summary>\n\n- **F1** — the check is in.\n\n</details>\n\n'
md3+=$'<details><summary>Later (1)</summary>\n\n- **[e.js:5]** — old helper is slow.\n\n</details>\n\n**Ready to merge?** No'
setup $'**Approach:** Sound' "$md3"
two_rounds
run
expect "round 3 without a block: IDs from the Markdown, nothing counted twice" '[[ $(jq -r ".source, ([.findings[] | .id + \":\" + .status] | join(\" \")), .counts.open_blocking, .counts.unverified, .counts.minor" <<<"$record" | paste -sd, -) == "parsed,F3:open F4:new F1:fixed,2,0,0" ]]'

setup $'**Approach:** Sound' "$round3"
two_rounds
touch "$stub/git.rebased"
run
expect "rebased: a range-diff of the two versions" '[[ $(jq -r ".mode" <<<"$record") == rebased ]] && grep -qF "git range-diff $B1..$H2 bbbb..aaaa" "$stub/code-prompt.txt" && grep -q "The author rebased" "$stub/code-prompt.txt"'

setup $'**Approach:** Sound' "$round3"
two_rounds
echo "$H2" >"$stub/git.missing"
run
expect "previous head gone: a full round that says why" '[[ $(jq -r ".mode" <<<"$record") == full ]] && grep -q "mode: full (previous head ${H2:0:12} not found after fetch)" "$stub/out.log"'
expect "previous head gone: rule 1 only" 'grep -q "Check every earlier finding" "$stub/code-prompt.txt" && ! grep -q "Outside what changed" "$stub/code-prompt.txt" && grep -q "This round is a full review" "$stub/code-prompt.txt"'
expect "previous head gone: the progress line says full review" '[[ $(sed -n 4p <<<"$body") == *"full review (previous head ${H2:0:12} not found after fetch)" ]]'

setup $'**Approach:** Sound' "$round3"
two_rounds
touch "$stub/git.diff-fails"
run
expect "file list fails: a full round that says why" '[[ $(jq -r ".mode, .mode_reason" <<<"$record" | paste -sd, -) == "full,could not list the files the changes touched" ]] && grep -q "mode: full (could not list the files" "$stub/out.log"'
expect "file list fails: no delta-files.txt, rule 1 only" '[[ -z $(session_file delta-files.txt) ]] && grep -q "Check every earlier finding" "$stub/code-prompt.txt" && ! grep -q "Outside what changed" "$stub/code-prompt.txt" && ! grep -q "delta-files.txt" "$stub/code-prompt.txt"'

setup $'**Approach:** Sound' "$round3"
two_rounds
run --full
expect "--full: a full round with rule 1 only" '[[ $(jq -r ".mode, .mode_reason" <<<"$record" | paste -sd, -) == "full,--full" ]] && grep -q "Check every earlier finding" "$stub/code-prompt.txt" && ! grep -q "Outside what changed" "$stub/code-prompt.txt"'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes\n\n```json findings\n[{"id":"F3","status":"open","severity":"critical","file":"c.js","line":9,"title":"data loss","in_delta":false,"later":false},{"id":"F1","status":"fixed","severity":"important","file":"a.js","line":3,"title":"thing breaks","in_delta":false,"later":false}]\n```'
two_rounds
run
expect "ready override: Yes with a blocking finding open posts as comment" '[[ $flag == --comment && $(jq -r ".ready, .ready_overridden" <<<"$record" | paste -sd, -) == "yes,true" ]] && grep -q "blocking findings are still open" "$stub/out.log"'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes\n\n```json findings\n[{"id":"F3","status":"declined","severity":"critical","in_delta":false,"later":false},{"id":"F1","status":"fixed","in_delta":false,"later":false},{"id":null,"status":"new","severity":"critical","file":"x.js","line":1,"title":"leaks a token","in_delta":false,"later":true}]\n```'
two_rounds
run
expect "model output cannot drop a blocker: no reason, no decline; a Critical is never Later" '[[ $flag == --comment && $(jq -r "([.findings[] | .id + \":\" + .status + (if .unverified then \"?\" else \"\" end)] | join(\" \")), (.later | length), .counts.open_blocking" <<<"$record" | paste -sd, -) == "F3:open? F1:fixed F4:new,0,2" ]]'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes\n\n```json findings\n[]\n```'
two_rounds
run
expect "unverified: a forgotten finding is carried as open, not re-checked" '[[ $(jq -r "[.findings[] | select(.unverified) | .id] | join(\" \")" <<<"$record") == "F1 F3" && $body == *"2 not re-checked"* && $flag == --comment ]]'

# Round 2 fixed the last open finding: round 3 still watches it, and a comeback keeps its ID.
fixed_only() {
	add_round '{"schema":1,"source":"model","round":1,"head_sha":"'"$H1"'","base_sha":"'"$B1"'","approach":"sound","ready":"no","code_review":true,"findings":[{"id":"F1","severity":"important","status":"new","first_round":1,"file":"a.js","line":3,"title":"thing breaks"}],"counts":{"open_blocking":1,"critical":0,"important":1,"minor":0}}' $'### Issues\n- round one'
	add_round '{"schema":1,"source":"model","round":2,"head_sha":"'"$H2"'","base_sha":"'"$B1"'","approach":"sound","ready":"yes","code_review":true,"findings":[{"id":"F1","severity":"important","status":"fixed","first_round":1,"file":"a.js","line":3,"title":"thing breaks"}],"counts":{"open_blocking":0,"critical":0,"important":0,"minor":0}}' $'### Issues\n- round two, all fixed'
}
setup $'**Approach:** Sound' $'**Ready to merge?** No\n\n```json findings\n[{"id":"F1","status":"open","severity":"important","file":"a.js","line":3,"title":"thing breaks again","in_delta":true,"later":false}]\n```'
fixed_only
run
expect "only fixed before: previous-findings.md lists them" '[[ $(session_file previous-findings.md) == "Fixed in round 2 (report one only if the problem is back, as open):"$'"'"'\n'"'"'"F1 · important · a.js:3 · thing breaks" ]] && [[ $(session_file previous-review.md) == *"round two, all fixed"* ]]'
expect "only fixed before: rule 1 asks whether one came back, nothing mandatory" 'grep -q "Check whether an earlier finding came back" "$stub/code-prompt.txt" && ! grep -q -e "Check every earlier finding" -e "is mandatory" "$stub/code-prompt.txt" && grep -q "Fixed since the last round" "$stub/code-prompt.txt"'
expect "only fixed before: the comeback keeps its ID, regressed and blocking" '[[ $(jq -r "(.findings | map(.id + \":\" + .status) | join(\" \")), .counts.open_blocking" <<<"$record" | paste -sd, -) == "F1:regressed,1" && $body == *"1 regressed"* ]]'
run --full
expect "only fixed before, --full: still watches them" '[[ $(jq -r .mode <<<"$record") == full ]] && grep -q "Check whether an earlier finding came back" "$stub/code-prompt.txt"'

# A marker cut to fit the size cap: the counts survive, the findings do not. Nothing can be re-checked by ID, so the
# round reviews the whole PR, as a first code review.
for capped in '"findings_dropped":true' '"findings_dropped":false'; do
	setup $'**Approach:** Sound' $'**Ready to merge?** Yes\n\n```json findings\n[]\n```'
	add_round '{"schema":1,"source":"model","round":1,"head_sha":"'"$H1"'","base_sha":"'"$B1"'","approach":"sound","ready":"no","code_review":true,"findings":[{"id":"F1","severity":"important","status":"new","first_round":1,"file":"a.js","line":3,"title":"thing breaks"}],"counts":{"open_blocking":1,"critical":0,"important":1,"minor":0}}' $'### Issues\n- round one'
	add_round '{"schema":1,"source":"model","round":2,"head_sha":"'"$H2"'","base_sha":"'"$B1"'","approach":"sound","ready":"no","code_review":true,'"$capped"',"last_ids":{"F":3,"L":0},"counts":{"open_blocking":3,"critical":1,"important":2,"minor":0}}' $'### Issues\n- round two'
	run
	expect "capped marker ($capped): a full round that says why" '[[ $rc == 0 && $(jq -r ".round, .mode, .mode_reason" <<<"$record" | paste -sd, -) == "3,full,the last record lost its findings to the size cap" ]] && grep -q "mode: full (the last record lost its findings" "$stub/out.log"'
	expect "capped marker ($capped): no rule 1, no rule 3, the first-round format" '! grep -q -e "## Previous round" -e "Check every earlier finding" -e "Outside what changed" -e "Fixed since the last round" "$stub/code-prompt.txt" && [[ -z $(session_file previous-findings.md) ]]'
	expect "capped marker ($capped): an empty reply does not claim progress over the lost findings" '[[ $(sed -n 4p <<<"$body") == "open blocking: 0 · "* && $body != *"(was 3)"* && $(sed -n 4p <<<"$body") == *"full review (the last record lost its findings to the size cap)" ]]'
done

setup $'### Approach\n\n**Approach:** Sound' "$round3"
add_round '{"schema":1,"source":"model","round":1,"head_sha":"'"$H1"'","base_sha":"'"$B1"'","approach":"rethink","ready":"unknown","code_review":false,"findings":[],"counts":{"open_blocking":null}}' $'### Approach\n\n**Approach:** Rethink'
run
expect "after a Rethink-only round: judged afresh, and a full first code review" '! grep -q "Your previous verdict" "$stub/owner-prompt.txt" && ! grep -q "## Previous round" "$stub/code-prompt.txt" && [[ $(jq -r ".round, .mode, .mode_reason" <<<"$record" | paste -sd, -) == "2,full,no earlier code review" ]]'

# ── producer to consumer: a posted round, returned as GitHub returns it, read back by rounds --json and --check
block=$'```json findings\n[{"severity":"important","file":"a.js","line":3,"title":"thing breaks"}]\n```'
setup $'**Approach:** Sound' $'### Issues\n#### ⚠️ Important (Should Fix)\n- **`a.js:3` — thing breaks.**\n\n**Ready to merge?** Yes with fixes\n\n'"$block"
run
expect "round trip: round 1 posted" '[[ $rc == 0 && $flag == --comment ]]'
jq -n --arg body "$body" '[{id: 11, user: {login: "me", type: "User"}, state: "COMMENTED", commit_id: "head1",
	submitted_at: "2026-05-01T10:00:00Z", body: $body}]' >"$stub/rest-reviews.json"
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
finished=true
exit "$fail"
