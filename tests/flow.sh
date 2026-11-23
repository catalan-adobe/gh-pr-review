#!/usr/bin/env bash
# Runs the whole gh-pr-review script with stub git, gh and pi, and checks the orchestration:
# how many model calls run, what the code review gets, and what is posted.
# Conditions are single-quoted on purpose: expect() evals them after each run sets rc, calls, body and flag.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fail=0

setup() { # approach-output code-review-output [discussion-exit-code]
	stub=$(mktemp -d)
	mkdir -p "$stub/bin" "$stub/home/.pi/agent" "$stub/work"
	echo '{"github-copilot":{}}' >"$stub/home/.pi/agent/auth.json"
	printf '%s' "$1" >"$stub/approach.out"
	printf '%s' "$2" >"$stub/review.out"
	cat >"$stub/bin/gh" <<S
#!/usr/bin/env bash
case "\$*" in
*"auth status"*) exit 0 ;;
*"api"*user*) echo me ;;
*"--json comments,reviews"*) [[ "${3:-0}" == 0 ]] || exit ${3:-0}; echo '{"comments":[],"reviews":[]}' ;;
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
if [[ "\${*: -1}" == *"long-time maintainer"* ]]; then cat "$stub/approach.out"; else
	printf '%s' "\${*: -1}" >"$stub/code-prompt.txt"; cat "$stub/review.out"; fi
S
	chmod +x "$stub/bin/"*
}

run() { # extra args...
	(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
		bash "$root/gh-pr-review" https://github.com/o/r/pull/1 -y "$@" >"$stub/out.log" 2>&1) && rc=0 || rc=$?
	calls=$(cat "$stub/pi.calls" 2>/dev/null | wc -l | tr -d ' ')
	body=$(sed -n '/^--body$/,$p' "$stub/posted.args" 2>/dev/null | sed 1d || true)
	flag=$(grep -x -- '--\(comment\|approve\|request-changes\)' "$stub/posted.args" 2>/dev/null || true)
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
expect "sound: posts approach then review" '[[ $body == *"**Approach:** Sound"*"**Ready to merge?** Yes"* ]]'
expect "sound: approves on bare yes" '[[ $flag == --approve ]]'

setup $'### Approach\n**Approach:** Rethink — use lib/http' 'never used'
run
expect "rethink: one model call" '[[ $calls == 1 ]]'
expect "rethink: posts the approach only" '[[ $body == *"**Approach:** Rethink"* && $body != *"never used"* ]]'
expect "rethink: requests changes" '[[ $flag == --request-changes ]]'

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
expect "skip-approach: one model call" '[[ $calls == 1 ]]'
expect "skip-approach: no discussion fetch needed" '[[ $rc == 0 && $flag == --request-changes ]]'
expect "skip-approach: no approach in body" '[[ $body != *"Approach"* ]]'
exit "$fail"
