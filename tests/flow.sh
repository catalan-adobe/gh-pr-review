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
	rm -f "$stub/git.base" "$stub/git.missing" "$stub/git.rebased" "$stub/git.retargeted" "$stub/git.diff-fails" "$stub/git.far-base" "$stub/git.deepened"
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
	# git: HEAD is the first line of heads (the PR head the clone checks out) and the merge-base bbbb (or the SHA in
	# git.base). Any other SHA resolves to itself, unless listed in git.missing. The previous head is an ancestor of the head unless git.rebased exists, and the previous base one of the base unless
	# git.retargeted exists. git.diff-fails makes `git diff` fail.
	# git.far-base: no merge-base until a `fetch --deepen` (logged in git.deepened); "never": not even then.
	cat >"$stub/bin/git" <<'S'
#!/usr/bin/env bash
s=$(cd "$(dirname "$0")/.." && pwd)
H=$(head -1 "$s/heads" 2>/dev/null || echo aaaa) B=$(cat "$s/git.base" 2>/dev/null || echo bbbb)
for a in "$@"; do [[ "$a" == clone ]] && mkdir -p "${@: -1}"; done
case "$*" in
*"rev-parse --is-shallow-repository"*) echo false ;;
*"rev-parse --verify"*)
	sha=${*: -1}
	sha=${sha%^\{commit\}}
	if grep -qx -- "$sha" "$s/git.missing" 2>/dev/null; then exit 1; fi
	[[ $sha == HEAD ]] && sha=$H
	echo "$sha"
	;;
*rev-parse*) echo "$H" ;;
*"fetch "*--deepen*) printf '%s\n' "$*" >>"$s/git.deepened" ;;
*"merge-base --is-ancestor"*" $H") [[ ! -f "$s/git.rebased" ]] ;;
*"merge-base --is-ancestor"*" $B") [[ ! -f "$s/git.retargeted" ]] ;;
*"merge-base --is-ancestor"*) true ;;
*merge-base*)
	if [[ -f "$s/git.far-base" ]] && { [[ ! -f "$s/git.deepened" ]] || grep -qx never "$s/git.far-base"; }; then exit 1; fi
	echo "$B"
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

# A clean code review: a severity section that says none, so its blockers are known (0) and a bare yes approves.
clean=$'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n*(none found)*\n\n### Assessment\n**Ready to merge?** Yes'
setup $'### Approach\n**Approach:** Sound' "$clean"
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
setup $'**Approach:** Sound' "$clean" 0 owner
run
expect "owner pass fails: run fails" '[[ $rc != 0 ]]'
expect "owner pass fails: no code review" '[[ $calls == 1 ]]'
expect "owner pass fails: nothing posted" '[[ -z $flag ]]'

setup $'**Approach:** Sound' "$clean" 0 code
run
expect "code review fails: run fails" '[[ $rc != 0 ]]'
expect "code review fails: nothing posted" '[[ -z $flag ]]'
expect "code review fails: names the session" 'grep -q "pr-review-sessions/pr-review-" "$stub/out.log"'
setup $'**Approach:** Sound' "$clean"
run --instructions 'Focus on db/ and $(skip) nits'
expect "instructions: owner prompt gets them" 'grep -qF "Focus on db/ and \$(skip) nits" "$stub/owner-prompt.txt"'
expect "instructions: code prompt gets them" 'grep -qF "Focus on db/ and \$(skip) nits" "$stub/code-prompt.txt"'
expect "instructions: owner prompt has them before the steps" '[[ $(grep -n -e "Reviewer instructions" -e "^## Steps" "$stub/owner-prompt.txt" | head -1) == *instructions* ]]'
expect "instructions: both prompts say not to quote them" 'grep -q "do not quote" "$stub/owner-prompt.txt" && grep -q "do not quote" "$stub/code-prompt.txt"'
expect "instructions: not posted" '[[ $rc == 0 && $body != *"Focus on db/"* ]]'

setup $'**Approach:** Sound' "$clean"
run
expect "no instructions: no section in either prompt" '! grep -q "Reviewer instructions" "$stub/owner-prompt.txt" "$stub/code-prompt.txt"'

setup 'unused' 'unused'
run --instructions
expect "instructions without a value: fails before any model call" '[[ $rc != 0 && $calls == 0 ]] && grep -q "requires" "$stub/out.log"'
setup 'unused' 'unused'
run --instructions --no-post
expect "instructions followed by a flag: fails, nothing posted" '[[ $rc != 0 && $calls == 0 && -z $flag ]]'
setup $'**Approach:** Sound' "$clean"
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

# The bullet has no location: a located one must match a block entry's location (block_covers_markdown).
block=$'```json findings\n[{"severity":"important","file":"secret/plan.md","line":3,"title":"SECRET note from the instructions"}]\n```'
setup $'**Approach:** Sound' $'### Issues\n#### ⚠️ Important (Should Fix)\n- **Thing breaks.**\n\n**Ready to merge?** No\n\n'"$block"
run
expect "records: text only in the findings block is not posted" \
	'[[ $rc == 0 && $body == *"gh-pr-review:round"* && $body != *SECRET* && $body != *secret/plan.md* ]]'
expect "records: round.json keeps it" '[[ $(jq -r ".source, .findings[0].title" <<<"$record" | paste -sd, -) == "model,SECRET note from the instructions" ]]'

# A code review of only whitespace is a failed run: nothing posted.
setup $'**Approach:** Sound' $'  \n\t\n   '
run
expect "an empty code review: exit 1, nothing posted" \
	'[[ $rc == 1 && -z $flag ]] && grep -q "the code review came back empty" "$stub/out.log"'

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

