# Round records: the findings parser, the record builder and the hidden marker. Load with
# `jq -L "$LIB_DIR" 'include "records"; …'`. Keep to jq 1.7 builtins (CI runs Ubuntu's jq).

def _trim: sub("^\\s+"; "") | sub("\\s+$"; "");
def _blank: test("^\\s*$");
def _str: if type == "string" and (_blank | not) then . else null end;
def _num: if type == "number" then floor elif type == "string" and test("^\\d+$") then tonumber else null end;
def _title100: if type == "string" then .[0:100] else null end;

# "path:line" right after a backtick or "[": the first one in the text, line = start of a range.
def _location: [capture("[`\\[](?<f>[\\w./@+~-]+):(?<l>\\d+)")] | .[0];
# A leading location, with its range and closing mark ("`a.ts:10–12`", "[a.ts:10]", "a.ts:10").
def _strip_location: sub("^\\s*[`\\[]?[\\w./@+~-]+:\\d+[^\\s`\\]]*[`\\]]?"; "");

# The severity a heading opens, or null.
def _severity:
	ascii_downcase
	| if test("critical") then "critical"
	elif test("important") then "important"
	elif test("minor") then "minor"
	else null end;

# A finding's title from its first line, list marker removed. With " — " inside the bold part: the text after it,
# up to the closing "**". Otherwise the bold text without its location, or, when the bold part is only the
# location, the text after it. Bold marks removed, cut to 100 characters.
def _title:
	([capture("^\\*\\*(?<b>.*?)\\*\\*(?<a>.*)$")] | .[0]) as $p
	| (if $p == null then {b: ltrimstr("**"), a: ""} else $p end) as $p
	| (if ($p.b | test(" [—–] ")) then $p.b | sub("^.*? [—–] "; "")
	else ($p.b | _strip_location | sub("^[\\s:—–-]+"; "")) as $t
		| if ($t | _blank) then $p.a | sub("^[\\s:—–-]+"; "") else $t end
	end)
	| gsub("\\*\\*"; "") | _trim | .[0:100] | _trim
	| if . == "" then null else . end;

# One finding from an item's first line.
def _finding($severity):
	sub("^(-|\\d+\\.)\\s+"; "") as $rest
	| ($rest | _location) as $loc
	| (if $loc then {file: $loc.f, line: ($loc.l | tonumber)}
	else ([$rest | capture("^\\*\\*[`\\[](?<f>[\\w./@+~-]+)[`\\]]")] | .[0].f) as $f
		| if $f != null and ($f | test("[./]")) and ($f | startswith("-") | not)
		then {file: $f, line: null} else {file: null, line: null} end
	end) as $where
	| {severity: $severity, file: $where.file, line: $where.line, title: ($rest | _title)};

# Markdown in, findings out: the "- **" and "<n>. **" items under each heading that names a severity, up to the
# next heading. Fenced code is skipped.
def parse_findings:
	reduce (split("\n")[] | sub("\r$"; "")) as $l ({severity: null, fence: false, out: []};
		if ($l | test("^\\s*(```|~~~)")) then .fence |= not
		elif .fence then .
		elif ($l | test("^#{1,6}\\s")) then .severity = ($l | _severity)
		elif .severity != null and ($l | test("^(-|\\d+\\.)\\s+\\*\\*")) then
			.severity as $s | .out += [$l | _finding($s)]
		else . end)
	| .out;

# Findings from the model's block or the parser, checked: known severities only, file/line/title typed.
def normalize_findings:
	if type == "array" then
		map(select(type == "object")
			| {severity: (.severity | if type == "string" then ascii_downcase else null end),
				file: (.file | _str), line: (.line | _num), title: (.title | _str | _title100)}
			| select(.severity == "critical" or .severity == "important" or .severity == "minor"))
	else [] end;

