#!/usr/bin/env bash
# Checks lib/records.sh: the findings block, the findings parser, the record builder, the marker and backfill.
# shellcheck disable=SC2016 # backticks in single quotes are Markdown, not command substitution
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
LIB_DIR="$root/lib"
# shellcheck source=lib/verdicts.sh
source "$root/lib/verdicts.sh"
# shellcheck source=lib/records.sh
source "$root/lib/records.sh"
fixtures="$root/tests/fixtures/reviews"
tmp=$(mktemp -d)
# The script must reach its end: Bash 3.2 can stop on an error inside an EXIT trap with status 0.
finished=false
trap 'rm -rf "$tmp"; [[ $finished == true ]] || { echo "FAIL stopped before the end"; exit 1; }' EXIT
fail=0

check() { # name got want
	if [[ "$2" == "$3" ]]; then echo "ok   $1"; else
		echo "FAIL $1: got '$2', want '$3'"
		fail=1
	fi
}

# ── parse_findings ──────────────────────────────────────────────────────────
counts() { jq -r '[map(select(.severity == "critical")), map(select(.severity == "important")),
	map(select(.severity == "minor"))] | map(length) | join(" ")' <<<"$1"; }
item() { jq -r ".[$2] | [.severity, .file, (.line | tostring), .title] | join(\" | \")" <<<"$1"; }

f=$(parse_findings "$fixtures/bullets.md")
check "bullets: counts per severity" "$(counts "$f")" "1 3 2"
check "bullets: range item" "$(item "$f" 0)" \
	"critical | tools/importer/republish.md | 106 | Unattended mode can publish pages the owner never selected."
check "bullets: hyphen range" "$(item "$f" 2)" \
	"important | tools/importer/republish.js | 201 | Errors from the second pass are swallowed."
check "bullets: file without line" "$(item "$f" 3)" "important | README.md | null | The new flag is not documented."

f=$(parse_findings "$fixtures/numbered.md")
check "numbered: counts per severity" "$(counts "$f")" "2 2 0"
check "numbered: item" "$(item "$f" 0)" \
	"critical | service/src/attempts.ts | 21 | A late report can reopen a closed attempt."

f=$(parse_findings "$fixtures/rethink-only.md")
check "rethink-only: no findings" "$f" "[]"

f=$(parse_findings "$fixtures/pre-approach.md")
check "pre-approach: counts per severity" "$(counts "$f")" "1 2 1"
check "pre-approach: bracket location, no dash" "$(item "$f" 0)" \
	"critical | src/api.ts | 141 | Webhook payload is trusted without checking the signature header."
check "pre-approach: bracket location, dash after bold" "$(item "$f" 1)" \
	"important | src/queue.ts | 33 | Failed jobs are retried forever."

f=$(parse_findings "$fixtures/dashes.md")
check "dashes: counts per severity" "$(counts "$f")" "1 2 1"
check "dashes: title with --extend" "$(item "$f" 0)" \
	'critical | bin/crawl.mjs | 40 | `--extend` re-runs the whole crawl and drops `--dry-run`.'

long=$(printf 'x%.0s' {1..150})
printf '#### 🚨 Critical\n\n- **`a.ts:1` — %s**\n' "$long" >"$tmp/long.md"
check "title cut to 100 characters" "$(parse_findings "$tmp/long.md" | jq '.[0].title | length')" 100

# ── cut_findings_block ──────────────────────────────────────────────────────
block() { printf '```json findings\n[{"severity":"%s","file":"a.ts","line":1,"title":"t"}]\n```\n' "$1"; }
cut() { # review-text -> sets body and found
	printf '%s' "$1" >"$tmp/review.md"
	cut_findings_block "$tmp/review.md" "$tmp/body.md" "$tmp/findings.json"
	body=$(cat "$tmp/body.md")
	found=$(cat "$tmp/findings.json")
}

cut $'### Issues\n\nNone.\n'
check "no block: whole review" "$body" $'### Issues\n\nNone.'
check "no block: empty findings" "$found" ""

cut "$(printf '### Assessment\n\n**Ready to merge?** Yes\n\n%s' "$(block minor)")"
check "block at end: body" "$body" $'### Assessment\n\n**Ready to merge?** Yes'
check "block at end: findings" "$(jq -r '.[0].severity' <<<"$found")" minor

cut "$(printf '### Issues\n\nText.\n\n%s\n\n### Assessment\n\n**Ready to merge?** No\n' "$(block critical)")"
check "block in the middle: body" "$body" $'### Issues\n\nText.\n\n### Assessment\n\n**Ready to merge?** No'
check "block in the middle: findings" "$(jq -r '.[0].severity' <<<"$found")" critical

cut "$(printf 'Text.\n\n%s\n\nMore.\n\n%s\n' "$(block critical)" "$(block important)")"
check "two blocks: the last wins" "$(jq -r '.[0].severity' <<<"$found")" important
check "two blocks: the first stays in the body" "$(grep -c 'json findings' "$tmp/body.md")" 1

cut "$(printf 'Text.\n\n```json\n[]\n```\n')"
check "plain json block: left in the body" "$body" $'Text.\n\n```json\n[]\n```'
check "plain json block: no findings" "$found" ""

cut "$(printf 'Text.\n\n```json findings\n[]\n')"
check "open block: cut to the end" "$body" "Text."
check "open block: findings" "$found" "[]"

# ── build_record ────────────────────────────────────────────────────────────
meta='{"source":"model","pr":{"host":"github.com","owner":"o","repo":"r","number":7},"round":2,"mode":"full",
	"reviewer":"me","model":"m","head_sha":"bbb","approach":"sound","ready":"yes-with-fixes","code_review":true}'
prev=$(jq -n '{head_sha: "aaa", findings: [range(1; 8) | {id: "F\(.)"}]}')
rec=$(build_record "$meta" "$(parse_findings "$fixtures/bullets.md")" "$prev")
rec_bullets=$rec
check "ids continue after F7" "$(jq -r '[.findings[].id] | join(" ")' <<<"$rec")" "F8 F9 F10 F11 F12 F13"
check "open_blocking" "$(jq '.counts.open_blocking' <<<"$rec")" 4
check "counts" "$(jq -c '.counts' <<<"$rec")" \
	'{"open_blocking":4,"critical":1,"important":3,"minor":2,"new":6,"fixed":0,"declined":0,"regressed":0,"later":0,"unverified":0}'
