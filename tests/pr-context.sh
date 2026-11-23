#!/usr/bin/env bash
# Runs write_pr_context against a stub gh and checks the files it writes.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
stub=$(mktemp -d)
sed -n '/^# ── pr context/,/^}/p' "$root/gh-pr-review" >"$stub/lib.sh"
fail=0

run() { # json -> writes into $stub/ctx
	printf '%s' "$1" >"$stub/pr.json"
	cat >"$stub/gh" <<S
#!/usr/bin/env bash
cat "$stub/pr.json"
S
	chmod +x "$stub/gh"
	rm -rf "$stub/ctx"
	PATH="$stub:$PATH" bash -c 'set -euo pipefail; source "$1"; PR_NUM=1 GH_HOST_NAME=h OWNER=o REPO=r PR_TITLE="T" PR_BODY="B"; write_pr_context "$2"' _ "$stub/lib.sh" "$stub/ctx"
}

expect() { # name file pattern
	if grep -qF -- "$3" "$stub/ctx/$2"; then echo "ok   $1"; else
		echo "FAIL $1: '$3' not in $2:"
		cat "$stub/ctx/$2"
		fail=1
	fi
}

run '{"comments":[],"reviews":[]}'
expect "body title" pr-body.md "# T"
expect "body text" pr-body.md "B"
expect "no discussion" pr-discussion.md "(no comments or review summaries)"
expect "scope is stated" pr-discussion.md "Inline review threads are not included"

run '{"comments":[{"author":{"login":"carol"},"body":"later comment","createdAt":"2026-01-03T00:00:00Z"}],
 "reviews":[{"author":{"login":"bob"},"state":"CHANGES_REQUESTED","body":"first review","submittedAt":"2026-01-01T00:00:00Z"},
            {"author":{"login":"bob"},"state":"COMMENTED","body":"","submittedAt":"2026-01-02T00:00:00Z"}]}'
expect "review header" pr-discussion.md "## bob · CHANGES_REQUESTED · 2026-01-01T00:00:00Z"
expect "comment header" pr-discussion.md "## carol · comment · 2026-01-03T00:00:00Z"
if [[ $(grep -c '^## ' "$stub/ctx/pr-discussion.md") == 2 ]]; then echo "ok   empty review skipped"; else
	echo "FAIL empty review skipped"
	fail=1
fi
if [[ $(grep -n '^## ' "$stub/ctx/pr-discussion.md" | head -1) == *bob* ]]; then echo "ok   oldest first"; else
	echo "FAIL oldest first"
	fail=1
fi
printf '#!/usr/bin/env bash\nexit 4\n' >"$stub/gh"
out=$(PATH="$stub:$PATH" bash -c 'set -euo pipefail; source "$1"; PR_NUM=1 GH_HOST_NAME=h OWNER=o REPO=r PR_TITLE=T PR_BODY=B; write_pr_context "$2"' _ "$stub/lib.sh" "$stub/ctx2" 2>&1) && rc=0 || rc=$?
if [[ $rc != 0 && "$out" == *"Error: could not fetch"* ]]; then echo "ok   gh failure is reported"; else
	echo "FAIL gh failure is reported: rc=$rc out=$out"
	fail=1
fi
exit "$fail"