setup $'**Approach:** Sound' $'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **`n.go:4` — Nil dereference.**\n\n**Ready to merge?** No\n\n```json findings\n[{"id":"F999","status":"open","title":"Nil dereference"}]\n```'
run
expect "records: an invented ID without a severity falls back to the Markdown" \
	'[[ $rc == 0 && $(jq -r ".source, .counts.critical, .findings[0].id, .findings[0].file" <<<"$record" | paste -sd, -) == "parsed,1,F1,n.go" ]]'

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
compacted='{"schema":1,"round":2,"head_sha":"old","findings_dropped":true,"counts":{"open_blocking":0,"critical":0,"important":0,"minor":0}}'
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
	setup $'**Approach:** Sound' "$clean"
	break_record "$mode"
	run
	expect "record $mode: the review is still posted, without a marker" \
		'[[ $rc == 0 && $body == *"Ready to merge?"* && $body != *"gh-pr-review:round"* ]] &&
			grep -q "could not write the round record" "$stub/out.log"'
	expect "record $mode: no record, so a bare yes comments instead of approving" \
		'[[ $flag == --comment && -z $record ]] && grep -q "posting as comment, not approve" "$stub/out.log"'
done

setup $'**Approach:** Sound' "$clean"
break_record posted
run_tty "Post as review" ""
expect "posted record fails, default approve taken at the prompt: posts as comment, without a marker" \
	'[[ $rc == 0 && $flag == --comment && $body != *"gh-pr-review:round"* ]] &&
		grep -q "posting as comment, not approve" "$stub/out.log" && grep -q "Enter = approve" "$stub/out.log"'
run_tty "Post as review" a
expect "posted record fails, approve typed at the prompt: stays an approval" '[[ $rc == 0 && $flag == --approve ]]'

# A valid preview that is gone by the time the review is posted: no posted record, so no marker and no automatic
# approval; an approval chosen at the prompt stays.
setup $'**Approach:** Sound' "$clean"
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

setup $'**Approach:** Sound' "$clean"
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

setup $'**Approach:** Sound' "$clean"
rounds_with 9 12 8 >"$stub/rest-reviews.json"
run
expect "loop warn: the round runs" '[[ $rc == 0 && $calls == 2 ]]'
expect "loop warn: the progress line comes right after the markers" '[[ $(sed -n 3p <<<"$body") == "### Round 4 · since round 3" && $body != *"**Loop:**"* ]]'
expect "loop warn: the decision still comes from Ready to merge" '[[ $flag == --approve ]]'
run --check
expect "--check: warn exits 0, no model call" '[[ $rc == 0 && $calls == 0 ]]'

setup $'**Approach:** Sound' "$clean"
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
setup 'unused' "$clean"
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
setup $'**Approach:** Sound' "$clean"
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
setup $'**Approach:** Sound' "$clean"
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
setup $'**Approach:** Sound' "$clean"
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
setup $'**Approach:** Sound' "$clean"
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

setup $'**Approach:** Sound' "$clean"
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
expect "round 3: the diff since the previous head" 'grep -qF "git diff --stat $H2..head1" "$stub/code-prompt.txt" && grep -qF "git diff $H2..head1" "$stub/code-prompt.txt"'
expect "round 3: the later-round output format" 'grep -q "Fixed since the last round" "$stub/code-prompt.txt" && grep -q "\"id\": \"F3\" or null" "$stub/code-prompt.txt"'
expect "round 3: the findings block asks for a decline's reason" 'grep -qF "\"reason\": \"<the quoted reason>\" or null" "$stub/code-prompt.txt" && grep -qF "Quote it, in \`\"reason\"\`" "$stub/code-prompt.txt"'
expect "round 3: previous-findings.md lists the open findings first" '[[ $(session_file previous-findings.md | sed -n 1,2p) == "F1 · important · a.js:3 · thing breaks"$'"'"'\n'"'"'"F3 · critical · c.js:9 · data loss" ]]'
expect "round 3: then the fixed ones, to catch a regression" '[[ $(session_file previous-findings.md | sed -n 4,5p) == "Fixed in round 2 (report one only if the problem is back, as open):"$'"'"'\n'"'"'"F2 · minor · b.js:1 · nit" ]]'
expect "round 3: previous-review.md is round 2 without markers" '[[ $(session_file previous-review.md) == *"F3 · \`c.js:9\`"* && $(session_file previous-review.md) != *"<!--"* ]]'
expect "round 3: delta-files.txt" '[[ $(session_file delta-files.txt) == d.js ]]'
expect "round 3: statuses and IDs" '[[ $(jq -r "([.findings[] | .id + \":\" + .status] | join(\" \")), (.later | map(.id) | join(\" \")), .counts.open_blocking" <<<"$record" | paste -sd, -) == "F1:fixed F3:open F4:new,L1,2" ]]'
expect "round 3: a churning loop adds the next move" '[[ $body == *"loop: churning"*"**Next:** "* ]]'
expect "round 3: the progress line opens the body" '[[ $(sed -n 3p <<<"$body") == "### Round 3 · since round 2" && $(sed -n 4p <<<"$body") == "1 fixed · 1 still open · 1 new (1 in the new commits) · 1 for later · open blocking: 2 (was 2)"* ]]'
expect "round 3: the owner starts from its previous verdict" 'grep -q "## Your previous verdict (round 2)" "$stub/owner-prompt.txt" && grep -q "Unchanged since round 2" "$stub/owner-prompt.txt" && grep -qF "git diff --stat $H2..head1" "$stub/owner-prompt.txt"'
expect "round 3: previous-approach.md is the Approach section" '[[ $(session_file previous-approach.md) == "### Approach"*"**Approach:** Sound" ]]'
expect "round 3: the record keeps the label of this round" '[[ $(jq -r ".loop.label" <<<"$record") == churning ]]'

# Later only outside the files the delta touched: d.js is in delta-files.txt, whatever in_delta says.
setup $'### Approach\n\n**Approach:** Sound' "${round3//\"e.js\"/\"d.js\"}"
two_rounds
run
expect "round 3: a Later entry in a touched file stays a finding" \
	'[[ $(session_file delta-files.txt) == d.js && $(jq -r "(.later | length), ([.findings[] | select(.file == \"d.js\") | .severity] | join(\" \"))" <<<"$record" | paste -sd, -) == "0,important minor" ]]'