check "round 1: no unverified key" "$(jq '[.findings[] | has("unverified")] | any' <<<"$rec")" false
check "round 1: last ids" "$(jq -c '.last_ids' <<<"$rec")" '{"F":13,"L":0}'
check "round 1: ready kept, not overridden" "$(jq -c '[.ready, .ready_overridden]' <<<"$rec")" '["yes-with-fixes",true]'
check "mode kept, no reason" "$(jq -c '[.mode, .mode_reason]' <<<"$rec")" '["full",null]'
check "finding fields" "$(jq -c '.findings[0] | [.status, .first_round, .in_delta]' <<<"$rec")" '["new",2,false]'
check "schema, later, preview" "$(jq -c '[.schema, .later, .preview]' <<<"$rec")" '[1,[],false]'
check "missing meta keys are null" "$(jq -c '[.base_sha, .posted_at, .decision]' <<<"$rec")" '[null,null,null]'
check "previous head from the previous record" "$(jq -r '.previous_head_sha' <<<"$rec")" aaa
check "first record starts at F1" "$(build_record "$meta" '[{"severity":"Minor","title":"t"}]' null |
	jq -r '.findings[0] | [.id, .severity] | join(" ")')" "F1 minor"
check "unknown severities dropped" "$(build_record "$meta" '[{"severity":"nit","title":"t"}]' null |
	jq '.findings | length')" 0

rethink=$(build_record "$(jq -c '.code_review = false | .approach = "rethink"' <<<"$meta")" \
	'[{"severity":"critical","title":"t"}]' null)
check "rethink: no findings" "$(jq -c '.findings' <<<"$rethink")" "[]"
check "rethink: null counts" "$(jq -c '[.counts[]] | unique' <<<"$rethink")" "[null]"
check "rethink: count keys" "$(jq -c '.counts | keys' <<<"$rethink")" \
	'["critical","declined","fixed","important","later","minor","new","open_blocking","regressed","unverified"]'
check "rethink: not overridden, no later" "$(jq -c '[.ready_overridden, .later]' <<<"$rethink")" '[false,[]]'

# ── build_record with statuses (round 2 and later) ──────────────────────────
# Round 2: F1 open, F2 fixed, F3 declined, F4 new, F5 regressed, L6 later. F and L number apart, each from its
# highest.
meta2=$(jq -c '.round = 3 | .mode = "incremental" | .mode_reason = null | .ready = "no" | .delta_files = ["t.ts"]' <<<"$meta")
prev2=$(jq -nc '{round: 2, head_sha: "aaa", counts: {open_blocking: 3}, findings: [
	{id: "F1", severity: "critical", status: "open", first_round: 1, in_delta: false, file: "a.ts", line: 1, title: "one"},
	{id: "F2", severity: "important", status: "fixed", first_round: 1, in_delta: false, file: "b.ts", line: 2, title: "two"},
	{id: "F3", severity: "important", status: "declined", first_round: 1, in_delta: false, file: "c.ts", line: 3, title: "three"},
	{id: "F4", severity: "minor", status: "new", first_round: 2, in_delta: true, file: "d.ts", line: 4, title: "four"},
	{id: "F5", severity: "important", status: "regressed", first_round: 1, in_delta: false, file: "e.ts", line: 5,
		title: "five"}],
	later: [{id: "L6", severity: "minor", file: "f.ts", line: 6, title: "six"}]}')
