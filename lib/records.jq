# Round records: the findings parser, the record builder and the hidden marker. Load with
# `jq -L "$LIB_DIR" 'include "records"; …'`. Keep to jq 1.7 builtins (CI runs Ubuntu's jq).

def _trim: sub("^\\s+"; "") | sub("\\s+$"; "");
def _blank: test("^\\s*$");
def _str: if type == "string" and (_blank | not) then . else null end;
def _num: if type == "number" then floor elif type == "string" and test("^\\d+$") then tonumber else null end;
def _title100: if type == "string" then .[0:100] else null end;

# "path:line" right after a backtick or "[": the first one in the text. A range ("a.ts:10–12", en dash or hyphen)
# gives its end too (e).
def _location: [capture("[`\\[](?<f>[\\w./@+~-]+):(?<l>\\d+)(?:[–-](?<e>\\d+))?")] | .[0];
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
	sub("^([-*+]|\\d+\\.)\\s+"; "") as $rest
	| ($rest | _location) as $loc
	| (if $loc then {file: $loc.f, line: ($loc.l | tonumber)}
		+ (if $loc.e != null and ($loc.e | tonumber) > ($loc.l | tonumber) then {line_end: ($loc.e | tonumber)} else {} end)
	else ([$rest | capture("^\\*\\*[`\\[](?<f>[\\w./@+~-]+)[`\\]]")] | .[0].f) as $f
		| if $f != null and ($f | test("[./]")) and ($f | startswith("-") | not)
		then {file: $f, line: null} else {file: null, line: null} end
	end) as $where
	| {severity: $severity, file: $where.file, line: $where.line, title: ($rest | _title)}
		+ (if $where.line_end then {line_end: $where.line_end} else {} end);

# A line that only says there is nothing: "*(none found)*", "None.", "_None found_", also as a list item ("- None.",
# "* None", "+ _None found_", "1. None."). The one check: parse_findings and empty_severities both use it.
def _none_line:
	sub("^\\s*([-*+]|\\d+\\.)\\s+"; "") | ascii_downcase | gsub("[*_()`.\\s]"; "") | . == "none" or . == "nonefound";