# Round 3 with no Critical in the Markdown: the block is judged as the record stores it (entry_outcome), so an entry
# the record keeps open is open for the checks, and one it stores as fixed, declined or Later is not. F3 is the open
# Critical of round 2; a finding the block leaves out is carried, unverified, and takes no part in the checks.
no_critical() { # <findings block entry, or nothing> -> round 3 with "*(none found)*" under Critical, F1 still open
	local md=$'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n\n*(none found)*\n\n'
	md+=$'#### ⚠️ Important (Should Fix)\n- **F1 · `a.js:3`** — thing breaks.\n\n**Ready to merge?** No\n\n'
	md+=$'```json findings\n[{"id":"F1","status":"open"}'"${1:+,$1}"$']\n```'
	setup $'### Approach\n\n**Approach:** Sound' "$md"
	two_rounds
	run
}
no_critical '{"id":"F3","status":"declined","reason":"by design"}'
expect "no Critical shown: F3 declined with a reason is not open: the block is used" \
	'[[ $rc == 0 && $(jq -c "[.source, (.findings[] | select(.id == \"F3\") | .status), .counts.critical]" <<<"$record") == "[\"model\",\"declined\",0]" ]]'
no_critical '{"id":"F3","status":"declined"}'
expect "no Critical shown: F3 declined without a reason is stored open: the record is parsed" \
	'[[ $rc == 0 && $(jq -r ".source" <<<"$record") == parsed ]] && grep -q "does not match the review" "$stub/out.log"'
no_critical '{"id":null,"status":"new","severity":"critical","file":"z.js","line":1,"title":"x","in_delta":false,"later":true}'
expect "no Critical shown: a Later Critical is not honoured, so open: the record is parsed" \
	'[[ $rc == 0 && $(jq -r ".source" <<<"$record") == parsed ]]'
no_critical '{"id":"F3","status":"fixed"}'
expect "no Critical shown: F3 fixed: the block is used" \
	'[[ $rc == 0 && $(jq -c "[.source, (.findings[] | select(.id == \"F3\") | .status), .counts.critical]" <<<"$record") == "[\"model\",\"fixed\",0]" ]]'
no_critical
expect "no Critical shown: F3 left out is carried, unverified, and not checked: the block is used" \
	'[[ $rc == 0 && $(jq -c "[.source, (.findings[] | select(.id == \"F3\") | [.status, .unverified])]" <<<"$record") == "[\"model\",[\"open\",true]]" ]]'

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
expect "rebased: a range-diff of the two versions" '[[ $(jq -r ".mode" <<<"$record") == rebased ]] && grep -qF "git range-diff $B1..$H2 bbbb..head1" "$stub/code-prompt.txt" && grep -q "The author rebased" "$stub/code-prompt.txt"'

setup $'**Approach:** Sound' "$round3"
two_rounds
touch "$stub/git.retargeted"
run
expect "retargeted: a full round that says why" '[[ $(jq -r ".mode, .mode_reason" <<<"$record" | paste -sd, -) == "full,the PR'"'"'s base changed" ]] && ! grep -q "Outside what changed" "$stub/code-prompt.txt"'

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

# Round 3 shows an Important for d.js in its Later list only, and its block marks it Later; d.js is in the delta, so
# the record keeps it as a finding. The empty Important section does not reject the block: the Later list shows it.
# The record has 1 blocker, and the Yes posts as comment. A Later item that does not show the entry (another file or
# line) rejects the block: the Markdown leaves the Later list out of its count, so the count is unknown: comment too.
later_promoted() { # <the Later item's location>
	local md=$'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n*(none found)*\n#### ⚠️ Important (Should Fix)\n*(none found)*\n'
	md+=$'#### 💡 Minor (Nice to Have)\n*(none found)*\n\n<details><summary>Later (1)</summary>\n\n'
	md+="- **\`$1\`** — retry loop has no bound."$'\n\n</details>\n\n**Ready to merge?** Yes\n\n```json findings\n'
	md+=$'[{"id":null,"status":"new","severity":"important","file":"d.js","line":2,"title":"retry loop has no bound","in_delta":false,"later":true}]\n```'
	setup $'**Approach:** Sound' "$md"
	fixed_only
	run
}
later_promoted d.js:2
expect "a Later entry in a touched file, shown in the Later list only: the block is used, 1 blocker, comment" \
	'[[ $rc == 0 && $flag == --comment && $(session_file delta-files.txt) == d.js &&
		$(jq -c "[.source, .counts.open_blocking, .counts.important, (.later | length), (.findings[] | select(.file == \"d.js\") | .status)]" <<<"$record") == "[\"model\",1,1,0,\"new\"]" ]]'
for elsewhere in e.js:2 d.js:40; do
	later_promoted "$elsewhere"
	expect "a Later entry in a touched file, the Later list shows $elsewhere: parsed, unknown count, comment" \
		'[[ $rc == 0 && $flag == --comment && $(jq -c "[.source, .counts.open_blocking]" <<<"$record") == "[\"parsed\",null]" ]] &&
			grep -q "blockers are unknown: posting as comment" "$stub/out.log"'
done

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

# A later round posted without its marker (no room for it): its Markdown shows only what it re-checked, so reading
# it back gives no findings list, and the next round is full.
setup $'**Approach:** Sound' $'**Ready to merge?** Yes\n\n```json findings\n[]\n```'
add_round '{"schema":1,"source":"model","round":1,"head_sha":"'"$H1"'","base_sha":"'"$B1"'","approach":"sound","ready":"no","code_review":true,"findings":[{"id":"F1","severity":"important","status":"new","first_round":1,"file":"a.js","line":3,"title":"thing breaks"}],"counts":{"open_blocking":1,"critical":0,"important":1,"minor":0}}' $'### Issues\n- round one'
jq -c --arg h "$H2" '. + [{user: {login: "me", type: "User"}, state: "APPROVED", commit_id: $h,
	submitted_at: "2026-01-02T00:00:00Z", body: "<!-- gh-pr-review generated -->\n### Round 2 · since round 1\n1 not re-checked · open blocking: 1 (was 1)\n\n### Issues\n\n*(none found)*\n\n**Ready to merge?** Yes"}]' \
	"$stub/rest-reviews.json" >"$stub/r.tmp" && mv "$stub/r.tmp" "$stub/rest-reviews.json"
run
expect "markerless later round: the next round is full and says why" \
	'[[ $rc == 0 && $(jq -r ".round, .mode, .mode_reason" <<<"$record" | paste -sd, -) == "3,full,the last round has no record of its findings" ]] && grep -q "mode: full (the last round has no record of its findings)" "$stub/out.log"'