r3() { build_record "$meta2" "$1" "$prev2"; }
one() { jq -c --arg id "$2" '(.findings + .later)[] | select(.id == $id)
	| [.status, .first_round, .severity, .file, .line, .title, (.unverified // false)]' <<<"$1"; }

rec=$(r3 '[{"id":"F1","status":"fixed"}]')
check "known id keeps its status" "$(one "$rec" F1)" '["fixed",1,"critical","a.ts",1,"one",false]'
rec=$(r3 '[{"id":"F1","status":"open","severity":"minor","file":"z.ts","line":9,"title":"new title"}]')
check "known id: model fields win" "$(one "$rec" F1)" '["open",1,"minor","z.ts",9,"new title",false]'
rec=$(r3 '[{"id":"F2","status":"open"}]')
check "fixed then open: regressed" "$(one "$rec" F2)" '["regressed",1,"important","b.ts",2,"two",false]'
check "regressed counts as blocking" "$(jq -c '.counts | [.regressed, .open_blocking]' <<<"$rec")" '[1,3]'
rec=$(r3 '[{"id":"F5","status":"open"}]')
check "regressed then open: open" "$(one "$rec" F5)" '["open",1,"important","e.ts",5,"five",false]'
rec=$(r3 '[{"severity":"minor","title":"n1"},{"severity":"important","file":"l.ts","title":"l1","later":true},
	{"severity":"critical","title":"n2","in_delta":true}]')
check "new ids continue after F5 and L6" "$(jq -c '[.findings[] | select(.status == "new") | .id], [.later[].id]' \
	<<<"$rec" | tr -d '\n')" '["F6","F7"]["L7"]'
check "new finding fields" "$(jq -c '.findings[] | select(.id == "F7") | [.status, .first_round, .in_delta]' \
	<<<"$rec")" '["new",3,true]'
check "later item fields" "$(jq -c '.later[0]' <<<"$rec")" \
	'{"id":"L7","severity":"important","file":"l.ts","line":null,"title":"l1"}'
check "last ids" "$(jq -c '.last_ids' <<<"$rec")" '{"F":7,"L":7}'
check "later items not blocking" "$(jq -c '.counts | [.later, .important]' <<<"$rec")" '[1,1]'
check "previous later not carried" "$(jq -c '[.later[].id] | index("L6")' <<<"$rec")" null
rec=$(r3 '[]')
check "missing ids carried as unverified open" \
	"$(jq -c '[.findings[] | [.id, .status, .unverified]]' <<<"$rec")" \
	'[["F1","open",true],["F4","open",true],["F5","open",true]]'
check "carried keep first round" "$(one "$rec" F4)" '["open",2,"minor","d.ts",4,"four",true]'
check "fixed and declined not carried" "$(jq -c '[.findings[].id | select(. == "F2" or . == "F3")]' <<<"$rec")" "[]"
check "carried: counts" "$(jq -c '.counts' <<<"$rec")" \
	'{"open_blocking":2,"critical":1,"important":1,"minor":1,"new":0,"fixed":0,"declined":0,"regressed":0,"later":0,"unverified":3}'
check "numbering survives an empty round" "$(build_record "$meta2" '[{"severity":"minor","title":"x"}]' "$rec" |
	jq -r '.findings[] | select(.status == "new") | .id')" F6
rec=$(r3 '[{"id":"F1","status":"fixed"},{"id":"F1","status":"open"}]')
check "duplicate keeps the first" "$(jq -c '[.findings[] | select(.id == "F1") | .status]' <<<"$rec")" '["fixed"]'
rec=$(r3 '[{"id":"F99","status":"open","severity":"important","title":"ghost"}]')
check "unknown id becomes new" "$(jq -c '.findings[0] | [.id, .status, .first_round, .title]' <<<"$rec")" \
	'["F6","new",3,"ghost"]'
rec=$(r3 '[{"id":"F1","status":"maybe"}]')
check "bad status: open, unverified" "$(one "$rec" F1)" '["open",1,"critical","a.ts",1,"one",true]'
check "bad status: not carried twice" "$(jq '[.findings[] | select(.id == "F1")] | length' <<<"$rec")" 1
check "in_delta kept as a boolean" "$(r3 '[{"severity":"minor","title":"t","in_delta":"yes"}]' |
	jq -c '.findings[0].in_delta')" false

rec=$(build_record "$(jq -c '.ready = "yes"' <<<"$meta2")" '[{"id":"F1","status":"open"}]' "$prev2")
check "ready yes with open blocking: overridden" "$(jq -c '[.ready, .ready_overridden]' <<<"$rec")" '["yes",true]'
rec=$(build_record "$(jq -c '.ready = "yes"' <<<"$meta2")" \
	'[{"id":"F1","status":"fixed"},{"id":"F4","status":"open"},{"id":"F5","status":"declined","reason":"out of scope"}]' "$prev2")
check "ready yes, nothing blocking: not overridden" "$(jq -c '[.ready_overridden, .counts.open_blocking]' \
	<<<"$rec")" '[false,0]'
check "ready no: not overridden" "$(r3 '[]' | jq .ready_overridden)" false
rec=$(build_record "$(jq -c '.mode = "full" | .mode_reason = "the previous head is gone"' <<<"$meta2")" '[]' "$prev2")
check "mode and mode_reason kept" "$(jq -c '[.mode, .mode_reason]' <<<"$rec")" '["full","the previous head is gone"]'
rec=$(build_record "$(jq -c '.code_review = false | .approach = "rethink"' <<<"$meta2")" \
	'[{"id":"F1","status":"fixed"}]' "$prev2")
check "rethink after round 2: no findings, null counts" "$(jq -c '[.findings, .later, ([.counts[]] | unique)]' \
	<<<"$rec")" '[[],[],[null]]'

# Model output that would drop a blocker: a decline needs a reason, Later needs an eligible finding.
rec=$(r3 '[{"id":"F1","status":"declined"},{"id":"F5","status":"declined","reason":"  "}]')
check "declined without a reason: open, unverified" "$(one "$rec" F1),$(one "$rec" F5)" \
	'["open",1,"critical","a.ts",1,"one",true],["open",1,"important","e.ts",5,"five",true]'
check "declined without a reason: still blocking" "$(jq -c '.counts | [.open_blocking, .declined]' <<<"$rec")" '[2,0]'
rec=$(r3 '[{"id":"F1","status":"declined","severity":"minor"}]')
check "declined without a reason: no severity downgrade" "$(one "$rec" F1)" '["open",1,"critical","a.ts",1,"one",true]'
check "declined without a reason: the Critical still blocks" \
	"$(jq -c '[.counts.open_blocking, .counts.critical, .counts.minor]' <<<"$rec")" '[2,1,1]'
rec=$(r3 '[{"id":"F1","status":"declined","reason":"\"not in this PR\" (alice)"}]')
check "declined with a reason: declined" "$(one "$rec" F1)" '["declined",1,"critical","a.ts",1,"one",false]'
later_of() { # <meta> <entry> -> where it went: later or the findings, with its status
	build_record "$1" "[$2]" "$prev2" | jq -r 'if (.later | length) > 0 then "later"
		else .findings[] | select(.status == "new") | "finding:" + .severity end'
}
check "later: an Important outside the delta, incremental" \
	"$(later_of "$meta2" '{"severity":"important","file":"x.ts","title":"x","later":true}')" later
check "later: a Minor outside the delta, rebased" \
	"$(later_of "$(jq -c '.mode = "rebased"' <<<"$meta2")" '{"severity":"minor","file":"x.ts","title":"x","later":true}')" later
check "later: a Critical stays a finding" \
	"$(later_of "$meta2" '{"severity":"critical","title":"x","later":true}')" finding:critical
check "later: one in the delta stays a finding" \
	"$(later_of "$meta2" '{"severity":"important","file":"x.ts","title":"x","later":true,"in_delta":true}')" finding:important
check "later: a full round has no Later" \
	"$(later_of "$(jq -c '.mode = "full"' <<<"$meta2")" '{"severity":"important","file":"x.ts","title":"x","later":true}')" \
	finding:important
check "later: no mode, no Later" \
	"$(later_of "$(jq -c 'del(.mode)' <<<"$meta2")" '{"severity":"minor","file":"x.ts","title":"x","later":true}')" finding:minor
# The delta's file list decides, not in_delta: a touched file, a missing file or an unknown list keeps the finding.
check "later: one in a file the delta touched stays a finding" \
	"$(later_of "$meta2" '{"severity":"important","file":"t.ts","title":"x","later":true,"in_delta":false}')" finding:important
check "later: a ./ path in a touched file stays a finding" \
	"$(later_of "$meta2" '{"severity":"minor","file":"./t.ts","title":"x","later":true}')" finding:minor
check "later: one without a file stays a finding" \
	"$(later_of "$meta2" '{"severity":"important","title":"x","later":true}')" finding:important
check "later: no file list, no Later" \
	"$(later_of "$(jq -c 'del(.delta_files)' <<<"$meta2")" '{"severity":"minor","file":"x.ts","title":"x","later":true}')" \
	finding:minor
rec=$(build_record "$(jq -c '.mode = "full" | .ready = "yes"' <<<"$meta2")" \
	'[{"id":"F1","status":"fixed"},{"id":"F4","status":"fixed"},{"id":"F5","status":"fixed"},
	{"severity":"critical","title":"x","later":true}]' "$prev2")
check "later: a Critical marked later in a full round blocks the approval" \
	"$(jq -c '[.counts.open_blocking, .ready_overridden, (.later | length)]' <<<"$rec")" '[1,true,0]'

# A full round 3 on the round 2 record: every status moves.
reply='[
	{"id":"F2","status":"open","in_delta":true},
	{"id":"F5","status":"fixed"},
	{"id":"F4","status":"declined","title":"four, declined","reason":"\"Kept on purpose\" (bob)"},
	{"id":"F2","status":"fixed"},
	{"id":"F3","status":"open"},
	{"id":"F77","status":"fixed","severity":"minor","file":"g.ts","line":7,"title":"unknown"},
	{"severity":"critical","file":"h.ts","line":8,"title":"in delta","in_delta":true},
	{"severity":"important","file":"i.ts","line":9,"title":"later one","later":true},
	{"severity":"nit","title":"dropped"}
]'
rec=$(r3 "$reply")
check "round 3: findings" "$(jq -c '[.findings[] | [.id, .status, .first_round, (.unverified // false)]]' <<<"$rec")" \
	'[["F2","regressed",1,false],["F5","fixed",1,false],["F4","declined",2,false],["F3","open",1,false],["F6","new",3,false],["F7","new",3,false],["F1","open",1,true]]'
