#!/usr/bin/env bash
# Runs the post block of gh-pr-review against a stub gh, under the script's own shell options.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
stub=$(mktemp -d)
{
	sed -n '/^# ── verdicts/,/^}/p' "$root/gh-pr-review"
	sed -n '/^# ── post/,$p' "$root/gh-pr-review"
} >"$stub/post.sh"
fail=0

check() { # name review author me decision approach-verdict expected-flag [code-review, default: review]
	cat >"$stub/gh" <<S
#!/usr/bin/env bash
if [[ "\$1" == api ]]; then echo "$4"; else printf '%s\\n' "\$@" | grep -x -- '--\(comment\|approve\|request-changes\)'; fi
S
	chmod +x "$stub/gh"
	local got
	got=$(PATH="$stub:$PATH" bash -c 'set -euo pipefail; POST_TO_PR=true YES=true DECISION="$1" REVIEW="$2" CODE_REVIEW="$6" PR_AUTHOR="$3" APPROACH_VERDICT="$5" PR_NUM=1 GH_HOST_NAME=h OWNER=o REPO=r; source "$4"' _ "$5" "$2" "$3" "$stub/post.sh" "$6" "${8-$2}" 2>&1 | grep -- '^--') || got="(exit failed)"
	if [[ "$got" == "$7" ]]; then echo "ok   $1"; else
		echo "FAIL $1: got '$got', want '$7'"
		fail=1
	fi
}

check "no" '**Ready to merge?** No' bob me '' '' --request-changes
check "yes" '**Ready to merge?** Yes' bob me '' '' --approve
check "yes with fixes" '**Ready to merge?** Yes with fixes' bob me '' '' --comment
check "bold value" '**Ready to merge?** **No**' bob me '' '' --request-changes
check "missing" 'no assessment here' bob me '' '' --comment
check "quoted yes then final no" $'Ready to merge? Yes\n**Ready to merge?** No' bob me '' '' --request-changes
check "own PR" '**Ready to merge?** Yes' me me '' '' --comment
check "explicit flag" 'x' bob me request-changes '' --request-changes
check "rethink" '**Approach:** Rethink' bob me '' rethink --request-changes
check "questionable + yes" '**Ready to merge?** Yes' bob me '' questionable --approve
check "rethink + explicit" 'x' bob me comment rethink --comment
check "rethink own PR" 'x' me me '' rethink --comment
check "approach quotes merge" $'quote: ready to merge yes\n**Ready to merge?** No' bob me '' sound --request-changes
check "approach line cannot approve" $'**Approach:** Questionable\nReady to merge: yes' bob me '' questionable --comment 'review without a verdict'
check "yes comma fixes" '**Ready to merge?** Yes, with fixes' bob me '' '' --comment
check "yes paren fixes" '**Ready to merge?** Yes (with fixes)' bob me '' '' --comment
check "yes dash fixes" '**Ready to merge?** Yes — with fixes' bob me '' '' --comment
check "no dash reason" '**Ready to merge?** No — see Critical' bob me '' '' --request-changes
exit "$fail"
