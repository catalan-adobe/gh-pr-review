#!/usr/bin/env bash
# Checks last_verdict, the shared parser for "**Approach:**" and "**Ready to merge?**" lines.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/verdicts.sh
source "$root/lib/verdicts.sh"
# The script must reach its end: Bash 3.2 can stop on an error inside an EXIT trap with status 0.
finished=false
trap '[[ $finished == true ]] || { echo "FAIL stopped before the end"; exit 1; }' EXIT
fail=0

check() { # name label text expected
	local got
	got=$(last_verdict "$2" "$3") || got="(exit failed)"
	if [[ "$got" == "$4" ]]; then echo "ok   $1"; else
		echo "FAIL $1: got '$got', want '$4'"
		fail=1
	fi
}

check "plain" 'Approach' '**Approach:** Rethink' rethink
check "bold+period" 'Approach' '**Approach:** **questionable**.' questionable
check "last wins" 'Approach' $'**Approach:** Sound | Questionable | Rethink\n**Approach:** Sound' sound
check "missing" 'Approach' 'no verdict here' ''
check "merge label" 'ready to merge' '**Ready to merge?** Yes with fixes' 'yes with fixes'
check "mid-line mention ignored" 'Approach' $'**Approach:** Rethink\nThe approach: sound overall' rethink
check "trailing reason kept" 'Approach' '**Approach:** Rethink — the shared client exists' 'rethink — the shared client exists'
check "trailing dash reason merge kept" 'ready to merge' '**Ready to merge?** No — see Critical' 'no — see critical'
check "comma qualifier kept" 'ready to merge' '**Ready to merge?** Yes, with fixes' 'yes, with fixes'
check "paren qualifier kept" 'ready to merge' '**Ready to merge?** Yes (with fixes)' 'yes (with fixes)'

check "approach notes prose ignored" 'Approach' $'**Approach:** Rethink\n\nApproach notes: use the existing shared client.' 'rethink'
check "approach rationale prose ignored" 'Approach' $'**Approach:** Sound\n\n**Approach rationale:** Rethink is unnecessary' 'sound'
check "merge criteria prose ignored" 'ready to merge' $'**Ready to merge?** No\nReady to merge criteria: yes' 'no'
check "plain label without bold" 'Approach' 'Approach: Questionable' 'questionable'
finished=true
exit "$fail"
