#!/usr/bin/env bash
# Checks the loop rules (lib/loop.jq) and their Bash wrappers (lib/loop.sh) on synthetic records built from the
# blocking series of the spec's calibration table.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
LIB_DIR="$root/lib"
# shellcheck source=lib/loop.sh
source "$root/lib/loop.sh"
fail=0

eq() { # name got want
	if [[ "$2" == "$3" ]]; then echo "ok   $1"; else
		echo "FAIL $1: got '$2', want '$3'"
		fail=1
	fi
}

# Prints `<word> ` n times: rep no 3 → "no no no".
rep() { # word n
	local i out=()
	for ((i = 0; i < $2; i++)); do out+=("$1"); done
	echo "${out[*]}"
}

# Prints a records array, oldest first. Each list holds one value per round, separated by spaces; a blocking
# value of `null` is a Rethink round (no code review, null counts). Approach letters: q questionable, s sound,
# r rethink, - skipped. Round K has head "sha<K>".
records() { # blocking critical ready approach-letters
	jq -cn --arg b "$1" --arg c "$2" --arg r "$3" --arg a "$4" '
		($b | split(" ")) as $b | ($c | split(" ")) as $c | ($r | split(" ")) as $r | ($a | split("")) as $a
		| {q: "questionable", s: "sound", r: "rethink", "-": "skipped"} as $approach
		| [range(0; $b | length) as $i | {
			round: ($i + 1),
			head_sha: "sha\($i + 1)",
			approach: $approach[$a[$i]],
			ready: $r[$i],
			code_review: ($b[$i] != "null"),
			counts: (if $b[$i] == "null" then {open_blocking: null, critical: null}
				else {open_blocking: ($b[$i] | tonumber), critical: ($c[$i] | tonumber)} end)
		}]'
}

# Labels as letters: e early, c converging, R ready, n nit loop, C churning, - rethink.
letters() { # records-json [params-json]
	jq -r -L "$LIB_DIR" --argjson p "${2:-null}" 'include "loop";
		loop_labels($p) | map({early: "e", converging: "c", ready: "R", "nit-loop": "n", churning: "C", rethink: "-"}[.])
		| join("")' <<<"$1"
}

# The next round for which the decision on the history so far first says stop, or "-".
stop_round() { # records-json [params-json]
	jq -r -L "$LIB_DIR" --argjson p "${2:-null}" 'include "loop";
		[range(0; length + 1) as $k | .[:$k] | loop_decide($p; null; "new"; false)
			| select(.decision == "stop") | .next_round] | .[0] // "-"' <<<"$1"
}