expect "markerless later round: no claim of progress over it" '[[ $(sed -n 4p <<<"$body") == "open blocking: 0 · "* && $body != *"(was "* ]]'

setup $'### Approach\n\n**Approach:** Sound' "$round3"
add_round '{"schema":1,"source":"model","round":1,"head_sha":"'"$H1"'","base_sha":"'"$B1"'","approach":"rethink","ready":"unknown","code_review":false,"findings":[],"counts":{"open_blocking":null}}' $'### Approach\n\n**Approach:** Rethink'
run
expect "after a Rethink-only round: judged afresh, and a full first code review" '! grep -q "Your previous verdict" "$stub/owner-prompt.txt" && ! grep -q "## Previous round" "$stub/code-prompt.txt" && [[ $(jq -r ".round, .mode, .mode_reason" <<<"$record" | paste -sd, -) == "2,full,no earlier code review" ]]'

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
printf '%s' "$clean" >"$stub/review.out"
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

# The same four fixed Criticals, with "- None." as the sole Critical bullet: a "none" line as a list item is still
# empty, so the record is parsed, with no blockers, as the reader sees it.
none=$'- None.\n\n'
setup $'**Approach:** Sound' $'### Issues\n\n#### 🚨 Critical (Must Fix Before Merge)\n\n'"$none"$'#### ⚠️ Important (Should Fix)\n\n'"$none"$'#### 💡 Minor (Nice to Have)\n\n'"$none"$'### Assessment\n\n**Ready to merge?** Yes\n\n'"$block"
run
expect "records: fixed blockers in the block under - None. sections: parsed, none blocking" \
	'[[ $rc == 0 && $flag == --approve && $(jq -c "[.source, .counts.open_blocking, (.findings | length)]" <<<"$record") == "[\"parsed\",0,0]" ]] &&
		grep -q "does not match the review" "$stub/out.log"'

# A review whose Markdown has no severity heading, with one Critical in its block, so long that its marker is the
# minimal one (no counts). round.json keeps the Critical; read back, GitHub's copy says nothing about the blockers:
# unknown, never ready. Compacting the marker differently never makes it ready either.
block=$'```json findings\n[{"severity":"critical","file":"a.js","line":1,"title":"boom"}]\n```'
setup $'**Approach:** Sound' "$(head -c 59500 /dev/zero | tr '\0' x)"$'\n\n**Ready to merge?** No\n\n'"$block"
run
expect "compaction: posted with the minimal marker, round.json keeps the Critical" \
	'[[ $rc == 0 && $(jq -c "[.source, .counts.critical, (.findings | length)]" <<<"$record") == "[\"model\",1,1]" &&
		$(sed -n 2p <<<"$body" | sed "s/^<!-- gh-pr-review:round //; s/ -->$//" | jq -c "[has(\"counts\"), .findings_dropped]") == "[false,true]" ]]'
landed 41 CHANGES_REQUESTED 2026-08-01T10:00:00Z
echo head2 >"$stub/heads"
check_json
expect "compaction: the minimal marker reads back as unknown, not ready" \
	'[[ $rc == 0 && $(jq -c "[.decision, .label, .series]" "$stub/check.json") == "[\"run\",\"unknown\",[null]]" ]]'
(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
	bash "$root/gh-pr-review" rounds https://github.com/o/r/pull/1 --json >"$stub/rounds.json" 2>"$stub/out.log") && rc=0 || rc=$?
expect "compaction: the record read back has no findings and no counts" \
	'[[ $rc == 0 && $(jq -c ".records[0] | [has(\"findings\"), .findings_dropped, .counts.open_blocking, .counts.critical]" "$stub/rounds.json") == "[false,true,null,null]" ]]'
# The same review under other markers without counts: read from the Markdown, which shows no severity section, so
# unknown too, even when the marker still lists the Critical.
remark() { # jq filter on round.json -> the review's marker replaced by it
	jq --arg m "<!-- gh-pr-review:round $(jq -c "$1" <<<"$record") -->" \
		'.[-1].body |= (split("\n") | .[1] = $m | join("\n"))' "$stub/rest-reviews.json" >"$stub/r.json"
	mv "$stub/r.json" "$stub/rest-reviews.json"
}
remark 'del(.counts)'
check_json
expect "compaction: a marker with its findings but no counts: unknown, as the minimal one" \
	'[[ $rc == 0 && $(jq -c "[.decision, .label, .series]" "$stub/check.json") == "[\"run\",\"unknown\",[null]]" ]]'
remark 'del(.counts, .findings) | .findings_dropped = true'
check_json
expect "compaction: a marker with neither findings nor counts: unknown, as the minimal one" \
	'[[ $rc == 0 && $(jq -c "[.decision, .label, .series]" "$stub/check.json") == "[\"run\",\"unknown\",[null]]" ]]'

# A code review with no severity section and no findings block: parsed, and its blockers are unknown (null counts),
# never 0. Read back, it is unknown under the full marker, the minimal one and none. A bare yes then comments.
setup $'**Approach:** Sound' $'Looks fine.\n\n**Ready to merge?** Yes with fixes'
run
expect "no severity section, parsed: the record's counts are null" \
	'[[ $rc == 0 && $(jq -c "[.source, .counts.open_blocking, .counts.critical]" <<<"$record") == "[\"parsed\",null,null]" &&
		$body == *"gh-pr-review:round"* ]]'