# The code-review part of a body in gh-pr-review's format: the text after its first approach verdict line
# ("**Approach:** Sound", Questionable or Rethink: the line last_verdict reads), or the whole text when it has none.
# Every Markdown read that decides a round's counts, sections or findings, the writer's and backfill_record's, reads
# this part only: a heading in the approach ("#### Important context") is never a severity section, and the writer
# and the reader read the same text.
def code_review_part:
	split("\n") as $l
	| (first(range(0; $l | length) as $i
		| select($l[$i] | test("^[\\s*_>-]*approach[*_]*[?:][\\s*_`]*(sound|questionable|rethink)\\b"; "i")) | $i) // null)
	| if . == null then $l | join("\n") else $l[. + 1:] | join("\n") end;

# The Markdown is read only as a fallback: for a findings block that cannot be used, or a review without a usable
# marker. The reader follows the format gh-pr-review asks the model for (the "### Issues" section with severity
# headings, list-item findings, the folded <details> Fixed and Later lists, each tag on its own line), and is best
# effort for other Markdown: fences nested in longer fences, HTML before </details> on one line, headings nested in
# list items.
# A review's Markdown as lines, each with the severity section it is in (s, null outside any), and whether it is a
# heading (h) or in fenced code (code). A heading (0–3 spaces, then 1–6 "#") that names a severity starts that
# section, up to the next heading. Severity headings count only in the code review's Issues section, from a heading
# titled "Issues" to the next heading of the same or a higher level; a body without one is read whole. Lines from a
# line starting with <details to the line starting with </details (a folded Fixed or Later list; 0–3 spaces first,
# outside fenced code) are in no section. Fenced code is tracked inside folds too, and belongs to the section it is in.
def _lines:
	def fence: test("^\\s*(```|~~~)");
	def opens: test("^ {0,3}<details\\b"; "i");
	def closes: test("^ {0,3}</details\\b"; "i") or (opens and test("</details\\s*>\\s*$"; "i"));
	reduce (split("\n")[] | sub("\r$"; "")) as $l ({fence: false, details: 0, s: null, i: null, issues: null, has: false, out: []};
		if .fence or ($l | fence) then
			(if ($l | fence) then .fence |= not else . end)
			| .out += [if .details > 0 then {l: $l, s: null, i: null} else {l: $l, s, i, code: true} end]
		elif .details > 0 or ($l | opens) then
			.details = ([.details + (if $l | opens then 1 else 0 end) - (if $l | closes then 1 else 0 end), 0] | max)
			| .out += [{l: $l, s: null, i: null}]
		elif ($l | test("^ {0,3}#{1,6}\\s")) then
			($l | capture("^ {0,3}(?<level>#+)\\s+(?<title>.*)$")) as $h
			| ($l | _severity) as $sev
			| (if .issues != null and ($h.level | length) <= .issues then .issues = null else . end)
			| (if ($h.title | sub("[\\s#]*$"; "") | ascii_downcase) == "issues" then .issues = ($h.level | length) | .has = true
				else . end)
			| .s = $sev | .i = (if .issues != null then $sev else null end)
			| .out += [{l: $l, s, i, h: true}]
		else .out += [{l: $l, s, i}] end)
	| .has as $has | .out | map({l, s: (if $has then .i else .s end), h: (.h == true), code: (.code == true)});

# Markdown in, findings out: the top-level "- ", "* ", "+ " and "<n>. " items, bold or plain, in each severity section
# (_lines; "- None." is not one). Fenced code is skipped. A location given as a range keeps its last line in line_end
# (the record itself keeps line only: normalize_findings drops it).
def parse_findings:
	[_lines[] | select(.s != null and (.h or .code | not)) | .s as $s | .l
		| select(test("^([-*+]|\\d+\\.)\\s+\\S") and (_none_line | not)) | _finding($s)];

# The severity sections of a review's Markdown (_lines), in order: {severity, lines (the non-blank lines up to the
# next heading), closed (another heading follows)}. Fenced code belongs to the section it is in.
def _sections:
	reduce _lines[] as $x ({open: false, out: []};
		if $x.h then
			(if .open then .out[-1].closed = true else . end)
			| if $x.s != null then .out += [{severity: $x.s, lines: [], closed: false}] | .open = true else .open = false end
		elif .open and $x.s != null and ($x.l | _blank | not) then .out[-1].lines += [$x.l]
		else . end)
	| .out;

# The severities the Markdown says it has none of: each section of that severity holds only a "none" line
# ("*(none found)*", "None.", "- None.": _none_line), or nothing at all before the next heading.
def empty_severities:
	_sections | group_by(.severity)
	| map(select(all(.[]; (.lines | length == 1 and (.[0] | _none_line)) or (.closed and (.lines | length == 0)))))
	| map(.[0].severity);

# Findings from the model's block or the parser, checked: known severities only, file/line/title typed.
def normalize_findings:
	if type == "array" then
		map(select(type == "object")
			| {severity: (.severity | if type == "string" then ascii_downcase else null end),
				file: (.file | _str), line: (.line | _num), title: (.title | _str | _title100)}
			| select(.severity == "critical" or .severity == "important" or .severity == "minor"))
	else [] end;

# The checks below judge the model's findings block (stored_findings) before a record is written from it:
# block_respects_empty and block_covers_markdown. A record posted on GitHub is never judged by its list: it is read
# as it is when its marker is complete (complete_marker), and from its review's Markdown otherwise.

# True for an entry that is still open: not fixed or declined.
def _open: .status | . != "fixed" and . != "declined";

# False when the list ({severity, status, file, line}) has an open entry of a severity the Markdown says it has none of
# ($empty: empty_severities): what the reader sees wins.
def _respects_empty($empty):
	all(.[] | select(_open); .severity as $s | all($empty[]; . != $s));

# True when the list ({severity, status, file, line}) reports at least the blockers the review's Markdown shows
# ($parsed: parse_findings of the posted body): as many open Critical entries, and as many open Critical and Important
# ones together. A list that leaves out or downgrades a visible blocker ([] next to a Critical bullet) fails.
# The locations must match too, one to one: every Critical or Important bullet with a file:line needs its own open
# blocking entry in that file at that line, or, for a range (a.go:10–12, line_end 12), at a line within it (two
# bullets at a.go:10 need two entries there). An entry repeated at one bullet's location does not cover another
# bullet's. Entries and bullets without a file and line take no part in this. Each file's bullets take, shortest end
# first, the lowest free entry line in their range: the greedy choice finds a one-to-one match whenever there is one.
def _covers_markdown($parsed):
	def blocking: (.severity | strings | ascii_downcase) as $s | $s == "critical" or $s == "important";
	def located: (.file | type == "string" and . != "") and (.line | type == "number");
	def location: if located then {file, line: (.line | floor)} else empty end;
	def span: if located then {file, a: (.line | floor),
		b: ([.line, .line_end] | map(numbers | floor) | max)} else empty end;
	def matched($have): group_by(.file) | all(.[];
		.[0].file as $f
		| reduce sort_by(.b, .a)[] as $x ({free: [$have[] | select(.file == $f) | .line] | sort, ok: true};
			if .ok then
				(first(range(0; .free | length) as $i | select(.free[$i] >= $x.a and .free[$i] <= $x.b) | $i) // null) as $i
				| if $i == null then .ok = false else .free |= del(.[$i]) end
			else . end)
		| .ok);
	def open($sev): [.[] | select(.severity == $sev)] | length;
	def shown($sev): [($parsed // [])[]? | objects | select(.severity == $sev)] | length;
	[.[] | select(_open)]
	| [.[] | select(blocking) | location] as $have
	| [($parsed // [])[]? | objects | select(blocking) | span] as $seen
	| open("critical") >= shown("critical")
		and open("critical") + open("important") >= shown("critical") + shown("important")
		and ($seen | matched($have));

# ── Writing: the model's findings block ──

# The status a findings entry from the model is stored with. This version has no statuses across rounds: every entry
# is stored as a new, open finding, so an entry marked fixed, declined or later is new too. The one place that
# decides it.
def stored_status: "new";

# The model's findings as the record will store them: normalized, each entry with its stored_status. The record
# builder stores these, and the block checks (block_respects_empty, block_covers_markdown) judge these, so they never
# disagree about which entries are open.
def stored_findings:
	if type == "array" then [.[] | objects | stored_status as $status | ([.] | normalize_findings)[] + {status: $status}]
	else [] end;

# False when the model's block has an open entry, as stored (stored_findings), of a severity the Markdown says it has
# none of ($empty: empty_severities): the round is parsed instead.
def block_respects_empty($empty): stored_findings | _respects_empty($empty);

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

# True when the model's findings block, as stored (stored_findings: in this version all of it is open), shows every
# blocker the review's Markdown does ($parsed: parse_findings of the posted body; _covers_markdown). Otherwise the
# round is parsed instead.
def block_covers_markdown($parsed): stored_findings | _covers_markdown($parsed);

# ── Reading: a record posted on GitHub ──

# True for a marker read as it is: a Rethink, or a code-review marker with the counts marker_line writes at every
# compaction step but the minimal one: numbers for open_blocking, critical, important and minor, and open_blocking
# the sum of critical and important. Any other marker (minimal, or with partial counts) is read from its review's
# Markdown, like a review without a marker (fetch_round_records in lib/rounds.sh).
def complete_marker:
	.code_review == false
	or (.counts | type == "object" and all(.open_blocking, .critical, .important, .minor; type == "number")
		and .open_blocking == .critical + .important);

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

# A record read back from GitHub, reconciled with the rounds before it ($earlier, already reconciled) and its
# position in submission order. Two runs can both pass the check before posting and claim the same round and the
# same new IDs. When the claimed round is not the position, or a new finding's ID is not above the ID floor of the
# earlier rounds, its new findings (status new, or none) are numbered after that floor, with first_round set to the
# position, and last_ids follows. Other findings, and a record that agrees with its position, are left as they are.
# A compacted record (no findings list, or findings_dropped) still says how many new findings it gave out
# (counts.new): those took the IDs up to its last_ids.F. When it claims a round that is not its position, or those
# IDs reach down to the floor, they are the floor's next ones instead: last_ids.F is at least floor + counts.new.
def reconcile_record($earlier; $position):
	($earlier | id_floor) as $floor
	| def is_new: type == "object" and ((.status // "new") == "new");
	def number: .id | strings | capture("^F(?<n>\\d+)$").n | tonumber;
	(.counts.new? | if type == "number" then floor else 0 end) as $new
	| if ((.findings | type) != "array" or .findings_dropped == true) and $new > 0 then
		if .round != $position or _last_number("F") - $new < $floor.F then
			.last_ids = {F: ([_last_number("F"), $floor.F + $new] | max), L: ([_last_number("L"), $floor.L] | max)}
		else . end
	elif .round != $position or any((.findings // [])[]? | select(is_new); (number // 0) <= $floor.F) then
		(reduce range(0; (.findings // []) | length) as $i ({rec: ., n: $floor.F};
			if (.rec.findings[$i] | is_new) then .n += 1 | .rec.findings[$i] += {id: "F\(.n)", first_round: $position}
			else . end)) as $r
		| $r.rec
		| .last_ids = {F: ([_last_number("F"), $floor.F] | max), L: ([_last_number("L"), $floor.L] | max)}
	else . end;

# round.json from the run's facts, the findings (block or parser) and the previous record (or null). New findings
# are numbered after $meta.id_floor ({F, L}, from id_floor over the whole history) and the previous record. A code
# review read from a Markdown with no severity section ($meta.no_sections: true) does not say how many blockers it
# has: its counts are null, so its blocking is unknown, never 0.
def build_record($meta; $findings; $prev):
	($meta.code_review != false) as $code_review
	| ([($meta.id_floor // {}).F | numbers] + [($prev // {}) | _last_number("F")] | max) as $last
	| ([($meta.id_floor // {}).L | numbers] + [($prev // {}) | _last_number("L")] | max) as $last_later
	| ($meta.round | _num) as $round
	| (if $code_review then $findings | stored_findings else [] end) as $found
	| ($found | to_entries | map({id: "F\(.key + $last + 1)", severity: .value.severity, status: .value.status,
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
		counts: (if $code_review and $meta.no_sections != true then
			{open_blocking: (count("critical") + count("important")), critical: count("critical"),
				important: count("important"), minor: count("minor"), new: ($items | length),
				fixed: 0, declined: 0, regressed: 0}
		else
			{open_blocking: null, critical: null, important: null, minor: null, new: null,
				fixed: null, declined: null, regressed: null}
		end)
	};

# A record rebuilt from an old review (GitHub REST review object). The caller reads the verdict lines. Its findings
# and sections come from the code-review part (code_review_part), as the writer's do: a code review whose part has no
# severity section (_sections) gets null counts (build_record).
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
		code_review: $code_review,
		no_sections: ($body | code_review_part | _sections | length == 0)
	}; (if $code_review then $body | code_review_part | parse_findings else [] end); $prev);

# The first line of every body gh-pr-review posts.
def generated_header: "<!-- gh-pr-review generated -->";

# Text as a reader sees it, for matching a title: bold/italic stars and backticks removed, whitespace runs as one
# space. Underscores stay: "api_key" and "apikey" are different words.
def _visible: gsub("[*`]"; "") | gsub("\\s+"; " ") | _trim;

# A string as a regex that matches it literally.
def _re_literal: gsub("(?<c>[\\\\^$.|?*+()\\[\\]{}/-])"; "\\\(.c)");

# The marker line for a record, posted right below the generated header and above $body, the exact review text.
# One HTML comment: every "--" in the JSON is written "-\u002d". The marker never publishes text the review does not
# show. A file stays only when $body shows that exact path, as a whole path: the whole content of a code span, less
# a ":line" suffix (`src/new file.go:1` shows "src/new file.go", not "file.go"), or, outside code spans, between
# spaces, brackets or quotes, or before ":line". A title stays when $body holds it as it is; else when the review's
# visible text holds it after only the * and ` marks are removed and whitespace is collapsed, and then the marker gets
# that visible form. A title cut to 100 characters may match part of a line. Otherwise the field is left out.
# The whole body (header, newline, marker, newline, review) must fit in 60,000 characters, under GitHub's 65,536: it
# drops titles, then file, line, first_round and in_delta, then later, then findings (findings_dropped: true; counts
# and last_ids stay). When even that does not fit: a minimal marker, {schema, round, findings_dropped: true} and
# last_ids if it fits, so a later round knows the baseline is missing. Nothing when even that does not fit.
def marker_line($body):
	($body | _visible) as $seen
	| ($body | [scan("`([^`\n]+)`") | .[0] | sub(":\\d+.*$"; "") | _trim]) as $spans
	| ($body | gsub("`[^`\n]+`"; "\u0001")) as $prose
	| def file_shown: type == "string" and . != "" and (. as $path | any($spans[]; . == $path)
		or (_re_literal as $f | $prose | test("(^|[\\s`\\[(*\"'])" + $f + "(?=$|[\\s`\\])*:,;\"']|\\.(\\s|$))")));
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

# True when a generated review (a GitHub REST review object) counts as a round: its author is an owner, member or
# collaborator of the repo (author_association), or is $me, the account running the tool ("" when unknown: then the
# association alone decides). Anyone can post a review that starts with the generated header.
def trusted_review($me):
	(.author_association // "") as $a
	| $a == "OWNER" or $a == "MEMBER" or $a == "COLLABORATOR"
		or ($me != "" and (.user.login? // null) == $me);

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
# record. A code-review marker valid but for its counts comes without them: it is then read from its review's
# Markdown (complete_marker), and its IDs still count. Nothing otherwise, and nothing for any other body.
def marker_record:
	select(is_generated_review)
	| (split("\n")[1] // "" | sub("\r$"; ""))
	| [capture("^<!-- gh-pr-review:round (?<j>\\{.*\\}) -->\\s*$").j] | .[0]
	| if . == null then empty else (fromjson? // empty)
		| (if type == "object" and .code_review != false and (valid_record | not) then del(.counts) else . end)
		| select(valid_record) end;