check "round 3: later" "$(jq -c '[.later[] | [.id, .title]]' <<<"$rec")" '[["L7","later one"]]'
check "round 3: counts" "$(jq -c '.counts' <<<"$rec")" \
	'{"open_blocking":4,"critical":2,"important":2,"minor":1,"new":2,"fixed":1,"declined":1,"regressed":1,"later":1,"unverified":1}'
check "round 3: kept the round 2 head" "$(jq -r .previous_head_sha <<<"$rec")" aaa

# A marker cut to fit the size cap: counts and last_ids kept, findings list gone. Nothing to carry, no ID to know.
capped2=$(jq -c '.last_ids = {F: 5, L: 6}' <<<"$prev2")
for capped in "$(jq -c 'del(.findings) | .findings_dropped = true' <<<"$capped2")" \
	"$(jq -c 'del(.findings)' <<<"$capped2")" "$(jq -c '.findings_dropped = true' <<<"$capped2")"; do
	what=$(jq -r 'if has("findings") then "findings_dropped with a list" elif .findings_dropped then "findings_dropped"
		else "no findings key" end' <<<"$capped")
	rec=$(build_record "$meta2" '[]' "$capped")
	check "capped previous ($what): nothing carried" "$(jq -c '[.findings, .counts.open_blocking, .counts.unverified]' \
		<<<"$rec")" '[[],0,0]'
	check "capped previous ($what): no 'was' in the progress line" \
		"$(progress_line "$rec" "$capped" '{"label":null}' | tail -n 1)" "open blocking: 0"
	rec=$(build_record "$meta2" '[{"id":"F1","status":"fixed"},{"id":"F2","status":"open","severity":"important","title":"t"}]' \
		"$capped")
	check "capped previous ($what): an ID it cannot know is new" "$(jq -c '[.findings[] | [.id, .status]]' <<<"$rec")" \
		'[["F6","new"]]'
done
empty=$(jq -c '.findings = [] | .counts.open_blocking = 0' <<<"$prev2")
rec=$(build_record "$meta2" '[]' "$empty")
check "empty previous list: a known zero, kept in the progress line" \
	"$(progress_line "$rec" "$empty" '{"label":null}' | tail -n 1)" "open blocking: 0 (was 0)"

# The Markdown fallback on a later-round body (no findings block): IDs kept, folded sections not open findings.
f=$(parse_findings "$fixtures/later-round.md")
check "later round: open items keep their ID, both bullet forms" \
	"$(jq -c '[.[] | select(.status == "open") | [.id, .severity, .file, .line]]' <<<"$f")" \
	'[["F1","critical","a.ts",1],["F5","important","e.ts",5],["F2","important","b.ts",2]]'
check "later round: the ID is not in the title" "$(item "$f" 0)" \
	"critical | a.ts | 1 | Still trusts the payload when the header is empty."
check "later round: a new item has no ID" "$(jq -c '[.[] | select(.id == null) | [.severity, .file, .title]]' <<<"$f")" \
	'[["important","d.ts","The new retry loop has no upper bound."]]'
check "later round: Fixed gives fixed and declined, with the quoted reason" \
	"$(jq -c '[.[] | select(.status == "fixed" or .status == "declined") | [.id, .status, .reason, .severity]]' <<<"$f")" \
	'[["F4","fixed",null,null],["F3","declined","\"Kept on purpose until the v2 API ships\" (@bob)",null]]'
check "later round: the Later item and the Strengths are left out" "$(jq -c '[.[] | .file] | index("f.ts"), index("src/api.ts")' \
	<<<"$f" | paste -sd, -)" "null,null"
rec=$(r3 "$f")
check "later round fallback: every ID once, nothing carried twice" \
	"$(jq -c '[.findings[] | [.id, .status, (.unverified // false)]]' <<<"$rec")" \
	'[["F1","open",false],["F5","open",false],["F2","regressed",false],["F6","new",false],["F4","fixed",false],["F3","declined",false]]'
check "later round fallback: counts" "$(jq -c '.counts | [.open_blocking, .unverified, .later, .minor]' <<<"$rec")" \
	'[4,0,0,0]'
printf '#### ⚠️ Important\n\n- **F1 · `a.ts:1`** — open.\n\n<details><summary>Fixed (1)</summary>\n\n- **F4** — declined:\n- **F5** — declined: \n\n#### 💡 Minor\n\n- **[m.ts:1]** — after an unclosed details.\n' \
	>"$tmp/unclosed.md"
f=$(parse_findings "$tmp/unclosed.md")
check "later round: a decline without a reason has none" "$(jq -c '[.[] | select(.status == "declined") | .reason]' <<<"$f")" \
	'[null,null]'
check "later round: a heading ends an unclosed <details>" "$(jq -c '[.[] | select(.severity == "minor") | .file]' <<<"$f")" \
	'["m.ts"]'
check "later round: an unreasoned decline stays open" "$(r3 "$f" | jq -c '[.findings[] | select(.id == "F4" or .id == "F5")
	| [.id, .status, .unverified]]')" '[["F4","open",true],["F5","open",true]]'