landed 51 COMMENTED 2026-09-01T10:00:00Z
echo head2 >"$stub/heads"
for shape in 'full marker~.' 'minimal marker~{schema, round, findings_dropped: true, last_ids}' 'no marker~'; do
	if [[ -n ${shape#*~} ]]; then remark "${shape#*~}"; else
		jq '.[-1].body |= (split("\n") | del(.[1]) | join("\n"))' "$stub/rest-reviews.json" >"$stub/r.json"
		mv "$stub/r.json" "$stub/rest-reviews.json"
	fi
	check_json
	expect "no severity section, ${shape%~*}: reads back unknown, not ready" \
		'[[ $rc == 0 && $(jq -c "[.decision, .label, .series]" "$stub/check.json") == "[\"run\",\"unknown\",[null]]" ]]'
done
setup $'**Approach:** Sound' $'Looks fine.\n\n**Ready to merge?** Yes'
run
expect "no severity section, bare yes: comments, not approve" \
	'[[ $rc == 0 && $flag == --comment ]] && grep -q "blockers are unknown: posting as comment" "$stub/out.log"'
# The last landed round read back under the full marker, the minimal one and none: the loop check's decision, label
# and series are $2 each time.
reads_back() { # name want
	local shape
	want=$2
	for shape in 'full marker~.' 'minimal marker~{schema, round, findings_dropped: true, last_ids}' 'no marker~'; do
		if [[ -n ${shape#*~} ]]; then remark "${shape#*~}"; else
			jq '.[-1].body |= (split("\n") | del(.[1]) | join("\n"))' "$stub/rest-reviews.json" >"$stub/r.json"
			mv "$stub/r.json" "$stub/rest-reviews.json"
		fi
		check_json
		expect "$1, ${shape%~*}" '[[ $rc == 0 && $(jq -c "[.decision, .label, .series]" "$stub/check.json") == "$want" ]]'
	done
}
# The same with a heading in the approach that names a severity ("Important context"), whatever the verdict line looks
# like, or with none: the writer reads the code review alone (review-body.md) and the reader the text after the
# boundary line, so the round is unknown when written and when read back, never ready.
for verdict in '**Approach:** Sound' '**Approach:** _Sound_' ''; do
	setup $'### Approach\n\n#### Important context\n\nThe handler is new.'"${verdict:+$'\n\n'$verdict}" \
		$'Looks fine.\n\n**Ready to merge?** Yes'
	run
	expect "approach heading (${verdict:-no verdict}), no severity section in the code review: written unknown, comments" \
		'[[ $rc == 0 && $flag == --comment &&
			$(jq -c "[.source, .counts.open_blocking]" <<<"$record") == "[\"parsed\",null]" && $body == *"Important context"* ]]'
	landed 52 COMMENTED 2026-09-02T10:00:00Z
	echo head2 >"$stub/heads"
	reads_back "approach heading (${verdict:-no verdict}): reads back unknown, not ready" '["run","unknown",[null]]'
done
# --skip-approach: a Critical quoting a verdict line, empty Important and Minor sections, and an empty findings block.
# The block does not show the Critical: it is rejected, and the Critical is kept when written and when read back.
setup 'unused' $'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **`a.js:1` — the verdict is read from a quote.** The doc says:\n\n  > **Approach:** Sound\n\n#### ⚠️ Important (Should Fix)\n*(none found)*\n#### 💡 Minor (Nice to Have)\n*(none found)*\n\n**Ready to merge?** No\n\n```json findings\n[]\n```'
run --skip-approach
expect "skip-approach, a Critical quoting a verdict line: the empty block is rejected, the Critical kept" \
	'[[ $rc == 0 && $flag == --request-changes &&
		$(jq -c "[.source, .counts.critical, .findings[0].file]" <<<"$record") == "[\"parsed\",1,\"a.js\"]" ]] &&
		grep -q "does not match the review" "$stub/out.log"'
landed 53 CHANGES_REQUESTED 2026-09-03T10:00:00Z
echo head2 >"$stub/heads"
reads_back "skip-approach, a Critical quoting a verdict line: read back with its Critical" '["run","early",[1]]'
# A review ending in a Critical section that says none, with a Critical in the block: the footer is not part of the
# code review, so the section is empty, the block is rejected, and the round has no blockers, written and read back.
setup $'**Approach:** Sound' $'**Ready to merge?** Yes\n\n### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n*(none found)*\n\n```json findings\n[{"severity":"critical","file":"a.js","line":1,"title":"boom"}]\n```'
run
expect "last section none found, a Critical in the block: parsed, none blocking" \
	'[[ $rc == 0 && $(jq -c "[.source, .counts.open_blocking, .counts.critical]" <<<"$record") == "[\"parsed\",0,0]" ]]'
landed 54 APPROVED 2026-09-04T10:00:00Z
echo head2 >"$stub/heads"
reads_back "last section none found: read back with no blockers" '["run","ready",[0]]'
# An automatic approve needs the check that the blocker count is known to succeed: when jq fails on it, the round
# posts as comment, even with a clean review whose count is a known 0.
setup $'**Approach:** Sound' "$clean"
cat >"$stub/bin/jq" <<S
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == *'(.counts.open_blocking | type)'* ]] && exit 5; done
exec "$(command -v jq)" "\$@"
S
chmod +x "$stub/bin/jq"
run
expect "the blocker-count check fails: comments, not approve" \
	'[[ $rc == 0 && $flag == --comment && $(jq -r .counts.open_blocking <<<"$record") == 0 ]]'
rm "$stub/bin/jq"
run
expect "the blocker-count check works again: the same review approves" '[[ $rc == 0 && $flag == --approve ]]'
# Only the second check, on the posted record, fails: the event, the marker and round.json all say comment.
cat >"$stub/bin/jq" <<S
#!/usr/bin/env bash
if [[ "\$*" == *'(.counts.open_blocking | type)'* && "\${*: -1}" == *round.json.posted ]]; then exit 5; fi
exec "$(command -v jq)" "\$@"
S
chmod +x "$stub/bin/jq"
run
expect "only the pre-post blocker-count check fails: event, marker and round.json all say comment" \
	'[[ $rc == 0 && $flag == --comment &&
		$(sed -n 2p <<<"$body" | sed "s/^<!-- gh-pr-review:round //; s/ -->$//" | jq -r .decision) == comment &&
		$(jq -c "[.decision, .preview]" <<<"$record") == "[\"comment\",false]" ]] &&
		grep -q "blockers are unknown: posting as comment" "$stub/out.log"'
