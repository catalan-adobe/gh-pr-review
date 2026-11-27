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

# A later-round item that names an earlier finding: "**F1 · [a.ts:1]** — …" (the ID inside the bold) or
# "**F1** · `a.ts:1` — …". Out: {id, line: the item without its ID, for _finding, after: the text after the bold},
# or null.
def _id_item:
	sub("^(-|\\d+\\.)\\s+"; "") as $rest
	| ([$rest | capture("^\\*\\*(?<id>F\\d+)\\s*·\\s*(?<r>.*)$")] | .[0]) as $in
	| ([$rest | capture("^\\*\\*(?<id>F\\d+)\\*\\*[\\s·:]*(?<r>.*)$")] | .[0]) as $out
	| if $in != null then {id: $in.id, line: ("- **" + $in.r), after: ($in.r | sub("^.*?\\*\\*"; ""))}
	elif $out != null then {id: $out.id, line: ("- " + $out.r), after: $out.r}
	else null end;

# An item of the folded "Fixed since the last round" section: {id, status: "fixed"}, or {id, status: "declined",
# reason} for "**F5** — declined: "the quoted reason"" (reason null when nothing follows). Null without an ID.
def _fixed_item:
	_id_item as $i
	| if $i == null then null
	else ([$i.after | capture("^[\\s·:—–-]*declined\\b[\\s:—–-]*(?<r>.*)$"; "i")] | .[0]) as $d
		| if $d == null then {id: $i.id, status: "fixed"}
		else {id: $i.id, status: "declined", reason: ($d.r | _trim | if . == "" then null else . end)} end
	end;

# The folded section a "<details>" or "<summary>" line opens: fixed, later, or other.
def _folded: ascii_downcase | if test("fixed") then "fixed" elif test("later") then "later" else "other" end;

# Markdown in, findings out: the "- **" and "<n>. **" items under each heading that names a severity, up to the
# next heading. Fenced code is skipped. Round 2 and later: an item that starts with an earlier ID ("**F1 · …") keeps
# it, as open; the folded <details> sections are not open findings: the Fixed one gives its IDs as fixed (or
# declined, with the quoted reason), the Later one is left out (its items carry no severity).
def parse_findings:
	def item: test("^(-|\\d+\\.)\\s+\\*\\*");
	reduce (split("\n")[] | sub("\r$"; "")) as $l ({severity: null, fence: false, folded: null, out: []};
		if ($l | test("^\\s*(```|~~~)")) then .fence |= not
		elif .fence then .
		elif ($l | test("^\\s*<details\\b"; "i")) then
			.folded = (if ($l | test("</details>"; "i")) then null elif ($l | test("<summary"; "i")) then ($l | _folded)
				else "other" end)
		elif .folded != null and ($l | test("</details>"; "i")) then .folded = null
		elif .folded != null and ($l | test("^\\s*<summary"; "i")) then .folded = ($l | _folded)
		elif ($l | test("^#{1,6}\\s")) then .folded = null | .severity = ($l | _severity)
		elif .folded == "fixed" and ($l | item) then
			($l | _fixed_item) as $f | if $f != null then .out += [$f] else . end
		elif .folded != null then .
		elif .severity != null and ($l | item) then
			.severity as $s | ($l | _id_item) as $i
			| if $i != null then .out += [($i.line | _finding($s)) + {id: $i.id, status: "open"}]
			else .out += [$l | _finding($s)] end
		else . end)
	| .out;

# True when the model's findings block can be used as it is: an array whose every entry is an object with a known
# severity, a string title, a file string or null and a line number or null. One bad entry and the whole round falls
# back to the Markdown, so normalize_findings never drops a finding the reader can see. $ids: the IDs of the last
# code review (known_ids; [] in round 1). Only an entry with one of them may give just its status, the rest coming
# from that record: any other ID is a new finding to the record builder, and needs a severity and a title.
def findings_block_ok($ids):
	def severity_ok: type == "string" and (ascii_downcase | . == "critical" or . == "important" or . == "minor");
	type == "array"
	and all(.[]; type == "object"
		and ((.id | type == "string" and (_trim as $id | $ids | index([$id]) != null)) as $known
			| (.severity | severity_ok or ($known and . == null))
			and (.title | type == "string" or ($known and . == null)))
		and (.file | . == null or type == "string")
		and (.line | . == null or type == "number"));

