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
trap 'rm -rf "$tmp"' EXIT
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
check "ids continue after F7" "$(jq -r '[.findings[].id] | join(" ")' <<<"$rec")" "F8 F9 F10 F11 F12 F13"
check "open_blocking" "$(jq '.counts.open_blocking' <<<"$rec")" 4
check "counts" "$(jq -c '.counts' <<<"$rec")" \
	'{"open_blocking":4,"critical":1,"important":3,"minor":2,"new":6,"fixed":0,"declined":0,"regressed":0}'
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

# ── finding IDs never restart ───────────────────────────────────────────────
check "last_ids: the highest IDs of the round" "$(jq -c '.last_ids' <<<"$rec")" '{"F":13,"L":0}'
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

ok_block() { jq -c -L "$LIB_DIR" 'include "records"; map(findings_block_ok)' <<<"$1"; }
check "findings_block_ok: good blocks" "$(ok_block '[[], [{"severity":"Critical","title":"t","file":null,"line":null}],
	[{"severity":"minor","title":"t","file":"a.js","line":3}, {"severity":"important","title":"u"}]]')" \
	"[true,true,true]"
check "findings_block_ok: one bad entry spoils the block" "$(ok_block '[{}, [{"level":"critical","title":"t"}],
	[{"severity":"nit","title":"t"}], [{"severity":"minor"}], [{"severity":"minor","title":"t","line":"3"}],
	[{"severity":"minor","title":"t","file":3}], [{"severity":"minor","title":"t"}, "F2"]]')" \
	"[false,false,false,false,false,false,false]"

covers() { # block parsed -> block_covers_markdown
	jq -c -n -L "$LIB_DIR" --argjson b "$1" --argjson p "$2" 'include "records"; $b | block_covers_markdown($p)'
}
crit='[{"severity":"critical","title":"t"}]'
check "block_covers_markdown: [] next to a Critical bullet does not cover it" "$(covers '[]' "$crit")" false
check "block_covers_markdown: the same Critical covers it" "$(covers '[{"severity":"Critical","title":"x"}]' "$crit")" true
check "block_covers_markdown: a Critical downgraded to Important does not cover it" \
	"$(covers '[{"severity":"important","title":"x"}]' "$crit")" false
check "block_covers_markdown: a Critical covers an Important" \
	"$(covers '[{"severity":"critical","title":"x"}]' '[{"severity":"important","title":"t"}]')" true
check "block_covers_markdown: a downgrade to minor does not cover an Important" \
	"$(covers '[{"severity":"minor","title":"x"}]' '[{"severity":"important","title":"t"}]')" false
check "block_covers_markdown: fixed, declined and later entries are not open" \
	"$(covers '[{"severity":"critical","status":"fixed"},{"severity":"critical","status":"declined"},
		{"severity":"critical","later":true}]' "$crit")" false
check "block_covers_markdown: open, regressed and status-less entries are" \
	"$(covers '[{"severity":"critical","status":"open"},{"severity":"important","status":"regressed"},{"severity":"important"}]' \
		'[{"severity":"critical"},{"severity":"important"},{"severity":"important"}]')" true
check "block_covers_markdown: minor findings in the Markdown need no cover" \
	"$(covers '[]' '[{"severity":"minor","title":"t"}]')" true
two='[{"severity":"critical","file":"a.go","line":10},{"severity":"critical","file":"b.go","line":11}]'
check "block_covers_markdown: one location repeated does not cover another blocker's" \
	"$(covers '[{"severity":"critical","file":"a.go","line":10},{"severity":"critical","file":"a.go","line":10}]' "$two")" false
check "block_covers_markdown: each location once covers them" \
	"$(covers '[{"severity":"critical","file":"b.go","line":11},{"severity":"important","file":"a.go","line":10},
		{"severity":"critical","title":"no location"}]' "$two")" true
