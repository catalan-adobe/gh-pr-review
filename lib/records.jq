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

# True when the model's findings block can be used as it is: an array whose every entry is an object with a known
# severity, a string title, a file string or null and a line number or null. One bad entry and the whole round falls
# back to the Markdown, so normalize_findings never drops a finding the reader can see.
def findings_block_ok:
	type == "array"
	and all(.[]; type == "object"
		and (.severity | type == "string" and (ascii_downcase | . == "critical" or . == "important" or . == "minor"))
		and (.title | type == "string")
		and (.file | . == null or type == "string")
		and (.line | . == null or type == "number"));

# Findings from the model's block or the parser, checked: known severities only, file/line/title typed.
def normalize_findings:
	if type == "array" then
		map(select(type == "object")
			| {severity: (.severity | if type == "string" then ascii_downcase else null end),
				file: (.file | _str), line: (.line | _num), title: (.title | _str | _title100)}
			| select(.severity == "critical" or .severity == "important" or .severity == "minor"))
	else [] end;

# The highest "<prefix><n>" ID in a record's findings, its later list and its last_ids, or 0. last_ids keeps the
# highest numbers even when the lists are empty (a Rethink) or cut from the marker, so an ID is never given twice.
def _last_number($prefix):
	[((.findings // [])[]?, (.later // [])[]?) | objects | .id | strings
		| capture("^" + $prefix + "(?<n>\\d+)$").n | tonumber]
	+ [(.last_ids // {})[$prefix]? | numbers]
	| max // 0;

# The ID floor of a history (an array of records): the highest F and L numbers any round used. Older markers have
# no last_ids: their findings and later IDs seed it.
def id_floor: map(objects) | {F: (map(_last_number("F")) | max // 0), L: (map(_last_number("L")) | max // 0)};

# round.json from the run's facts, the findings (block or parser) and the previous record (or null). New findings
# are numbered after $meta.id_floor ({F, L}, from id_floor over the whole history) and the previous record.
def build_record($meta; $findings; $prev):
	($meta.code_review != false) as $code_review
	| ([($meta.id_floor // {}).F | numbers] + [($prev // {}) | _last_number("F")] | max) as $last
	| ([($meta.id_floor // {}).L | numbers] + [($prev // {}) | _last_number("L")] | max) as $last_later
	| ($meta.round | _num) as $round
	| (if $code_review then $findings | normalize_findings else [] end) as $found
	| ($found | to_entries | map({id: "F\(.key + $last + 1)", severity: .value.severity, status: "new",
		first_round: $round, in_delta: false, file: .value.file, line: .value.line, title: .value.title})) as $items
	| def count($s): $items | map(select(.severity == $s)) | length;
	{
		schema: 1,
		source: $meta.source,
		pr: ($meta.pr | if type == "object" then {host, owner, repo, number: (.number | _num)} else null end),
		round: $round,
		mode: $meta.mode,
		reviewer: $meta.reviewer,
		model: $meta.model,
		posted_at: $meta.posted_at,
		base_sha: $meta.base_sha,
		head_sha: $meta.head_sha,
		previous_head_sha: ($meta.previous_head_sha // ($prev // {}).head_sha),
		approach: $meta.approach,
		ready: $meta.ready,
		decision: $meta.decision,
		preview: ($meta.preview == true),
		code_review: $code_review,
		findings: $items,
		later: [],
		last_ids: {F: ($last + ($items | length)), L: $last_later},
		counts: (if $code_review then
			{open_blocking: (count("critical") + count("important")), critical: count("critical"),
				important: count("important"), minor: count("minor"), new: ($items | length),
				fixed: 0, declined: 0, regressed: 0}
		else
			{open_blocking: null, critical: null, important: null, minor: null, new: null,
				fixed: null, declined: null, regressed: null}
		end)
	};

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

# The first line of every body gh-pr-review posts.
def generated_header: "<!-- gh-pr-review generated -->";

# Text as a reader sees it, for matching a title: bold/italic stars and backticks removed, whitespace runs as one
# space. Underscores stay: "api_key" and "apikey" are different words.
def _visible: gsub("[*`]"; "") | gsub("\\s+"; " ") | _trim;

# A string as a regex that matches it literally.
def _re_literal: gsub("(?<c>[\\\\^$.|?*+()\\[\\]{}/-])"; "\\\(.c)");

# The marker line for a record, posted right below the generated header and above $body, the exact review text.
# One HTML comment: every "--" in the JSON is written "-\u002d". The marker never publishes text the review does not
# show. A file stays only when $body shows that exact path, as a whole path (in backticks, before ":line", or
# between spaces or brackets). A title stays when $body holds it as it is; else when the review's visible text holds
# it after only the * and ` marks are removed and whitespace is collapsed, and then the marker gets that visible
# form. A title cut to 100 characters may match part of a line. Otherwise the field is left out.
# The whole body (header, newline, marker, newline, review) must fit in 60,000 characters, under GitHub's 65,536: it
# drops titles, then file, line, first_round and in_delta, then later, then findings (findings_dropped: true; counts
# and last_ids stay). When even that does not fit: a minimal marker, {schema, round, findings_dropped: true} and
# last_ids if it fits, so a later round knows the baseline is missing. Nothing when even that does not fit.
def marker_line($body):
	($body | _visible) as $seen
	| def file_shown: type == "string" and . != "" and (_re_literal as $f
		| $body | test("(^|[\\s`\\[(*\"'])" + $f + "(?=$|[\\s`\\])*:,;\"']|\\.(\\s|$))"));
	def title_shown: if type != "string" or (_trim == "") then null
		elif (. as $t | $body | contains($t)) then .
		else _visible as $t | if $t != "" and ($seen | contains($t)) then $t else null end end;
	def public: if type == "array" then map(if type == "object" then
			(if has("title") and .title != null then
				(.title | _title100 | title_shown) as $t | if $t != null then .title = $t else del(.title) end
			else . end)
			| (if has("file") and .file != null and (.file | file_shown | not) then del(.file) else . end)
		else . end) else . end;
	def line: "<!-- gh-pr-review:round " + (tojson | gsub("--"; "-\\u002d")) + " -->";
	def fits: (generated_header + "\n" + line + "\n" + $body | length) <= 60000;
	(if has("findings") then .findings |= public else . end)
	| (if has("later") then .later |= public else . end)
	| if fits then . else del(.findings[]?.title, .later[]?.title) end
	| if fits then . else del(.findings[]?.file, .findings[]?.line, .findings[]?.first_round, .findings[]?.in_delta,
		.later[]?.file, .later[]?.line, .later[]?.first_round, .later[]?.in_delta) end
	| if fits then . else del(.later) end
	| if fits then . else del(.findings) | .findings_dropped = true end
	| if fits then . else {schema: 1, round, findings_dropped: true} + (if .last_ids then {last_ids} else {} end) end
	| if fits then . else del(.last_ids) end
	| if fits then line else empty end;

# True when a review body is a generated round: its first line is exactly the generated marker (trailing spaces
# or CR allowed). A review that quotes the marker further down is a person's review.
def is_generated_review:
	type == "string" and ((split("\n")[0] // "" | sub("\\s+$"; "")) == generated_header);

def _opt($t): . == null or type == $t;

# A marker record as gh-pr-review writes it: schema 1, a round number, and the optional fields typed.
def valid_record:
	type == "object" and .schema == 1 and (.round | type == "number")
	and all(.source, .mode, .reviewer, .model, .posted_at, .base_sha, .head_sha, .previous_head_sha, .approach,
		.ready, .decision; _opt("string"))
	and all(.preview, .code_review, .forced, .findings_dropped; _opt("boolean"))
	and (.counts | _opt("object") and (. == null or all(.[]; _opt("number"))))
	and (.last_ids | _opt("object") and (. == null or all(.[]; _opt("number"))))
	and all(.findings, .later; _opt("array") and (. == null or all(.[]; type == "object"
		and (.id | _opt("string")) and (.severity | _opt("string")) and (.title | _opt("string"))
		and (.file | _opt("string")) and (.line | _opt("number")))));

# The record of a generated review: the marker on the line right below the generated marker, when it holds a valid
# record. Nothing otherwise, and nothing for any other body.
def marker_record:
	select(is_generated_review)
	| (split("\n")[1] // "" | sub("\r$"; ""))
	| [capture("^<!-- gh-pr-review:round (?<j>\\{.*\\}) -->\\s*$").j] | .[0]
	| if . == null then empty else (fromjson? // empty) | select(valid_record) end;