rm "$stub/bin/jq"
# An automatic approve needs a successful check that the count is 0, not only a number. Round 3 says Yes with F3, a
# Critical, still open (1 blocker, ready_overridden). The lookup of ready_overridden fails: the count check still
# comments. When the first count check wrongly passes too, the final one, on the posted record, does. An approve
# chosen stays.
yes_open=$'**Ready to merge?** Yes\n\n```json findings\n[{"id":"F3","status":"open","severity":"critical","file":"c.js","line":9,"title":"data loss","in_delta":false,"later":false},{"id":"F1","status":"fixed","in_delta":false,"later":false}]\n```'
setup $'**Approach:** Sound' "$yes_open"
two_rounds
cat >"$stub/bin/jq" <<S
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == '.ready_overridden == true' ]] && exit 5; done
exec "$(command -v jq)" "\$@"
S
chmod +x "$stub/bin/jq"
run
expect "the ready_overridden lookup fails, 1 blocker open: comments, not approve" \
	'[[ $rc == 0 && $flag == --comment && $(jq -c "[.source, .counts.open_blocking, .decision]" <<<"$record") == "[\"model\",1,\"comment\"]" ]] &&
		grep -q "But 1 blocking findings are still open: posting as comment" "$stub/out.log"'
cat >"$stub/bin/jq" <<S
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == '.ready_overridden == true' ]] && exit 5; done
if [[ "\$*" == *'.counts.open_blocking == 0'* && "\${*: -1}" == *round.json ]]; then exit 0; fi
exec "$(command -v jq)" "\$@"
S
run
expect "only the pre-post check sees the 1 open blocker: event, marker and round.json all say comment" \
	'[[ $rc == 0 && $flag == --comment &&
		$(sed -n 2p <<<"$body" | sed "s/^<!-- gh-pr-review:round //; s/ -->$//" | jq -c "[.decision, .counts.open_blocking]") == "[\"comment\",1]" &&
		$(jq -c "[.decision, .preview]" <<<"$record") == "[\"comment\",false]" ]]'
rm "$stub/bin/jq"
run --decision approve
expect "1 open blocker, approve chosen: stays an approval" '[[ $rc == 0 && $flag == --approve ]]'

# ── the review is bound to the commit it read
setup $'**Approach:** Sound' "$clean"
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

# A loop warning and a head that moved: the review's head (here the progress lines, which replace the loop line) stays
# first, the note comes right after it.
setup $'**Approach:** Sound' "$clean"
rounds_with 9 12 8 >"$stub/rest-reviews.json"
printf 'head1\nhead2\n' >"$stub/heads"
run
expect "progress lines and moved head: the progress lines first, then the note" \
	'[[ $rc == 0 && $flag == --comment && $(sed -n 3p <<<"$body") == "### Round 4 · since round 3" &&
		$(sed -n 4p <<<"$body") == "open blocking: 0 (was 8)"* && -z $(sed -n 5p <<<"$body") &&
		$(sed -n 6p <<<"$body") == "**Note:** The PR moved to head2 during the review; this review covers head1." &&
		-z $(sed -n 7p <<<"$body") && $(sed -n 8p <<<"$body") == "**Approach:** Sound" ]]'

setup $'**Approach:** Sound' "$clean"
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
setup $'**Approach:** Sound' "$clean"
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

# ── producer to consumer, three code-review rounds: each round reads the last one back as GitHub returns it
H3=$(printf 'c3%.0s' {1..20})
post_back() { # <commit> <date>: the body just posted, as a submitted review in the REST reviews and the discussion
	jq -c --arg body "$body" --arg c "$1" --arg d "$2" '. + [{id: (length + 1), user: {login: "me", type: "User"},
		state: "COMMENTED", commit_id: $c, submitted_at: $d, body: $body}]' "$stub/rest-reviews.json" >"$stub/r.tmp" &&
		mv "$stub/r.tmp" "$stub/rest-reviews.json"
	jq -c --arg body "$body" --arg d "$2" '.reviews += [{author: {login: "me"}, state: "COMMENTED", submittedAt: $d,
		body: $body}]' "$stub/discussion.json" >"$stub/d.tmp" && mv "$stub/d.tmp" "$stub/discussion.json"
}
r1=$'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **`c.js:9` — data loss.**\n'
r1+=$'#### ⚠️ Important (Should Fix)\n- **`a.js:3` — thing breaks.**\n\n**Ready to merge?** No\n\n'
r1+=$'```json findings\n[{"severity":"important","file":"a.js","line":3,"title":"thing breaks"},'
r1+=$'{"severity":"critical","file":"c.js","line":9,"title":"data loss"}]\n```'
setup $'**Approach:** Sound' "$r1"
echo "$H1" >"$stub/heads"
echo "$B1" >"$stub/git.base"
run
expect "three rounds: round 1 posted" '[[ $rc == 0 && $(jq -r "[.findings[] | .id + \":\" + .file] | join(\" \")" <<<"$record") == "F1:a.js F2:c.js" ]]'
post_back "$H1" 2026-06-01T10:00:00Z
# Round 2 leaves F1 out of both the block and the Markdown: carried, not re-checked, and its file and title appear
# nowhere in the body, so the marker drops them. F2's title is not shown word for word either.
r2=$'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **F2 · `c.js:9`** — still loses data.\n'
r2+=$'#### ⚠️ Important (Should Fix)\n*(none found)*\n#### 💡 Minor (Nice to Have)\n- **`d.js:4`** — typo in a comment.\n\n'
r2+=$'**Ready to merge?** No\n\n```json findings\n[{"id":"F2","status":"open","severity":"critical","file":"c.js","line":9,'
r2+=$'"title":"data loss","in_delta":false,"later":false},{"id":null,"status":"new","severity":"minor","file":"d.js",'
r2+=$'"line":4,"title":"typo in a comment","in_delta":true,"later":false}]\n```'
printf '%s' "$r2" >"$stub/review.out"
echo "$H2" >"$stub/heads"
run
expect "three rounds: round 2 incremental from round 1's head" \
	'[[ $rc == 0 && $(jq -r ".round, .mode, .previous_head_sha" <<<"$record" | paste -sd, -) == "2,incremental,$H1" ]] && grep -qF "git diff --stat $H1..$H2" "$stub/code-prompt.txt"'