check "block_covers_markdown: two bullets at one location need two entries there" \
	"$(covers '[{"severity":"critical","file":"a.go","line":10},{"severity":"critical","file":"c.go","line":1}]' \
		'[{"severity":"critical","file":"a.go","line":10},{"severity":"critical","file":"a.go","line":10}]')" false
check "block_covers_markdown: entries and bullets without a location take no part" \
	"$(covers '[{"severity":"critical","title":"x"},{"severity":"critical","file":"z.go"}]' \
		'[{"severity":"critical","file":"a.go","line":null},{"severity":"critical","file":null,"line":null}]')" true
check "block_covers_markdown: a fixed entry at the location does not cover it" \
	"$(covers '[{"severity":"critical","file":"a.go","line":10,"status":"fixed"},{"severity":"critical"}]' \
		'[{"severity":"critical","file":"a.go","line":10}]')" false

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
check "marker: a visible title and file stay, the title as the reader sees it" \
	"$(marker_record "$(generated "$line")" | jq -c '.findings[0] | [.title, .file]')" '["Visible title, with emphasis","src/a_b.js"]'
check "marker: a title and file the reader can't see are left out" \
	"$(marker_record "$(generated "$line")" | jq -c '.findings[1] | [has("title"), has("file"), .line]')" '[false,false,1]'
check "marker: no private text" "$(grep -c -e PRIVATE -e secret <<<"$line" || true)" 0
check "marker: round.json keeps the private text" "$(jq -r '.findings[1].title' "$tmp/private.json")" \
	"PRIVATE instructions text"

# A path is published only as the review shows it, and a title only as the reader sees it: underscores count.
jq -n '{schema: 1, round: 1, counts: {}, findings: [
	{id: "F1", title: "Leaks the api_key header", file: "api_key.go", line: 1},
	{id: "F2", title: "Rename snake_case fields", file: "key.go", line: 2},
	{id: "F3", title: "Uses `api_key` in *logs*", file: "pkg/apikey.go", line: 3}]}' >"$tmp/paths.json"
line=$(marker_line "$tmp/paths.json" $'- **`apikey.go:1` — Leaks the apikey header.**\n- **Rename snake_case fields** in the store.\n- `pkg/apikey.go`: Uses api_key in logs')
check "marker: apikey.go shown, api_key.go is not published, nor its underscore-less title" \
	"$(marker_record "$(generated "$line")" | jq -c '.findings[0] | [has("file"), has("title")]')" '[false,false]'
check "marker: key.go inside apikey.go is not a shown path; an underscore title is" \
	"$(marker_record "$(generated "$line")" | jq -c '.findings[1] | [has("file"), .title]')" '[false,"Rename snake_case fields"]'
check "marker: a whole path and a title behind Markdown marks are published as shown" \
	"$(marker_record "$(generated "$line")" | jq -c '.findings[2] | [.file, .title]')" '["pkg/apikey.go","Uses api_key in logs"]'

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
line=$(marker_line "$tmp/big.json" "$tmp/body.md")
pad_to "$(fill "$line")"
line=$(marker_line "$tmp/big.json" "$tmp/body.md")
step "no room for counts: minimal marker" "$line" '. == {"schema": 1, "round": 2, "findings_dropped": true, "last_ids": {"F": 4, "L": 0}}'
pad_to $(($(fill "$line") + 1))
line=$(marker_line "$tmp/big.json" "$tmp/body.md")
pad_to "$(fill "$line")"
line=$(marker_line "$tmp/big.json" "$tmp/body.md")
step "minimal marker without last_ids" "$line" '. == {"schema": 1, "round": 2, "findings_dropped": true}'
pad_to $(($(fill "$line") + 1))
check "marker cap: no room even for the minimal marker, no marker" "$(marker_line "$tmp/big.json" "$tmp/body.md")" ""
check "marker cap: round.json keeps everything" "$(jq -c '[(.findings | length), (.later | length)]' "$tmp/big.json")" \
	"[4,1]"

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
check "backfill bullets: ready" "$(jq -r .ready <<<"$rec")" yes-with-fixes

exit "$fail"