# ── finding IDs never restart ───────────────────────────────────────────────
check "last_ids: the highest IDs of the round" "$(jq -c '.last_ids' <<<"$rec_bullets")" '{"F":13,"L":0}'
one='[{"severity":"minor","title":"t"}]'
r1=$(build_record "$meta" "$one" null)
r2=$(build_record "$(jq -c '.code_review = false | .approach = "rethink"' <<<"$meta")" "$one" "$r1")
check "rethink: keeps last_ids" "$(jq -c '.last_ids' <<<"$r2")" '{"F":1,"L":0}'
check "F1, then a Rethink, then a new finding: F2" "$(build_record "$meta" "$one" "$r2" | jq -r '.findings[0].id')" F2
floor() { jq -c -L "$LIB_DIR" 'include "records"; id_floor' <<<"$1"; }
check "id_floor: no history" "$(floor '[]')" '{"F":0,"L":0}'
check "id_floor: F1 then a Rethink" "$(floor "[$r1, $r2]")" '{"F":1,"L":0}'
check "id_floor: a compacted marker without findings keeps its last_ids" \
	"$(floor '[{"findings":[{"id":"F2"}]},{"findings_dropped":true,"last_ids":{"F":9,"L":4}},{"code_review":false}]')" \
	'{"F":9,"L":4}'
check "id_floor: older markers without last_ids are seeded from their IDs" \
	"$(floor '[{"findings":[{"id":"F3"},{"id":"F12"}],"later":[{"id":"L2"}]},{"findings":[{"id":"F5"}]}]')" \
	'{"F":12,"L":2}'
check "id_floor: the next ID comes after the floor, not the previous record" \
	"$(build_record "$(jq -c '.id_floor = {F: 9, L: 4}' <<<"$meta")" "$one" "$r1" |
		jq -c '[.findings[0].id, .last_ids]')" '["F10",{"F":10,"L":4}]'

ok_block() { # <blocks> [known ids]
	jq -c -L "$LIB_DIR" --argjson ids "${2:-[]}" 'include "records"; map(findings_block_ok($ids))' <<<"$1"
}
check "findings_block_ok: good blocks" "$(ok_block '[[], [{"severity":"Critical","title":"t","file":null,"line":null}],
	[{"severity":"minor","title":"t","file":"a.js","line":3}, {"severity":"important","title":"u"}]]')" \
	"[true,true,true]"
check "findings_block_ok: an earlier ID may give only its status" \
	"$(ok_block '[[{"id":"F3","status":"fixed"}], [{"id":"F3","status":"open","severity":"critical"}], [{"id":null,"status":"new","title":"t"}], [{"status":"new","severity":"minor"}], [{"id":" F3 ","status":"fixed"}]]' '["F1","F3"]')" \
	"[true,true,false,false,true]"
# An ID the last code review does not have is a new finding: without a severity and a title, the Markdown decides.
check "findings_block_ok: an unknown ID must be a whole new finding" \
	"$(ok_block '[[{"id":"F999","status":"open","title":"Nil dereference"}], [{"id":"F2","status":"fixed"}],
	[{"id":"F999","status":"open","severity":"critical","title":"Nil dereference"}]]' '["F1"]')" "[false,false,true]"
check "findings_block_ok: round 1 knows no ID" "$(ok_block '[[{"id":"F1","status":"fixed"}]]')" "[false]"
check "known_ids: the last code review's IDs, none without its list" \
	"$(jq -c -L "$LIB_DIR" 'include "records"; map(known_ids)' <<<"[null, $prev2, $(jq -c '.findings_dropped = true' <<<"$prev2")]")" \
	'[[],["F1","F2","F3","F4","F5"],[]]'
# Round 1 with an invented ID and no severity: the block is not usable, so the Markdown's Critical is the record's.
printf '#### 🚨 Critical\n\n- **`n.go:4` — Nil dereference.**\n' >"$tmp/invented.md"
if jq -e -L "$LIB_DIR" 'include "records"; findings_block_ok(null | known_ids)' \
	<<<'[{"id":"F999","status":"open","title":"Nil dereference"}]' >/dev/null; then
	f='[{"id":"F999","status":"open","title":"Nil dereference"}]'
else f=$(parse_findings "$tmp/invented.md"); fi
check "invented ID: the record has the Critical from the Markdown" \
	"$(build_record "$meta" "$f" null | jq -c '[.counts.critical, .findings[0].id, .findings[0].file]')" '[1,"F1","n.go"]'

check "findings_block_ok: one bad entry spoils the block" "$(ok_block '[{}, [{"level":"critical","title":"t"}],
	[{"severity":"nit","title":"t"}], [{"severity":"minor"}], [{"severity":"minor","title":"t","line":"3"}],
	[{"severity":"minor","title":"t","file":3}], [{"severity":"minor","title":"t"}, "F2"]]')" \
	"[false,false,false,false,false,false,false]"

# ── normalize_ready ─────────────────────────────────────────────────────────
for pair in "Yes=yes" "yes.=yes" "Yes with fixes=yes-with-fixes" "Yes, with fixes=yes-with-fixes" \
	"Yes (with fixes)=yes-with-fixes" "yes — with fixes=yes-with-fixes" "No — see Critical=no" "no.=no" \
	"=unknown" "[Yes | No | Yes with fixes]=unknown"; do
	check "normalize_ready '${pair%%=*}'" "$(normalize_ready "${pair%%=*}")" "${pair#*=}"
