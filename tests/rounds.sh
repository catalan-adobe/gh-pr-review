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
marker='{"schema":1,"source":"model","round":2,"head_sha":"bbbbbbb2","posted_at":"2026-01-03T10:00:00Z",'
marker+='"approach":"sound","ready":"yes-with-fixes","code_review":true,"findings":[],'
marker+='"counts":{"open_blocking":1,"critical":0,"important":1,"minor":1}}'
marker_body="<!-- gh-pr-review generated -->${nl}<!-- gh-pr-review:round ${marker} -->${nl}**Ready to merge?** Yes with fixes"
rethink_body="<!-- gh-pr-review generated -->${nl}### Approach${nl}**Approach:** Rethink"

jq -n --arg b "$backfill_body" --arg m "$marker_body" --arg r "$rethink_body" '[
	{body: "plain human review", commit_id: "x", submitted_at: "2026-01-01T08:00:00Z", user: {login: "carol"}},
	{body: $r, commit_id: "ddddddd4", submitted_at: "2026-01-04T10:00:00Z", user: {login: "me"}},
	{body: $b, commit_id: "aaaaaaa1", submitted_at: "2026-01-02T10:00:00Z", user: {login: "me"}},
	{body: $m, commit_id: "bbbbbbb2", submitted_at: "2026-01-03T10:00:00Z", user: {login: "me"}}]' >"$stub/reviews.json"
jq -n '[{commit: {committer: {date: "2026-01-01T09:00:00Z"}}}, {commit: {committer: {date: "2026-01-02T12:00:00Z"}}},
	{commit: {committer: {date: "2026-01-02T13:00:00Z"}}}, {commit: {committer: {date: "2026-01-03T12:00:00Z"}}}]' \
	>"$stub/commits.json"
cat >"$stub/gh" <<S
#!/usr/bin/env bash
case "\$*" in
*pulls/1/reviews*) cat "$stub/reviews.json" ;;
*pulls/1/commits*) cat "$stub/commits.json" ;;
*"pr view"*) echo '{"additions":10,"deletions":2,"changedFiles":3,"headRefOid":"eeeeeee5"}' ;;
*) echo "unexpected gh call: \$*" >&2; exit 9 ;;
esac
S
chmod +x "$stub/gh"

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

out=$(rounds) && rc=0 || rc=$?
expect "rounds: a PR is required" '[[ $rc != 0 && $out == *Usage* ]]'
exit "$fail"