expect "three rounds: round 2 carries F1, and its marker drops what the body does not show" \
	'[[ $(jq -r "[.findings[] | .id + \":\" + .status + (if .unverified then \"?\" else \"\" end)] | join(\" \")" <<<"$record") == "F2:open F3:new F1:open?" ]] &&
		[[ $(sed -n 2p <<<"$body" | sed "s/^<!-- gh-pr-review:round //; s/ -->$//" | jq -c "[.findings[] | select(.id != \"F3\") | [.id, .file, .title]]") == "[[\"F2\",\"c.js\",null],[\"F1\",null,null]]" ]]'
post_back "$H2" 2026-06-02T10:00:00Z
# An outsider's generated review between rounds 1 and 2: no round, so it must not shift round 2 out of place as the
# previous review.
outsider=$'<!-- gh-pr-review generated -->\n### Issues\n- outsider text'
jq -c --arg body "$outsider" '. + [{id: (length + 1), user: {login: "eve", type: "User"}, author_association: "NONE",
	state: "COMMENTED", commit_id: "'"$H1"'", submitted_at: "2026-06-01T12:00:00Z", body: $body}]' \
	"$stub/rest-reviews.json" >"$stub/r.tmp" && mv "$stub/r.tmp" "$stub/rest-reviews.json"
jq -c --arg body "$outsider" '.reviews += [{author: {login: "eve"}, authorAssociation: "NONE", state: "COMMENTED",
	submittedAt: "2026-06-01T12:00:00Z", body: $body}]' "$stub/discussion.json" >"$stub/d.tmp" &&
	mv "$stub/d.tmp" "$stub/discussion.json"
printf '%s' $'**Ready to merge?** No\n\n```json findings\n[]\n```' >"$stub/review.out"
echo "$H3" >"$stub/heads"
run
expect "three rounds: an outsider's generated review is not the previous review" \
	'[[ $(session_file previous-review.md) == *"still loses data"* && $(session_file previous-review.md) != *"outsider text"* ]]'
expect "three rounds: round 3 compares with round 2's head" \
	'[[ $rc == 0 && $(jq -r ".round, .mode, .previous_head_sha" <<<"$record" | paste -sd, -) == "3,incremental,$H2" ]] &&
		grep -qF "git diff --stat $H2..$H3" "$stub/code-prompt.txt" && grep -qF "git diff $H2..$H3" "$stub/code-prompt.txt"'
expect "three rounds: every carried finding is identifiable, details recovered from round 1" \
	'[[ $(session_file previous-findings.md) == "F2 · critical · c.js:9 · data loss"$'"'"'\n'"'"'"F3 · minor · d.js:4 · typo in a comment"$'"'"'\n'"'"'"F1 · important · a.js:3 · thing breaks" ]]'
expect "three rounds: both blockers still count" '[[ $(jq -r ".counts.open_blocking, .counts.unverified" <<<"$record" | paste -sd, -) == "2,3" ]]'

# ── producer to reader, a later round: round 2 with fixed, declined, carried, new and Later findings, posted with the
# boundary line, read back by rounds with its full marker and with the minimal ones
read_rounds() { # [--json]: rounds over the stub's REST reviews -> $stub/rounds.out
	(cd "$stub/work" && HOME="$stub/home" PATH="$stub/bin:$PATH" GH_PR_REVIEW_USER='' \
		bash "$root/gh-pr-review" rounds https://github.com/o/r/pull/1 "$@" >"$stub/rounds.out" 2>"$stub/out.log") &&
		rc=0 || rc=$?
}
p1=$'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n- **`a.js:1` — one.**\n#### ⚠️ Important (Should Fix)\n'
p1+=$'- **`b.js:2` — two.**\n- **`c.js:3` — three.**\n#### 💡 Minor (Nice to Have)\n- **`m.js:4` — four.**\n\n'
p1+=$'**Ready to merge?** No\n\n```json findings\n[{"severity":"critical","file":"a.js","line":1,"title":"one"},'
p1+=$'{"severity":"important","file":"b.js","line":2,"title":"two"},{"severity":"important","file":"c.js","line":3,'
p1+=$'"title":"three"},{"severity":"minor","file":"m.js","line":4,"title":"four"}]\n```'
setup $'**Approach:** Sound' "$p1"
echo "$H1" >"$stub/heads"
echo "$B1" >"$stub/git.base"
run
expect "later round read back: round 1 posted, F1–F4" \
	'[[ $rc == 0 && $(jq -c "[.last_ids.F, .counts.open_blocking]" <<<"$record") == "[4,3]" ]]'
post_back "$H1" 2026-07-01T10:00:00Z
# Round 2: F1 fixed, F2 declined with a quote, F3 left out (carried, not re-checked), F4 still open, a new Important
# in d.js (the delta), and an Important outside it filed under Later.
p2=$'### Issues\n#### 🚨 Critical (Must Fix Before Merge)\n*(none found)*\n#### ⚠️ Important (Should Fix)\n'
p2+=$'- **`d.js:5` — new bug.**\n#### 💡 Minor (Nice to Have)\n- **F4 · `m.js:4`** — still four.\n\n'
p2+=$'<details><summary>Fixed since the last round (2)</summary>\n\n- **F1** — fixed.\n'
p2+=$'- **F2** — declined: "by design" (@bob)\n\n</details>\n\n<details><summary>Later (1)</summary>\n\n'
p2+=$'- **`z.js:9`** — can wait.\n\n</details>\n\n**Ready to merge?** No\n\n```json findings\n'
p2+=$'[{"id":"F1","status":"fixed","in_delta":false,"later":false},'
p2+=$'{"id":"F2","status":"declined","reason":"\\"by design\\" (@bob)","in_delta":false,"later":false},'
p2+=$'{"id":"F4","status":"open","severity":"minor","file":"m.js","line":4,"title":"four","in_delta":false,"later":false},'
p2+=$'{"id":null,"status":"new","severity":"important","file":"d.js","line":5,"title":"new bug","in_delta":true,"later":false},'
p2+=$'{"id":null,"status":"new","severity":"important","file":"z.js","line":9,"title":"can wait","in_delta":false,"later":true}]\n```'
printf '%s' "$p2" >"$stub/review.out"
echo "$H2" >"$stub/heads"
run
expect "later round read back: round 2 written from the block, every status" \
	'[[ $rc == 0 && $(jq -c "[.source, ([.findings[] | .id + \":\" + .status + (if .unverified then \"?\" else \"\" end)] | join(\" \")), (.later | map(.id)), .last_ids, (.counts | [.open_blocking, .critical, .important, .minor, .fixed, .declined])]" <<<"$record") == "[\"model\",\"F1:fixed F2:declined F4:open F5:new F3:open?\",[\"L1\"],{\"F\":5,\"L\":1},[2,0,2,1,1,1]]" ]]'
expect "later round read back: the progress lines, then the approach, then the boundary before the code review" \
	'[[ $(sed -n 3p <<<"$body") == "### Round 2 · since round 1" && $(sed -n 4p <<<"$body") == *"open blocking: 2 (was 3)"* &&
		$(sed -n 6p <<<"$body") == "**Approach:** Sound" && $(sed -n 8p <<<"$body") == "<!-- gh-pr-review:code-review -->" &&
		$(sed -n 9p <<<"$body") == "### Issues" ]]'
