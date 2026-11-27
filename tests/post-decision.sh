#!/usr/bin/env bash
# Runs the post block of gh-pr-review against a stub gh, under the script's own shell options. The run has a valid
# round record unless a test passes "none", "broken" (the final record build fails) or "empty" (round.json is
# empty by the time the post block runs).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
stub=$(mktemp -d)
{
	cat "$root"/lib/*.sh
	sed -n '/^# ── post/,$p' "$root/gh-pr-review"
} >"$stub/post.sh"
fail=0

check() { # name review author me decision approach-verdict expected-flag [code-review, default: review] [record: none]
	cat >"$stub/gh" <<S
#!/usr/bin/env bash
case "\$*" in
*"--method POST"*)
	while [[ \$# -gt 0 ]]; do [[ "\$1" == --input ]] && cp "\$2" "$stub/posted.json" &&
		jq -r '"--" + (.event | ascii_downcase | sub("_"; "-"))' "\$2" >"$stub/flag"; shift; done ;;
*/reviews*) echo '[]' ;;
*"pr view"*) echo '{"headRefOid":"h1"}' ;;
api*) echo "$4" ;;
esac
S
	chmod +x "$stub/gh"
	local got record="$stub/round.json"
	rm -f "$stub/flag" "$stub/posted.json"
	echo '{"schema":1,"round":1,"counts":{"open_blocking":0}}' >"$record"
	[[ "${9:-}" == none ]] && record=""
	# broken: the record is there when the run decides, and the final build of the posted record fails.
	[[ "${9:-}" == broken ]] && echo 'not json' >"$record"
	[[ "${9:-}" == empty ]] && : >"$record"
	PATH="$stub:$PATH" LIB_DIR="$root/lib" bash -c 'set -euo pipefail; POST_TO_PR=true YES=true DECISION="$1" REVIEW="$2" CODE_REVIEW="$6" PR_AUTHOR="$3" APPROACH_VERDICT="$5" PR_NUM=1 GH_HOST_NAME=h OWNER=o REPO=r ROUND=1 HEAD_SHA=h1 RECORD_FILE="$7" SESSION_DIR="$8"; source "$4"' _ "$5" "$2" "$3" "$stub/post.sh" "$6" "${8-$2}" "$record" "$stub" >"$stub/out.log" 2>&1 &&
		got=$(cat "$stub/flag" 2>/dev/null) || got="(exit failed)"
	if [[ "$got" == "$7" ]]; then echo "ok   $1"; else
		echo "FAIL $1: got '$got', want '$7'"
		tail -3 "$stub/out.log"
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
check "no record: a bare yes comments" '**Ready to merge?** Yes' bob me '' '' --comment '**Ready to merge?** Yes' none
check "no record: an explicit approve stays" 'x' bob me approve '' --approve x none
check "final record build fails: a bare yes comments" '**Ready to merge?** Yes' bob me '' '' --comment '**Ready to merge?** Yes' broken
check "final record build fails: an explicit approve stays" 'x' bob me approve '' --approve x broken
check "empty record before posting: a bare yes comments" '**Ready to merge?** Yes' bob me '' '' --comment '**Ready to merge?** Yes' empty
if jq -e '.body | contains("gh-pr-review:round") | not' "$stub/posted.json" >/dev/null; then
	echo "ok   empty record before posting: no marker"
else
	echo "FAIL empty record before posting: a marker was posted"
	fail=1
fi
check "empty record before posting: an explicit approve stays" 'x' bob me approve '' --approve x empty
check "no dash reason" '**Ready to merge?** No — see Critical' bob me '' '' --request-changes
exit "$fail"
