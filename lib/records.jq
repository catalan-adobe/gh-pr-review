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

# The highest "F<n>" in a record, or 0.
def _last_finding_number: [(.findings // [])[]? | .id | strings | capture("^F(?<n>\\d+)$").n | tonumber] | max // 0;

# round.json from the run's facts, the findings (block or parser) and the previous record (or null).
def build_record($meta; $findings; $prev):
	($meta.code_review != false) as $code_review
	| (($prev // {}) | _last_finding_number) as $last
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
