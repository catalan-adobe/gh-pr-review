#!/usr/bin/env bash
# Runs the whole gh-pr-review script with stub git, gh and pi, and checks the orchestration:
# how many model calls run, what the code review gets, and what is posted.
# Conditions are single-quoted on purpose: expect() evals them after each run sets rc, calls, body and flag.
# shellcheck disable=SC2016,SC2034
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
	cat >"$stub/bin/gh" <<S
#!/usr/bin/env bash
case "\$*" in
*"auth status"*) exit 0 ;;
*"api"*user*) echo me ;;
*graphql*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
*"--json comments,reviews"*) [[ "${3:-0}" == 0 ]] || exit ${3:-0}; cat "$stub/discussion.json" ;;
*"pr view"*) echo '{"title":"T","body":"B","headRefName":"h","baseRefName":"main","author":{"login":"bob"},"additions":1,"deletions":0,"changedFiles":1}' ;;
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

run() { # extra args...
	(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
		bash "$root/gh-pr-review" https://github.com/o/r/pull/1 -y "$@" >"$stub/out.log" 2>&1) && rc=0 || rc=$?
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

setup $'**Approach:** Sound' $'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **`b.js:9` — data loss.**\n\n**Ready to merge?** No'
run
expect "records: no block falls back to parsing" '[[ $rc == 0 && $(jq -r ".source, .findings[0].severity, .counts.open_blocking" <<<"$record" | paste -sd, -) == "parsed,critical,1" ]]'

setup $'### Approach\n**Approach:** Rethink' 'never used'
run
expect "records: a Rethink has no code review" '[[ $(jq -r ".code_review, .counts.open_blocking" <<<"$record" | paste -sd, -) == "false,null" ]]'
expect "records: a Rethink posts its marker" '[[ $body == *"gh-pr-review:round"* ]]'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes\n\n```json findings\n[{"severity":"minor","file":"c.js","line":1,"title":"nit"}]\n```'
prev='{"schema":1,"round":2,"head_sha":"old","findings":[{"id":"F1","severity":"minor","status":"new"},{"id":"F3","severity":"important","status":"new"}]}'
jq -n --arg prev "<!-- gh-pr-review:round $prev -->" '{comments: [], reviews: [
	{author: {login: "x"}, state: "COMMENTED", submittedAt: "2026-01-01T00:00:00Z", body: "<!-- gh-pr-review generated -->\nold round"},
	{author: {login: "y"}, state: "COMMENTED", submittedAt: "2026-01-02T00:00:00Z", body: "a human review"},
	{author: {login: "x"}, state: "COMMENTED", submittedAt: "2026-01-03T00:00:00Z", body: ("<!-- gh-pr-review generated -->\n" + $prev + "\nround two")}]}' >"$stub/discussion.json"
run
expect "records: earlier generated reviews count as rounds" '[[ $(jq -r ".round" <<<"$record") == 3 ]]'
expect "records: finding IDs continue from the previous record" '[[ $(jq -r ".findings[0].id, .previous_head_sha" <<<"$record" | paste -sd, -) == "F4,old" ]]'

setup $'**Approach:** Sound' $'**Ready to merge?** Yes\n\n```json findings\n[]\n```'
run --no-post
expect "records: --no-post keeps a preview record and posts nothing" '[[ -z $flag && $(jq -r ".preview, .decision" <<<"$record" | paste -sd, -) == "true,null" ]]'
exit "$fail"