done

# ── marker_line and marker_record ───────────────────────────────────────────
generated() { printf '<!-- gh-pr-review generated -->\n%s\n' "$1"; }
build_record "$meta" "$(parse_findings "$fixtures/dashes.md")" null >"$tmp/round.json"
# The review below the marker is the fixture itself, so every title and file is visible to the reader.
line=$(marker_line "$tmp/round.json" "$fixtures/dashes.md")
check "marker: one line" "$(wc -l <<<"$line" | tr -d ' ')" 1
check "marker: one <!--" "$(grep -o -- '<!--' <<<"$line" | wc -l | tr -d ' ')" 1
check "marker: one -->" "$(grep -o -- '-->' <<<"$line" | wc -l | tr -d ' ')" 1
check "marker: no -- inside" "$(grep -c -- '--' <<<"${line:4:${#line}-8}" || true)" 0
body=$(printf '<!-- gh-pr-review generated -->\n%s\n### Approach\n\n**Approach:** Sound\n' "$line")
check "marker: round trip keeps titles" "$(marker_record "$body" | jq -c '[.findings[].title]')" \
	"$(jq -c '[.findings[].title]' "$tmp/round.json")"
check "marker: round trip keeps the record" "$(marker_record "$body" | jq -S .)" "$(jq -S . "$tmp/round.json")"
check "marker: the review as text gives the same line" "$(marker_line "$tmp/round.json" "$(cat "$fixtures/dashes.md")")" \
	"$line"
check "marker: verdict lines unchanged" "$(last_verdict 'approach' "$body")" sound
check "marker_record: a marker example later in the review does not override the record" \
	"$(marker_record "$(printf '%s\nText.\n%s\n' "$body" "${line/\"round\":2/\"round\":1}")" | jq .round)" 2
check "marker_record: no marker, nothing" "$(marker_record $'<!-- gh-pr-review generated -->\ntext')" ""
check "marker_record: broken JSON, nothing" \
	"$(marker_record $'<!-- gh-pr-review generated -->\n<!-- gh-pr-review:round {"round": -->')" ""
check "marker_record: header with trailing CR and spaces" \
	"$(marker_record $'<!-- gh-pr-review generated --> \r\n'"$line"$'\r\ntext' | jq .round)" 2
check "marker_record: a quoted header is not a generated review" \
	"$(marker_record "$(printf 'I saw this:\n<!-- gh-pr-review generated -->\n%s\n' "$line")")" ""
check "marker_record: a marker that is not right below the header is not read" \
	"$(marker_record "$(printf '<!-- gh-pr-review generated -->\nText.\n%s\n' "$line")")" ""
for bad in '"x"' '{"schema":2,"round":1}' '{"schema":1}' '{"schema":1,"round":"1"}' \
	'{"schema":1,"round":1,"counts":{"critical":"2"}}' '{"schema":1,"round":1,"findings":[{"line":"3"}]}' \
	'{"schema":1,"round":1,"findings":"F1"}' '{"schema":1,"round":1,"head_sha":7}'; do
	check "marker_record: invalid record $bad, nothing" \
		"$(marker_record "$(printf '<!-- gh-pr-review generated -->\n<!-- gh-pr-review:round %s -->\n' "$bad")")" ""
done
check "is_generated_review: first line only" "$(jq -c -L "$LIB_DIR" 'include "records"; map(is_generated_review)' <<<'
	["<!-- gh-pr-review generated -->\nx", "<!-- gh-pr-review generated -->\t\r", "x\n<!-- gh-pr-review generated -->",
	 " <!-- gh-pr-review generated -->", "", null]')" "[true,true,false,false,false,false]"

# Only what the reader sees: a title or file that appears nowhere in the posted review is left out of the marker.
jq -n '{schema: 1, round: 1, counts: {}, findings: [
	{id: "F1", title: "Visible   title, with emphasis", file: "src/a_b.js", line: 3},
	{id: "F2", title: "PRIVATE instructions text", file: "secret/plan.md", line: 1},
	{id: "F3", title: null, file: null}]}' >"$tmp/private.json"
line=$(marker_line "$tmp/private.json" $'### Issues\n- **`src/a_b.js:3` — Visible\ntitle, with *emphasis*.** More.')
check "marker: a visible title and file stay" "$(marker_record "$(generated "$line")" | jq -c '.findings[0] | [.title, .file]')" \
	'["Visible   title, with emphasis","src/a_b.js"]'
check "marker: a title and file the reader can't see are left out" \
	"$(marker_record "$(generated "$line")" | jq -c '.findings[1] | [has("title"), has("file"), .line]')" '[false,false,1]'
check "marker: no private text" "$(grep -c -e PRIVATE -e secret <<<"$line" || true)" 0
check "marker: round.json keeps the private text" "$(jq -r '.findings[1].title' "$tmp/private.json")" \
	"PRIVATE instructions text"

# The size cap, step by step, on the exact assembled body: header, newline, marker, newline, review.
jq '.later = [{id: "L1", severity: "minor", file: "src/render.ts", line: 7, title: "Comment says"}]' "$tmp/round.json" \
	>"$tmp/big.json"
