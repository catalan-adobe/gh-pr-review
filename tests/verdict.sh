#!/usr/bin/env bash
# Checks last_verdict, the shared parser for "**Approach:**" and "**Ready to merge?**" lines.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib=$(mktemp)
sed -n '/^# ── verdicts/,/^}/p' "$root/gh-pr-review" >"$lib"
# shellcheck source=/dev/null
source "$lib"
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
exit "$fail"
