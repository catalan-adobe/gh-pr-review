# The loop rules: a label per round, flags, and the decision for the next round.
# Input: the array of round records, oldest first. $p: parameters, merged over loop_defaults.
# Load with: jq -L "$LIB_DIR" 'include "loop"; …'

def loop_defaults:
  {min_rounds: 3, converge_ratio: 0.7, nit_max_blocking: 3, too_big_lines: 800, too_big_files: 25, stuck_rounds: 3};

def loop_params($p): loop_defaults + ($p // {});

# A record without a code review (a Rethink-only round) has no blocking count.
def loop_code_review: .code_review != false;

# Blocking count of one record, null for a Rethink round.
def loop_blocking: if loop_code_review then (.counts.open_blocking // 0) else null end;

def loop_bad: . == "nit-loop" or . == "churning";

# One label per record. N and B(K−2) count code-review rounds only, so a Rethink round neither breaks nor extends
# a run of bad rounds.
def loop_labels($p):
  loop_params($p) as $q
  | . as $records
  | reduce range(0; length) as $i ({b: [], labels: []};
    $records[$i] as $r
    | if ($r | loop_code_review) then
      ($r | loop_blocking) as $b
      | (.b + [$b]) as $bs
      | ($bs | length) as $n
      | (if $n >= 3 then $bs[$n - 3] else null end) as $b2
      | .b = $bs
      | .labels += [
        if $b == 0 and ($r.ready == "yes" or $r.ready == "yes-with-fixes") then "ready"
        elif $n < $q.min_rounds then "early"
        elif $b <= 1 or ($b2 != null and $b <= $q.converge_ratio * $b2 + 1e-9) then "converging"
        elif $b <= $q.nit_max_blocking and (($r.counts.critical // 0) == 0) then "nit-loop"
        else "churning"
        end
      ]
      else .labels += ["rethink"]
      end)
  | .labels;

# approach-stuck: a questionable or rethink approach in each of the last stuck_rounds records.
# too-big: $size ({lines, files}) above either threshold.
def loop_flags($p; $size):
  loop_params($p) as $q
  | (if $q.stuck_rounds > 0 and length >= $q.stuck_rounds
      and (.[length - $q.stuck_rounds:] | all(.approach == "questionable" or .approach == "rethink"))
    then ["approach-stuck"] else [] end)
  + (if (($size.lines // 0) > $q.too_big_lines) or (($size.files // 0) > $q.too_big_files)
    then ["too-big"] else [] end);

# The suggested move, from the label and the flags. Only a Nit loop or Churning label gets one.
def loop_suggestion($label; $flags):
  if ($label | loop_bad) | not then null
  elif $flags | index("approach-stuck") then
    "Settle the approach before the next round: answer the approach questions, or rethink"
  elif $flags | index("too-big") then "Split the PR: each part converges on its own"
  elif $label == "churning" then
    "Look at what keeps coming back, and decide it with the author before the next round"
  else "Approve, and file the remaining findings as follow-ups"
  end;

# The decision for the next round: nothing-new, then stop, then warn, then run.
# $head: the PR's head SHA now. $lifted: true when something since the last round lifts a stop.
def loop_decide($p; $size; $head; $lifted):
  . as $records
  | loop_labels($p) as $labels
  | loop_flags($p; $size) as $flags
  | [range(0; length) | select($labels[.] != "rethink")] as $cr
  | (if ($cr | length) > 0 then $labels[$cr[-1]] else null end) as $label
  | (if ($cr | length) > 1 then $labels[$cr[-2]] else null end) as $prev
  | {
    next_round: (length + 1),
    labels: $labels,
    label: $label,
    flags: $flags,
    series: map(loop_blocking),
    suggestion: loop_suggestion($label; $flags)
  }
  + if length > 0 and ($head // "") != "" and $records[-1].head_sha == $head then
    {decision: "nothing-new", reason: "no new commits since round \(length)"}
  elif ($label | loop_bad) and ($prev | loop_bad) and $lifted != true then
    {decision: "stop",
      reason: "\(if $prev == $label then $label else "\($prev) and \($label)" end) in rounds \($cr[-2] + 1) and \($cr[-1] + 1)"}
  elif ($label | loop_bad) and ($prev | loop_bad) then
    {decision: "warn", reason: "\($label) in rounds \($cr[-2] + 1) and \($cr[-1] + 1), stop lifted"}
  elif $label | loop_bad then
    {decision: "warn", reason: "\($label) in round \($cr[-1] + 1)"}
  elif $label == null then
    {decision: "run", reason: "no earlier rounds"}
  else
    {decision: "run", reason: "\($label) in round \($cr[-1] + 1)"}
  end
  | {next_round, labels, label, flags, series, decision, reason, suggestion};

# "Nit loop", "Churning", … for a person.
def loop_label_name: if . == "nit-loop" then "Nit loop" else (.[:1] | ascii_upcase) + .[1:] end;