len() { printf '%s' "$1" | jq -Rs length; }
header_len=$(len '<!-- gh-pr-review generated -->')
pad_to() { # n -> $tmp/body.md: the fixture, padded with x to n characters
	local have
	have=$(jq -Rs length "$fixtures/dashes.md")
	{
		cat "$fixtures/dashes.md"
		head -c $(($1 - have)) /dev/zero | tr '\0' x
	} >"$tmp/body.md"
}
assembled() { jq -Rs --arg m "$1" '("<!-- gh-pr-review generated -->\n" + $m + "\n" + .) | length' "$tmp/body.md"; }
# The review length that makes the assembled body exactly 60,000 characters with this marker line.
fill() { echo $((60000 - header_len - 1 - $(len "$1") - 1)); }
step() { # name marker-line jq-check
	check "marker cap, $1: body is exactly 60,000" "$(assembled "$2")" 60000
	check "marker cap, $1: shape" "$(marker_record "$(generated "$2")" | jq -c "$3")" true
}
pad_to 3000
full=$(marker_line "$tmp/big.json" "$tmp/body.md")
pad_to "$(fill "$full")"
line=$(marker_line "$tmp/big.json" "$tmp/body.md")
step "full marker" "$line" '[.findings[], .later[] | has("title")] | all'
pad_to $(($(fill "$full") + 1))
line=$(marker_line "$tmp/big.json" "$tmp/body.md")
pad_to "$(fill "$line")"
line=$(marker_line "$tmp/big.json" "$tmp/body.md")
step "titles dropped" "$line" '([.findings[], .later[] | has("title")] | any | not) and (.findings[0] | has("file"))'
pad_to $(($(fill "$line") + 1))
line=$(marker_line "$tmp/big.json" "$tmp/body.md")
pad_to "$(fill "$line")"
line=$(marker_line "$tmp/big.json" "$tmp/body.md")
step "locations dropped" "$line" '(.findings | map(keys) | unique) == [["id", "severity", "status"]] and has("later")'
pad_to $(($(fill "$line") + 1))
line=$(marker_line "$tmp/big.json" "$tmp/body.md")
pad_to "$(fill "$line")"
line=$(marker_line "$tmp/big.json" "$tmp/body.md")
step "later dropped" "$line" '(has("later") | not) and (.findings | length) == 4'
pad_to $(($(fill "$line") + 1))
line=$(marker_line "$tmp/big.json" "$tmp/body.md")
pad_to "$(fill "$line")"
line=$(marker_line "$tmp/big.json" "$tmp/body.md")
step "findings dropped" "$line" '(has("findings") | not) and .findings_dropped and .counts.open_blocking == 3
	and .last_ids == {"F": 4, "L": 0} and .round == 2'
pad_to $(($(fill "$line") + 1))
check "marker cap: no room even for counts, no marker" "$(marker_line "$tmp/big.json" "$tmp/body.md")" ""
check "marker cap: round.json keeps everything" "$(jq -c '[(.findings | length), (.later | length)]' "$tmp/big.json")" \
	"[4,1]"

build_record "$meta2" "$reply" "$prev2" >"$tmp/round3.json"
# The posted review shows every title and file, so the marker keeps them all.
body3=$(jq -r '[.findings[], .later[] | (.file // empty), (.title // empty)] | join("\n")' "$tmp/round3.json")
line=$(marker_line "$tmp/round3.json" "$body3")
check "marker: statuses and later round trip" "$(marker_record "$(generated "$line")" | jq -S .)" \
	"$(jq -S . "$tmp/round3.json")"
check "marker: no -- with statuses" "$(grep -c -- '--' <<<"${line:4:${#line}-8}" || true)" 0
line=$(marker_line "$tmp/round3.json" "$body3$(head -c 59000 /dev/zero | tr '\0' x)")
check "marker: near the cap, last ids and counts stay" \
	"$(marker_record "$(generated "$line")" | jq -c '[.last_ids, .counts.unverified, has("later")]')" '[{"F":7,"L":7},1,false]'

# ── progress_line ───────────────────────────────────────────────────────────
dec='{"label":"converging"}'
check "progress: all counts" "$(progress_line "$(cat "$tmp/round3.json")" "$prev2" "$dec")" \
	"### Round 3 · since round 2
1 fixed · 1 still open · 1 regressed · 2 new (1 in the new commits) · 1 declined · 1 for later · 1 not re-checked \
· open blocking: 4 (was 3) · loop: converging"
rec=$(r3 '[{"id":"F1","status":"fixed"},{"id":"F4","status":"open"},{"id":"F5","status":"open"},
	{"severity":"minor","title":"n"}]')
check "progress: zero counts dropped" "$(progress_line "$rec" "$(jq -c 'del(.counts)' <<<"$prev2")" \
	'{"label":"nit-loop"}' | tail -n 1)" "1 fixed · 2 still open · 1 new · open blocking: 1 · loop: nit loop"
check "progress: unverified, no label" "$(progress_line "$(r3 '[]')" "$prev2" '{"label":null}' | tail -n 1)" \
	"3 not re-checked · open blocking: 2 (was 3)"
check "progress: still open excludes unverified" "$(progress_line "$(r3 '[{"id":"F1","status":"open"}]')" "$prev2" \
	"$dec" | tail -n 1)" "1 still open · 2 not re-checked · open blocking: 2 (was 3) · loop: converging"
rec=$(build_record "$(jq -c '.mode = "full" | .mode_reason = "the previous head is gone"' <<<"$meta2")" \
	'[{"id":"F1","status":"fixed"},{"id":"F4","status":"fixed"},{"id":"F5","status":"fixed"}]' "$prev2")
check "progress: full with a reason" "$(progress_line "$rec" "$prev2" '{"label":"ready"}' | tail -n 1)" \
	"3 fixed · open blocking: 0 (was 3) · loop: ready · full review (the previous head is gone)"
check "progress: full without a reason" "$(progress_line "$(jq -c '.mode_reason = null' <<<"$rec")" "$prev2" \
	'{"label":"ready"}' | tail -n 1)" "3 fixed · open blocking: 0 (was 3) · loop: ready · full review"
check "progress: no previous record, nothing" "$(progress_line "$rec" null "$dec")" ""
rec=$(build_record "$(jq -c '.code_review = false | .approach = "rethink"' <<<"$meta2")" '[]' "$prev2")
check "progress: rethink" "$(progress_line "$rec" "$prev2" "$dec")" \
	"### Round 3 · since round 2
code review skipped: the approach needs a rethink"

# ── backfill_record ─────────────────────────────────────────────────────────
pr='{"host":"github.com","owner":"o","repo":"r","number":7}'
review() { # fixture [state] -> GitHub REST review JSON
	jq -n --rawfile body "$fixtures/$1" --arg state "${2:-COMMENTED}" \
		'{body: $body, commit_id: "c0ffee", submitted_at: "2026-01-02T03:04:05Z", user: {login: "rev"}, state: $state}'
}

rec=$(backfill_record "$(review rethink-only.md CHANGES_REQUESTED)" "$prev" 3 "$pr")
check "backfill rethink: source" "$(jq -r .source <<<"$rec")" backfill
check "backfill rethink: approach" "$(jq -r .approach <<<"$rec")" rethink
check "backfill rethink: no code review" "$(jq -c '[.code_review, .findings, .ready]' <<<"$rec")" '[false,[],"unknown"]'
check "backfill rethink: null counts" "$(jq -c '[.counts[]] | unique' <<<"$rec")" "[null]"
check "backfill rethink: facts" "$(jq -r '[.round, .head_sha, .previous_head_sha, .posted_at, .reviewer, .model,
	.decision, .pr.number] | join(" ")' <<<"$rec")" \
	"3 c0ffee aaa 2026-01-02T03:04:05Z rev test-provider/model-a request-changes 7"

rec=$(backfill_record "$(review pre-approach.md APPROVED)" null 1 "$pr")
check "backfill pre-approach: approach skipped" "$(jq -r .approach <<<"$rec")" skipped
check "backfill pre-approach: ready" "$(jq -r .ready <<<"$rec")" yes
check "backfill pre-approach: counts" "$(jq -c '.counts | [.open_blocking, .critical, .important, .minor]' <<<"$rec")" \
	"[3,1,2,1]"
check "backfill pre-approach: decision" "$(jq -r .decision <<<"$rec")" approve
check "backfill pre-approach: ids" "$(jq -r '[.findings[].id] | join(" ")' <<<"$rec")" "F1 F2 F3 F4"

rec=$(backfill_record "$(review numbered.md)" null 2 "$pr")
check "backfill numbered: approach and ready" "$(jq -r '[.approach, .ready, .code_review] | join(" ")' <<<"$rec")" \
	"questionable no true"
check "backfill numbered: open_blocking" "$(jq .counts.open_blocking <<<"$rec")" 4

rec=$(backfill_record "$(review bullets.md)" null 1 "$pr")
rec2=$(backfill_record "$(review numbered.md)" "$rec" 2 "$pr")
check "backfill after backfill: counts its own findings only, nothing carried" \
	"$(jq -c '[.counts.open_blocking, .counts.unverified, ([.findings[] | select(.unverified)] | length)]' <<<"$rec2")" "[4,0,0]"
check "backfill after backfill: IDs continue, previous head kept" \
	"$(jq -r '[.findings[0].id == "F\($n + 1)", .previous_head_sha == $h] | all' --argjson n "$(jq '[.findings[].id[1:] | tonumber] | max' <<<"$rec")" \
		--arg h "$(jq -r .head_sha <<<"$rec")" <<<"$rec2")" true
check "backfill bullets: ready" "$(jq -r .ready <<<"$rec")" yes-with-fixes
has_list() { jq -L "$LIB_DIR" 'include "records"; has_findings_list' <<<"$1"; }
check "backfill: a standalone review keeps its findings list" "$(has_list "$rec")" true

# A later round posted without its marker: its record carried an Important finding the body does not show (omitted
# by the model, so not re-checked). Read back from the Markdown alone, it must not look like a verified empty list.
prev1=$(jq -nc '{round: 1, head_sha: "aaa", counts: {open_blocking: 1}, findings: [{id: "F1", severity: "important",
	status: "new", first_round: 1, file: "a.ts", line: 1, title: "one"}]}')