# The highest "<prefix><n>" ID in a record's findings, its later list and its last_ids, or 0. The last_ids field
# keeps the numbers of findings that were not carried (fixed, declined, Later), so an ID is never given twice.
def _last_number($prefix):
	[((.findings // [])[]?, (.later // [])[]?) | objects | .id | strings
		| capture("^" + $prefix + "(?<n>\\d+)$").n | tonumber]
	+ [(.last_ids // {})[$prefix]? | numbers]
	| max // 0;

def _severity_ok: . == "critical" or . == "important" or . == "minor";

# One entry of the model's array, typed: id and status as given (strings or null), the rest as normalize_findings.
def _entry:
	{id: (.id | _str | if . then _trim else null end), status: (.status | if type == "string" then ascii_downcase | _trim
		else null end), severity: (.severity | if type == "string" then ascii_downcase | _trim else null end),
		file: (.file | _str), line: (.line | _num), title: (.title | _str | _title100), in_delta: (.in_delta == true),
		later: (.later == true)};

# The findings of a code-review round, from the model's array and the previous record's findings.
# Out: {findings, later, last_ids}. Known IDs keep their ID and first round, with the model's status (open on an
# ID last marked fixed is regressed; a status outside fixed, open, declined is open and unverified). Entries
# without an ID, or with an ID the previous record doesn't have, are new: F<n>, or L<n> with later true. The first
# entry for an ID wins. Previous open, new or regressed findings the reply leaves out are carried, unverified.
def _track($findings; $prev; $round):
	(($prev // {}).findings // [] | map(objects | select(.id | type == "string"))) as $old
	| (reduce $old[] as $f ({}; if has($f.id) then . else .[$f.id] = $f end)) as $known
	| reduce ((if ($findings | type) == "array" then $findings else [] end)[] | objects | _entry) as $e (
		{seen: {}, findings: [], later: [], f: (($prev // {}) | _last_number("F")), l: (($prev // {}) | _last_number("L"))};
		if $e.id != null and .seen[$e.id] then .
		else (if $e.id != null then .seen[$e.id] = true else . end)
			| if $e.id != null and $known[$e.id] != null then
				$known[$e.id] as $p
				| (if $e.status == "fixed" or $e.status == "declined" then {status: $e.status}
					elif $e.status == "open" or $e.status == "regressed" then
						{status: (if $p.status == "fixed" or $p.status == "regressed" and $e.status == "regressed"
							then "regressed" else "open" end)}
					else {status: "open", unverified: true} end) as $s
				| .findings += [{id: $e.id,
					severity: (if ($e.severity | _severity_ok) then $e.severity else $p.severity end),
					status: $s.status, first_round: ($p.first_round // $round), in_delta: $e.in_delta,
					file: ($e.file // $p.file), line: ($e.line // $p.line), title: ($e.title // $p.title)}
					+ (if $s.unverified then {unverified: true} else {} end)]
			elif ($e.severity | _severity_ok) | not then .
			elif $e.later then
				.l += 1
				| .later += [{id: "L\(.l)", severity: $e.severity, file: $e.file, line: $e.line, title: $e.title}]
			else
				.f += 1
				| .findings += [{id: "F\(.f)", severity: $e.severity, status: "new", first_round: $round,
					in_delta: $e.in_delta, file: $e.file, line: $e.line, title: $e.title}]
			end
		end)
	| .seen as $seen
	| {findings: (.findings + [$old[] | select(.status == "open" or .status == "new" or .status == "regressed")
			| select($seen[.id] | not)
			| {id, severity, status: "open", first_round, in_delta: false, file, line, title, unverified: true}]
			| reduce .[] as $f ({ids: {}, out: []}; if .ids[$f.id] then . else .ids[$f.id] = true | .out += [$f] end)
			| .out),
		later: .later, last_ids: {F: .f, L: .l}};

# round.json from the run's facts, the findings (block or parser) and the previous record (or null).
# Round 1 findings carry no id or status: all are new. From round 2, see _track.
def build_record($meta; $findings; $prev):
	($meta.code_review != false) as $code_review
	| ($meta.round | _num) as $round
	| (if $code_review then _track($findings; $prev; $round)
		else {findings: [], later: [], last_ids: {F: (($prev // {}) | _last_number("F")),
			L: (($prev // {}) | _last_number("L"))}} end) as $t
	| $t.findings as $items
	| def open: select(.status == "open" or .status == "new" or .status == "regressed");
	def count($s): [$items[] | open | select(.severity == $s)] | length;
	def status($s): [$items[] | select(.status == $s)] | length;
	(if $code_review then
		{open_blocking: (count("critical") + count("important")), critical: count("critical"),
			important: count("important"), minor: count("minor"), new: status("new"), fixed: status("fixed"),
			declined: status("declined"), regressed: status("regressed"), later: ($t.later | length),
			unverified: ([$items[] | select(.unverified == true)] | length)}
	else
		{open_blocking: null, critical: null, important: null, minor: null, new: null,
			fixed: null, declined: null, regressed: null, later: null, unverified: null}
	end) as $counts
	| {
		schema: 1,
		source: $meta.source,
		pr: ($meta.pr | if type == "object" then {host, owner, repo, number: (.number | _num)} else null end),
		round: $round,
		mode: $meta.mode,
		mode_reason: ($meta.mode_reason | _str),
		reviewer: $meta.reviewer,
		model: $meta.model,
		posted_at: $meta.posted_at,
		base_sha: $meta.base_sha,
		head_sha: $meta.head_sha,
		previous_head_sha: ($meta.previous_head_sha // ($prev // {}).head_sha),
		approach: $meta.approach,
		ready: $meta.ready,
		ready_overridden: ($code_review and ($meta.ready == "yes" or $meta.ready == "yes-with-fixes")
			and $counts.open_blocking > 0),
		decision: $meta.decision,
		preview: ($meta.preview == true),
		code_review: $code_review,
		findings: $items,
		later: $t.later,
		last_ids: $t.last_ids,
		counts: $counts
	};

# The progress line that opens a round 2 or later body, for a person. $prev: the previous code-review record, or
# null (no line). $decision: loop_decide over the history with this record, so its label is this round's.
#   ### Round 3 · since round 2
#   4 fixed · 2 still open · 3 new (1 in the new commits) · open blocking: 5 (was 6) · loop: converging
def progress_line($prev; $decision):
	. as $r
	| if $prev == null then empty
	else "### Round \($r.round) · since round \($prev.round)",
		if $r.code_review == false then "code review skipped: the approach needs a rethink"
		else ($r.findings // []) as $f
			| def n($s): [$f[] | select(.status == $s and (.unverified != true))] | length;
			def part($n; $text): if $n > 0 then ["\($n) \($text)"] else [] end;
			([$f[] | select(.status == "new" and .in_delta == true)] | length) as $delta
			| ([$f[] | select(.unverified == true)] | length) as $unverified
			| (part(n("fixed"); "fixed") + part(n("open"); "still open") + part(n("regressed"); "regressed")
				+ (if n("new") > 0 then ["\(n("new")) new" + (if $delta > 0 then " (\($delta) in the new commits)"
					else "" end)] else [] end)
				+ part(n("declined"); "declined") + part(($r.later // []) | length; "for later")
				+ part($unverified; "not re-checked")
				+ ["open blocking: \($r.counts.open_blocking // 0)"
					+ (if ($prev.counts.open_blocking? | type) == "number" then " (was \($prev.counts.open_blocking))"
					else "" end)]
				+ (if ($decision.label? | type) == "string"
					then ["loop: " + (if $decision.label == "nit-loop" then "nit loop" else $decision.label end)]
					else [] end)
				+ (if $r.mode == "full" then ["full review" + (if ($r.mode_reason | type) == "string"
					then " (\($r.mode_reason))" else "" end)] else [] end))
			| join(" · ")
		end
	end;

# A record rebuilt from an old review (GitHub REST review object). The caller reads the verdict lines.
def backfill_record($review; $prev; $round; $pr; $approach; $ready; $code_review):
	($review.body // "") as $body
	| build_record({
		source: "backfill",
		pr: $pr,
		round: $round,
		mode: "full",
		reviewer: $review.user.login,
		model: ([$body | capture("gh pr-review · model: (?<m>[^*\\s]+)")] | last | .m?),
		head_sha: $review.commit_id,
		approach: $approach,
		ready: $ready,
		decision: ({APPROVED: "approve", CHANGES_REQUESTED: "request-changes", COMMENTED: "comment"}
			| .[$review.state | strings] // null),
		posted_at: $review.submitted_at,
		code_review: $code_review
	}; (if $code_review then $body | parse_findings else [] end); $prev);

# The marker line for a record, for a body of $len characters. One HTML comment: every "--" in the JSON is
# written "-\u002d". Past 60,000 characters (body, newline and marker) it drops titles, then later, then findings.
def marker_line($len):
	def line: "<!-- gh-pr-review:round " + (tojson | gsub("--"; "-\\u002d")) + " -->";
	def fits: $len + 1 + (line | length) <= 60000;
	def cut: if type == "array" then map(if type == "object" and has("title") then .title |= _title100 else . end)
		else . end;
	(if has("findings") then .findings |= cut else . end)
	| (if has("later") then .later |= cut else . end)
	| if fits then . else del(.findings[]?.title, .later[]?.title) end
	| if fits then . else del(.later) end
	| if fits then . else del(.findings) end
	| line;

# The record in the last marker line of a body, or nothing.
def marker_record:
	[split("\n")[] | sub("\r$"; "") | capture("^\\s*<!-- gh-pr-review:round (?<j>\\{.*\\}) -->\\s*$").j]
	| last
	| if . == null then empty else (fromjson? // empty) | objects end;