post_back "$H2" 2026-07-02T10:00:00Z
full_body="$body"
read_rounds --json
full_rounds=$(cat "$stub/rounds.out")
r2_view() { jq -c '[.records[1] | .source, .counts.open_blocking, .counts.critical, .last_ids.F, .last_ids.L] + [.decision.labels[1], .decision.label]' "$stub/rounds.out"; }
expect "later round read back, full marker: as written, 2 blockers, last_ids F5 and L1" \
	'[[ $rc == 0 && $(r2_view) == "[\"model\",2,0,5,1,\"early\",\"early\"]" ]]'
read_rounds
full_table=$(grep '^2 ' "$stub/rounds.out")
# The same posted body with the minimal marker in place of the full one, with last_ids and without: read from the
# Markdown after the boundary, with the progress line's 2 blockers (the carried F3 is not in the Markdown), and the
# same label. With last_ids the floor is the writer's, F5 and L1; without, every finding the Markdown shows takes a
# new ID after round 1's F4 (F5, F6: never below the writer's), and the Later item reserves L1.
for m in '{"schema":1,"round":2,"findings_dropped":true,"last_ids":{"F":5,"L":1}}~5,1' \
	'{"schema":1,"round":2,"findings_dropped":true}~6,1'; do
	min_body=$(sed "2s/.*/<!-- gh-pr-review:round ${m%%~*} -->/" <<<"$full_body")
	jq -c --arg b "$min_body" '.[1].body = $b' "$stub/rest-reviews.json" >"$stub/r.tmp" && mv "$stub/r.tmp" "$stub/rest-reviews.json"
	read_rounds --json
	expect "later round read back, minimal marker ${m%%~*}: 2 blockers, the same label, last_ids F,L ${m##*~}" \
		'[[ $rc == 0 && $(r2_view) == "[\"backfill\",2,0,${m##*~},\"early\",\"early\"]" &&
			$(jq -c ".records[1] | [.findings_dropped, has(\"findings\")]" "$stub/rounds.out") == "[true,false]" &&
			$(jq -c "[.records[] | .counts.open_blocking]" "$stub/rounds.out") == "$(jq -c "[.records[] | .counts.open_blocking]" <<<"$full_rounds")" ]]'
	read_rounds
	expect "later round read back, minimal marker ${m%%~*}: the table row differs only in IMP and the source" \
		'[[ $rc == 0 && $(grep "^2 " "$stub/rounds.out" | sed "s/  */ /g") == "$(sed "s/  */ /g; s/ 2 1 early model/ 1 1 early backfill/" <<<"$full_table")" ]]'
done

# Rounds 1–2 leave two blockers open (F1, F3). Round 3's record can't be built: it posts as comment, its Markdown
# shows neither blocker, and its minimal marker says it is a later round with an unknown count and no findings list.
# Read back that way, round 4 does not build on it as an empty baseline: it is a full review of the whole PR, as a
# first code review (no previous-round rules, no previous-findings.md), and round 3 counts as unknown, not as 0
# blockers. A full review re-reads the whole PR, so its clean verdict stands: it approves.
setup $'**Approach:** Sound' "$clean"
two_rounds
echo "$H3" >"$stub/heads"
echo "$B1" >"$stub/git.base"
break_record fail
run
expect "record fails in round 3: posted as comment, with a minimal marker of unknown count" \
	'[[ $rc == 0 && $flag == --comment && -z $record &&
		$(sed -n 2p <<<"$body" | sed "s/^<!-- gh-pr-review:round //; s/ -->$//" | jq -c .) == "{\"schema\":1,\"round\":3,\"findings_dropped\":true,\"last_ids\":{\"F\":3,\"L\":0},\"counts\":{\"open_blocking\":null,\"critical\":null,\"important\":null,\"minor\":null}}" ]]'
rm "$stub/bin/jq"
post_back "$H3" 2026-01-03T00:00:00Z
read_rounds --json
expect "record fails in round 3: read back with unknown counts and no findings list" \
	'[[ $rc == 0 && $(jq -c ".records[2] | [.round, .counts.open_blocking, .counts.critical, .findings_dropped, has(\"findings\"), .last_ids.F]" "$stub/rounds.out") == "[3,null,null,true,false,3]" &&
		$(jq -c ".decision.series" "$stub/rounds.out") == "[1,2,null]" ]]'
H4=$(printf 'c4%.0s' {1..20})
echo "$H4" >"$stub/heads"
run
expect "record failed in round 3: round 4 is a full review, not an increment on an empty baseline" \
	'[[ $rc == 0 && $(jq -r ".round, .mode, .mode_reason" <<<"$record" | paste -sd, -) == "4,full,the last round has no record of its findings" ]] &&
		grep -q "mode: full (the last round has no record of its findings)" "$stub/out.log"'
expect "record failed in round 3: round 4 has no previous-round rules and no previous-findings.md" \
	'! grep -q -e "## Previous round" -e "Check every earlier finding" -e "Outside what changed" "$stub/code-prompt.txt" &&
		[[ -z $(session_file previous-findings.md) ]]'
expect "record failed in round 3: round 4, a clean full review, approves" \
	'[[ $flag == --approve && $(jq -c "[.counts.open_blocking, .decision]" <<<"$record") == "[0,\"approve\"]" ]]'

finished=true
exit "$fail"