r2=$(build_record "$(jq -c '.round = 2 | .mode = "incremental" | .ready = "yes"' <<<"$meta")" \
	'[{"severity":"minor","file":"m.ts","line":2,"title":"Tiny nit"}]' "$prev1")
check "later round without marker: setup, the record carries F1" \
	"$(jq -c '[.counts.open_blocking, .counts.unverified, .last_ids.F]' <<<"$r2")" '[1,1,2]'
later_body() { # <filler length>: the round 2 body as posted, with a filler paragraph before the Assessment
	echo '<!-- gh-pr-review generated -->'
	progress_line "$r2" "$prev1" '{"label":"early"}'
	printf '\n### Issues\n\n#### 🚨 Critical (Must Fix Before Merge)\n\n*(none found)*\n\n'
	printf '#### ⚠️ Important (Should Fix)\n\n*(none found)*\n\n#### 💡 Minor (Nice to Have)\n\n'
	printf -- '- **F2 · `m.ts:2`** — Tiny nit.\n\n'
	head -c "$1" /dev/zero | tr '\0' x
	printf '\n\n### Assessment\n\n**Ready to merge?** Yes\n'
}
filler=$((59776 - $(later_body 1 | jq -Rs length) + 1))
later_body "$filler" >"$tmp/later-padded.md"
check "later round without marker: setup, a 59,776-character body" "$(jq -Rs length "$tmp/later-padded.md")" 59776
check "later round without marker: setup, no room for the marker" \
	"$(marker_line <(jq -c . <<<"$r2") "$(tail -n +2 "$tmp/later-padded.md")")" ""
rec=$(backfill_record "$(jq -n --rawfile body "$tmp/later-padded.md" '{body: $body, commit_id: "bbb",
	submitted_at: "2026-01-03T00:00:00Z", user: {login: "rev"}, state: "APPROVED"}')" "$prev1" 2 "$pr")
check "later round without marker: no findings list" "$(has_list "$rec")" false
check "later round without marker: the blocking count of the progress line, IDs covered" \
	"$(jq -c '[.findings_dropped, .counts.open_blocking, .ready_overridden, .last_ids.F, has("findings")]' <<<"$rec")" \
	'[true,1,true,2,false]'
check "later round without marker: the next round carries nothing it cannot know" \
	"$(build_record "$meta2" '[]' "$rec" | jq -c '[.findings, .counts.open_blocking]')" '[[],0]'
printf '### Issues\n\n- **`a.ts:1`** — x\n\n<details><summary>Later (1)</summary>\n\n- **[e.ts:5]** — slow.\n\n</details>\n' \
	>"$tmp/folded.md"
rec=$(backfill_record "$(jq -n --rawfile body "$tmp/folded.md" '{body: $body}')" null 2 "$pr")
check "later round without marker: a folded Later section is enough" "$(has_list "$rec")" false

finished=true
exit "$fail"