first_bad() { # letters
	local i
	for ((i = 0; i < ${#1}; i++)); do
		[[ "${1:i:1}" == [nC] ]] && {
			echo $((i + 1))
			return
		}
	done
	echo -
}

# One row of the calibration table: labels by round, the first warn round, the stop round, and the decision on
# the full history (decision, flags, suggestion).
calib() { # name blocking critical ready approach lines files labels warn stop decision flags suggestion
	local recs size labels got
	recs=$(records "$2" "$3" "$4" "$5")
	size=$(jq -cn --argjson l "$6" --argjson f "$7" '{lines: $l, files: $f}')
	labels=$(letters "$recs")
	eq "$1 labels" "$labels" "$8"
	eq "$1 warn" "$(first_bad "$labels")" "$9"
	eq "$1 stop" "$(stop_round "$recs")" "${10}"
	got=$(loop_decide_json "$recs" "$size" new false)
	eq "$1 decision" "$(jq -r '.decision' <<<"$got")" "${11}"
	eq "$1 flags" "$(jq -r '.flags | join(" ")' <<<"$got")" "${12}"
	eq "$1 suggestion" "$(jq -r '.suggestion // "-"' <<<"$got")" "${13}"
	eq "$1 next round" "$(jq -r '.next_round' <<<"$got")" "$(($(jq 'length' <<<"$recs") + 1))"
}

SETTLE="Settle the approach before the next round: answer the approach questions, or rethink"
SPLIT="Split the PR: each part converges on its own"
DECIDE="Look at what keeps coming back, and decide it with the author before the next round"
APPROVE="Approve, and file the remaining findings as follow-ups"

calib "skills#813" "9 12 8 10 8 8 8 9 9 7 8 8 null 10" "2 1 2 1 2 2 2 2 4 2 2 3 - 3" "$(rep no 14)" \
	qqqqqqqqqqqqrq 4476 66 eeCCCCCCCCCC-C 3 5 stop "approach-stuck too-big" "$SETTLE"
calib "skills#823" "9 7" "2 2" "no no" qq 3154 62 ee - - run "too-big" -
calib "skills#764" "5 3 2" "0 0 0" "no no no" --- 522 8 eec - - run "" -
calib "skills#763" "3 2 3" "0 0 0" "no no no" --- 692 21 een 3 - warn "" "$APPROVE"
calib "of1-labs#331" "4 8" "0 2" "no no" -- 3230 53 ee - - run "too-big" -
calib "of1-labs#512" "5 2 2 1 0 1 1 0" "$(rep 0 8)" \
	"$(rep yes-with-fixes 4) yes yes-with-fixes yes-with-fixes yes" qqqqqqqq 1227 18 eeccRccR - - run \
	"approach-stuck too-big" -
calib "of1-labs#504" "1 1 3 2 3 3" "$(rep 0 6)" "$(rep yes-with-fixes 6)" ssssss 717 17 eennnn 3 5 stop "" "$APPROVE"
calib "of1-labs#486" "1 0 1 0" "0 0 0 0" "$(rep yes-with-fixes 3) yes" ssss 201 14 eRcR - - run "" -
calib "of1-labs#460" "5 10 9 2 1 0" "0 2 3 0 0 0" "no no no yes-with-fixes yes-with-fixes yes" ---sss 7373 58 \
	eeCccR 3 - run "too-big" -
calib "of1-labs#466" "3 5 6 0" "0 0 1 0" "no no no yes" ---s 2417 15 eeCR 3 - run "too-big" -
calib "of1-labs#473" "4 3 10 6 3" "0 0 3 1 0" "$(rep no 5)" ----q 3229 63 eeCCc 3 5 run "too-big" -
calib "of1-labs#505" "3 0" "0 0" "yes-with-fixes yes" ss 1564 19 eR - - run "too-big" -

# The decision order and the stop's lift.
r813=$(records "9 12 8 10 8 8 8 9 9 7 8 8 null 10" "2 1 2 1 2 2 2 2 4 2 2 3 - 3" "$(rep no 14)" qqqqqqqqqqqqrq)
big='{"lines":4476,"files":66}'
got=$(loop_decide_json "$r813" "$big" sha14 false)
eq "nothing-new beats stop" "$(jq -r '.decision' <<<"$got")" nothing-new
eq "nothing-new reason" "$(jq -r '.reason' <<<"$got")" "no new commits since round 14"
got=$(loop_decide_json "$r813" "$big" sha13 false)
eq "an older head is not nothing-new" "$(jq -r '.decision' <<<"$got")" stop
got=$(loop_decide_json "$r813" "$big" new true)
eq "lifted turns a stop into a warn" "$(jq -r '.decision' <<<"$got")" warn
eq "Rethink round skipped in the stop" "$(jq -r '.reason' <<<"$(loop_decide_json "$r813" "$big" new false)")" \
	"churning in rounds 12 and 14"
eq "series with a Rethink null" "$(jq -c '.series' <<<"$got")" "[9,12,8,10,8,8,8,9,9,7,8,8,null,10]"
eq "label is the last code-review label" "$(jq -r '.label' <<<"$got")" churning

got=$(loop_decide_json '[]' '{"lines":10,"files":1}' new false)
eq "empty history" "$(jq -c '[.decision, .next_round, .label, .labels, .series, .flags, .suggestion]' <<<"$got")" \
	'["run",1,null,[],[],[],null]'
eq "empty history ignores head" "$(jq -r '.decision' <<<"$(loop_decide_json '[]' '{}' '' false)")" run

# A Rethink-only history has no label.
rethink=$(records "null" "-" "unknown" r)
got=$(loop_decide_json "$rethink" '{"lines":1,"files":1}' new false)
eq "Rethink-only history" "$(jq -c '[.decision, .label, .labels, .series]' <<<"$got")" '["run",null,["rethink"],[null]]'

# Same head as a Rethink-only last round: nothing new for a full run, but a code-review-only run has work to do.
eq "Rethink on this head: nothing new" "$(loop_decide_json "$rethink" '{}' sha1 false | jq -r .decision)" nothing-new
eq "Rethink on this head, skip_approach: run" \
	"$(loop_decide_json "$rethink" '{}' sha1 false '{"skip_approach":true}' | jq -r .decision)" run
eq "code review on this head, skip_approach: still nothing new" \
	"$(loop_decide_json "$(records "2" "0" "no" s)" '{}' sha1 false '{"skip_approach":true}' | jq -r .decision)" nothing-new

# A Rethink round between two bad rounds neither breaks nor extends the run.
recs=$(records "9 12 null 8" "1 1 - 1" "no no unknown no" ssrs)
eq "Rethink between rounds keeps B(K-2)" "$(letters "$recs")" "ee-C"
recs=$(records "9 12 8 null 10" "1 1 1 - 1" "no no no unknown no" sssrs)
eq "Rethink does not break a bad run" "$(stop_round "$recs")" 6
recs=$(records "9 12 8 null" "1 1 1 -" "no no no unknown" sssr)
eq "Rethink does not extend a bad run" "$(jq -r '.decision' <<<"$(loop_decide_json "$recs" '{}' new false)")" warn

# Parameters override the defaults.
r763=$(records "3 2 3" "0 0 0" "no no no" ---)
eq "min_rounds 2" "$(letters "$r763" '{"min_rounds":2}')" enn
eq "min_rounds 2 stop" "$(stop_round "$r763" '{"min_rounds":2}')" 4
eq "nit_max_blocking 2" "$(letters "$r763" '{"nit_max_blocking":2}')" eeC
eq "params through loop_decide_json" \
	"$(jq -r '.decision' <<<"$(loop_decide_json "$r763" '{}' new false '{"min_rounds":2}')")" stop
eq "too_big_lines 500" "$(jq -r '.flags | join(" ")' <<<"$(loop_decide_json "$r763" '{"lines":692,"files":21}' new false \
	'{"too_big_lines":500}')")" too-big
eq "stuck_rounds 2" "$(jq -r '.flags | join(" ")' <<<"$(loop_decide_json "$(records "9 7" "2 2" "no no" qr)" \
	'{}' new false '{"stuck_rounds":2}')")" approach-stuck

# Flags: approach-stuck needs the last stuck_rounds records; too-big on lines or files.
flags() { jq -r '.flags | join(" ")' <<<"$(loop_decide_json "$(records "$1" "$2" "$3" "$4")" "$5" new false)"; }
eq "approach-stuck with rethink" "$(flags "5 3 2" "0 0 0" "no no no" qrq '{}')" approach-stuck
eq "approach-stuck broken by sound" "$(flags "5 3 2" "0 0 0" "no no no" qsq '{}')" ""
eq "approach-stuck broken by skipped" "$(flags "5 3 2 1" "0 0 0 0" "no no no no" qq-q '{}')" ""
eq "too-big on lines" "$(flags "5" "0" "no" s '{"lines":801,"files":1}')" too-big
eq "not too-big at the limits" "$(flags "5" "0" "no" s '{"lines":800,"files":25}')" ""
eq "too-big on files" "$(flags "5" "0" "no" s '{"lines":1,"files":26}')" too-big

# The suggested move, one per row of the spec's table.
suggest() { jq -r '.suggestion // "-"' <<<"$(loop_decide_json "$(records "$1" "$2" "$3" "$4")" "$5" new false)"; }
eq "suggest churning + approach-stuck" "$(suggest "9 12 8" "1 1 1" "no no no" qqq '{"lines":2000,"files":40}')" "$SETTLE"
eq "suggest churning + too-big" "$(suggest "9 12 8" "1 1 1" "no no no" sss '{"lines":2000,"files":40}')" "$SPLIT"
eq "suggest churning" "$(suggest "9 12 8" "1 1 1" "no no no" sss '{"lines":100,"files":4}')" "$DECIDE"
eq "suggest nit loop" "$(suggest "3 2 3" "0 0 0" "no no no" sss '{"lines":100,"files":4}')" "$APPROVE"
eq "suggest nit loop on a big PR" "$(suggest "3 2 3" "0 0 0" "no no no" sss '{"lines":2000,"files":40}')" "$APPROVE"
eq "suggest nit loop with approach-stuck" "$(suggest "3 2 3" "0 0 0" "no no no" qqq '{"lines":2000,"files":40}')" "$APPROVE"
eq "no suggestion when converging" "$(suggest "9 6 2" "1 1 0" "no no no" qqq '{"lines":2000,"files":40}')" -

# loop_text and loop_line.
got=$(loop_decide_json "$(jq -c '.[:4]' <<<"$r813")" "$big" new false)
eq "loop_text stop" "$(loop_text "$got")" "Loop check for round 5: stop
  label     churning (rounds 3 and 4)
  blocking  9 12 8 10
  flags     approach-stuck too-big
  suggested $SETTLE
  override  --force-round"
got=$(loop_decide_json "$(jq -c '.[:3]' <<<"$r813")" "$big" new false)
eq "loop_line churning" "$(loop_line "$got")" "**Loop:** Churning · blocking 9, 12, 8 · $SETTLE"
eq "loop_text warn" "$(loop_text "$got")" "Loop check for round 4: warn
  label     churning (round 3)
  blocking  9 12 8
  flags     approach-stuck too-big
  suggested $SETTLE"
got=$(loop_decide_json "$r813" "$big" new false)
eq "loop_line skips Rethink" "$(loop_line "$got")" "**Loop:** Churning · blocking 8, 8, 10 · $SETTLE"
eq "loop_text Rethink dash" "$(loop_text "$got" | sed -n 3p)" "  blocking  9 12 8 10 8 8 8 9 9 7 8 8 - 10"
got=$(loop_decide_json "$r813" "$big" new true)
eq "loop_text lifted" "$(loop_text "$got" | sed -n 1,2p)" "Loop check for round 15: warn
  label     churning (rounds 12 and 14, stop lifted)"
got=$(loop_decide_json "$r763" '{"lines":692,"files":21}' new false)
eq "loop_line nit loop" "$(loop_line "$got")" "**Loop:** Nit loop · blocking 3, 2, 3 · $APPROVE"
got=$(loop_decide_json "$r813" "$big" sha14 false)
eq "loop_text nothing-new" "$(loop_text "$got" | sed -n '1p;5,$p')" "Loop check for round 15: nothing-new
  reason    no new commits since round 14
  suggested $SETTLE
  override  --force-round"
eq "loop_text empty" "$(loop_text "$(loop_decide_json '[]' '{}' new false)")" "Loop check for round 1: run
  label     none (no earlier rounds)
  blocking  none
  flags     none"
exit "$fail"