# True when the findings block reports at least the blockers the review's Markdown shows ($parsed: parse_findings of
# the posted body): as many open Critical findings, and as many open Critical and Important ones together. An entry
# with status fixed or declined, or with later: true, is not open; status and later may be absent. A block that
# leaves out or downgrades a visible blocker ([] next to a Critical bullet) fails, and the round is parsed instead.
# The locations must match too, one to one: every Critical or Important bullet with a file:line needs its own open
# blocking entry at that file:line (two bullets at a.go:10 need two entries there). An entry repeated at one bullet's
# location does not cover another bullet's. Entries and bullets without a file and line take no part in this.
def block_covers_markdown($parsed):
	def blocking: (.severity | strings | ascii_downcase) as $s | $s == "critical" or $s == "important";
	def location: if (.file | type == "string" and . != "") and (.line | type == "number")
		then "\(.file):\(.line | floor)" else empty end;
	def open_entries: [.[] | objects | select(.later != true)
		| select((.status // "new") | . != "fixed" and . != "declined")];
	def open($sev): [open_entries[] | select((.severity | strings | ascii_downcase) == $sev)] | length;
	def shown($sev): [($parsed // [])[]? | objects | select(.severity == $sev)] | length;
	(if type == "array" then . else [] end)
	| [open_entries[] | select(blocking) | location] as $have
	| [($parsed // [])[]? | objects | select(blocking) | location] as $seen
	| open("critical") >= shown("critical")
		and open("critical") + open("important") >= shown("critical") + shown("important")
		and all($seen | group_by(.)[]; .[0] as $at | ($have | map(select(. == $at)) | length) >= length);

# Findings from the model's block or the parser, checked: known severities only, file/line/title typed.
def normalize_findings:
	if type == "array" then
		map(select(type == "object")
			| {severity: (.severity | if type == "string" then ascii_downcase else null end),
				file: (.file | _str), line: (.line | _num), title: (.title | _str | _title100)}
			| select(.severity == "critical" or .severity == "important" or .severity == "minor"))
	else [] end;

# The highest "<prefix><n>" ID in a record's findings, its later list and its last_ids, or 0. last_ids keeps the
# highest numbers even when the lists are empty (a Rethink), cut from the marker, or not carried (fixed, declined,
# Later), so an ID is never given twice.
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
		later: (.later == true), reason: (.reason | _str)};

# True when a record still has its findings list. A marker cut to fit GitHub's size cap can keep the counts but drop
# the list (findings_dropped): an empty list is a round with no findings, a missing one is unknown.
def has_findings_list: type == "object" and (.findings | type) == "array" and .findings_dropped != true;

# The finding IDs a record knows, for findings_block_ok: none without its findings list (or without a record).
def known_ids: if has_findings_list then [.findings[] | objects | .id | strings] else [] end;

# The findings of a code-review round, from the model's array and the previous record's findings.
# Out: {findings, later, last_ids}. Known IDs keep their ID and first round, with the model's status (open on an
# ID last marked fixed is regressed; declined without a reason, or a status outside fixed, open, declined, is open
# and unverified, with the previous severity). Entries without an ID, or with an ID the previous record doesn't
# have, are new: F<n>, or L<n> when Later applies: later true on an Important or Minor finding outside the delta, in
# an incremental or rebased round ($mode), with a file that is not in $delta_files (the files the delta touched). A
# Critical one, one marked in the delta, one in a touched file, one without a file, any when the file list is unknown
# (not an array) and any in a full round stay findings. The first entry for an ID wins. Previous open, new or
# regressed findings the reply leaves out are carried, unverified. A previous record without its findings list
# (has_findings_list) knows no ID and carries nothing. New IDs start after $floor ({F, L}: the highest numbers in the
# whole history) and the previous record's.
def _track($findings; $prev; $round; $mode; $floor; $delta_files):
	(if $prev | has_findings_list then $prev.findings | map(objects | select(.id | type == "string")) else [] end)
	as $old
	| (reduce $old[] as $f ({}; if has($f.id) then . else .[$f.id] = $f end)) as $known
	| reduce ((if ($findings | type) == "array" then $findings else [] end)[] | objects | _entry) as $e (
		{seen: {}, findings: [], later: [],
			f: ([($prev // {}) | _last_number("F"), (($floor // {}).F | numbers)] | max),
			l: ([($prev // {}) | _last_number("L"), (($floor // {}).L | numbers)] | max)};
		if $e.id != null and .seen[$e.id] then .
		else (if $e.id != null then .seen[$e.id] = true else . end)
			| if $e.id != null and $known[$e.id] != null then
				$known[$e.id] as $p
				| (if $e.status == "fixed" or $e.status == "declined" and $e.reason != null then {status: $e.status}
					elif $e.status == "open" or $e.status == "regressed" then
						{status: (if $p.status == "fixed" or $p.status == "regressed" and $e.status == "regressed"
							then "regressed" else "open" end)}
					else {status: "open", unverified: true} end) as $s
				| .findings += [{id: $e.id,
					# A rejected status update (unverified) keeps the previous severity: it cannot downgrade a blocker.
					severity: (if ($e.severity | _severity_ok) and ($s.unverified | not) then $e.severity
						else $p.severity end),
					status: $s.status, first_round: ($p.first_round // $round), in_delta: $e.in_delta,
					file: ($e.file // $p.file), line: ($e.line // $p.line), title: ($e.title // $p.title)}
					+ (if $s.unverified then {unverified: true} else {} end)]
			elif ($e.severity | _severity_ok) | not then .
			elif $e.later and ($e.severity == "important" or $e.severity == "minor") and ($e.in_delta | not)
				and ($mode == "incremental" or $mode == "rebased") and ($delta_files | type) == "array"
				and ($e.file | type) == "string" and ($delta_files | index([$e.file | ltrimstr("./")]) == null) then
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

# A record whose findings miss a file, line or title (a marker leaves out what its review does not show, such as a
# finding the model left out and the round carried) gets them back from the newest record in $history (an array of
# records, oldest first) that has the same ID with that detail.
def recover_details($history):
	([($history // [])[] | objects | (.findings // [])[]? | objects | select(.id | type == "string")] | reverse)
	as $earlier
	| if (.findings | type) == "array" then
		.findings |= map(if type == "object" and (.id | type == "string") then
			.id as $id | [$earlier[] | select(.id == $id)] as $same
			| .file = (.file // first($same[] | .file | strings) // null)
			| .line = (.line // first($same[] | .line | numbers) // null)
			| .title = (.title // first($same[] | .title | strings) // null)
		else . end)
	else . end;

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

# Block entries with an earlier ID and no severity take it from the last code review ($base), so the cross-check
# with the Markdown (block_covers_markdown) counts an open earlier blocker as the blocker it is.
def with_base_severity($base):
	(if $base | has_findings_list then [$base.findings[] | select(.id | type == "string") | {key: .id, value: .severity}]
		| from_entries else {} end) as $severity
	| map(if type == "object" and .severity == null and (.id | type == "string") then .severity = $severity[.id] else . end);

# round.json from the run's facts, the findings (block or parser) and the previous record (or null). Round 1
# findings carry no id or status: all are new. From round 2, see _track. New findings are numbered after
# $meta.id_floor ({F, L}, from id_floor over the whole history) and the previous record. $meta.delta_files: the paths
# the delta touched (changed_files), for Later.
def build_record($meta; $findings; $prev):
	($meta.code_review != false) as $code_review
	| ([($meta.id_floor // {}).F | numbers] + [($prev // {}) | _last_number("F")] | max) as $last
	| ([($meta.id_floor // {}).L | numbers] + [($prev // {}) | _last_number("L")] | max) as $last_later
	| ($meta.round | _num) as $round
	| (if $code_review then _track($findings; $prev; $round; $meta.mode; {F: $last, L: $last_later}; $meta.delta_files)
		else {findings: [], later: [], last_ids: {F: $last, L: $last_later}} end) as $t
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
				# "was" only when the previous findings were there to re-check: else the two counts measure different things.
				+ ["open blocking: \($r.counts.open_blocking // 0)"
					+ (if ($prev.counts.open_blocking? | type) == "number" and ($prev | has_findings_list)
					then " (was \($prev.counts.open_blocking))" else "" end)]
				+ (if ($decision.label? | type) == "string"
					then ["loop: " + (if $decision.label == "nit-loop" then "nit loop" else $decision.label end)]
					else [] end)
				+ (if $r.mode == "full" then ["full review" + (if ($r.mode_reason | type) == "string"
					then " (\($r.mode_reason))" else "" end)] else [] end))
			| join(" · ")
		end
	end;

# True when a review body is a round 2 or later review: a progress line ("### Round 3 · since round 2") near the top,
# or a folded Fixed since / Later section. Its Markdown leaves out what it did not re-check, so it is no findings list.
def later_round_body:
	(split("\n") | map(sub("\r$"; ""))) as $lines
	| ($lines[0:8] | any(test("^###\\s+Round\\s+\\d+\\s+·\\s+since\\s+round\\s+\\d+\\s*$"; "i")))
		or ($lines | any(test("<summary>\\s*(fixed since|later\\b)"; "i")));

# A record rebuilt from an old review (GitHub REST review object). The caller reads the verdict lines. A later-round
# body that lost its marker (later_round_body) gives no findings list (findings_dropped, so the next round is full),
# the open blocking count of its progress line, and last_ids that cover the IDs it shows.
def backfill_record($review; $prev; $round; $pr; $approach; $ready; $code_review):
	($review.body // "") as $body
	| ($code_review and ($body | later_round_body)) as $later_round
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
	}; (if $code_review then $body | parse_findings else [] end);
		# An old review says nothing about which earlier findings were fixed: the previous record only numbers the IDs,
		# so a backfilled round counts what it found, never carries the round before.
		(if $prev == null then null
		else {round: $prev.round, head_sha: $prev.head_sha,
			last_ids: {F: ($prev | _last_number("F")), L: ($prev | _last_number("L"))}} end))
	| if $later_round | not then .
	else ([$body | parse_findings[] | .id | strings | capture("^F(?<n>\\d+)$").n | tonumber] | max // 0) as $shown
		| ([$body | split("\n")[0:8][] | capture("open blocking: (?<n>\\d+)").n | tonumber] | first // null)
		as $blocking
		| del(.findings, .later) | .findings_dropped = true
		| .last_ids.F = ([.last_ids.F, $shown] | max)
		| if $blocking == null then .
		else .counts.open_blocking = $blocking
			| .ready_overridden = ((.ready == "yes" or .ready == "yes-with-fixes") and $blocking > 0) end
	end;

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
