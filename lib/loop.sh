#!/usr/bin/env bash
# The loop check: wraps lib/loop.jq for the review run and the rounds subcommand. Functions only.

# Prints the decision JSON for the next round: {next_round, labels, label, flags, series, decision, reason,
# suggestion}. The records go through stdin, so a long history never hits the argument limit.
loop_decide_json() { # <records-json> <size-json> <head> <lifted:true|false> [params-json]
	local params="${5:-}"
	[[ -n "$params" ]] || params='{}'
	jq -c -L "${LIB_DIR:?}" --argjson size "$2" --arg head "$3" --argjson lifted "$4" \
		--argjson p "$params" 'include "loop"; loop_decide($p; $size; $head; $lifted)' <<<"$1"
}

# Prints the diagnosis for a person, for example:
#   Loop check for round 5: stop
#     label     churning (rounds 3 and 4)
#     blocking  9 12 8 10
#     flags     approach-stuck too-big
#     suggested Settle the approach before the next round: answer the approach questions, or rethink
#     override  --force-round
loop_text() { # <decision-json>
	jq -r -L "${LIB_DIR:?}" 'include "loop";
		[range(0; .labels | length) as $i | select(.labels[$i] != "rethink") | $i] as $cr
		| (if ($cr | length) > 1 then .labels[$cr[-2]] else null end) as $prev
		| "Loop check for round \(.next_round): \(.decision)",
		"  label     " + (
			if .label == null then "none (no earlier rounds)"
			elif (.label | loop_bad) and ($prev | loop_bad) then
				"\(if $prev == .label then .label else "\($prev) and \(.label)" end) (rounds \($cr[-2] + 1) and \($cr[-1] + 1)"
				+ (if .decision == "warn" then ", stop lifted)" else ")" end)
			else "\(.label) (round \($cr[-1] + 1))"
			end),
		"  blocking  " + (if (.series | length) == 0 then "none" else .series | map(. // "-" | tostring) | join(" ") end),
		"  flags     " + (if (.flags | length) == 0 then "none" else .flags | join(" ") end),
		(select(.decision == "nothing-new") | "  reason    \(.reason)"),
		(select(.suggestion != null) | "  suggested \(.suggestion)"),
		(select(.decision == "stop" or .decision == "nothing-new") | "  override  --force-round")' <<<"$1"
}

# Prints the loop line for the posted body: **Loop:** Churning · blocking 9, 12, 8 · <suggestion>
# The blocking values are the last three of the code-review rounds.
loop_line() { # <decision-json>
	jq -r -L "${LIB_DIR:?}" 'include "loop";
		"**Loop:** \(.label // "none" | loop_label_name) · blocking "
		+ ([.series[] | select(. != null)] | .[-3:] | map(tostring) | join(", "))
		+ (if .suggestion == null then "" else " · \(.suggestion)" end)' <<<"$1"
}
