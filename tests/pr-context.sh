#!/usr/bin/env bash
# Runs write_pr_context against a stub gh and checks the files it writes.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
stub=$(mktemp -d)
sed -n '/^# ── pr context/,/^}/p' "$root/gh-pr-review" >"$stub/lib.sh"
no_threads='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
fail=0

run() { # pr-json [threads-json] [graphql-exit-code] -> writes into $stub/ctx, sets out and rc
	printf '%s' "$1" >"$stub/pr.json"
	printf '%s' "${2:-$no_threads}" >"$stub/threads.json"
	cat >"$stub/gh" <<S
#!/usr/bin/env bash
case "\$*" in
*--slurp*) echo "unknown flag: --slurp" >&2; exit 1 ;;
*graphql*--paginate* | *--paginate*graphql*) [[ "${3:-0}" == 0 ]] || exit ${3:-0}; cat "$stub/threads.json" ;;
*graphql*) head -c 1 "$stub/threads.json" ;;
*) cat "$stub/pr.json" ;;
esac
S
	chmod +x "$stub/gh"
	rm -rf "$stub/ctx"
	out=$(PATH="$stub:$PATH" bash -c 'set -euo pipefail; source "$1"; PR_NUM=1 GH_HOST_NAME=h OWNER=o REPO=r PR_TITLE="T" PR_BODY="B"; write_pr_context "$2"' _ "$stub/lib.sh" "$stub/ctx" 2>&1) && rc=0 || rc=$?
}

expect() { # name file pattern
	if grep -qF -- "$3" "$stub/ctx/$2"; then echo "ok   $1"; else
		echo "FAIL $1: '$3' not in $2:"
		cat "$stub/ctx/$2"
		fail=1
	fi
}

expect_not() { # name file pattern
	if ! grep -qF -- "$3" "$stub/ctx/$2"; then echo "ok   $1"; else
		echo "FAIL $1: '$3' unexpectedly in $2:"
		cat "$stub/ctx/$2"
		fail=1
	fi
}

run '{"comments":[],"reviews":[]}'
expect "body title" pr-body.md "# T"
expect "body text" pr-body.md "B"
expect "no discussion" pr-discussion.md "(no comments or review summaries)"
expect "no threads" pr-discussion.md "(no inline review threads)"

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

thread() { # path line originalLine isResolved isOutdated -> one thread node with two comments
	printf '{"path":"%s","line":%s,"originalLine":%s,"isResolved":%s,"isOutdated":%s,"comments":{"totalCount":2,"nodes":[
	 {"author":{"login":"alice"},"body":"finding on %s\\nsecond line","createdAt":"2026-01-01T00:00:00Z"},
	 {"author":{"login":"bob"},"body":"reply on %s","createdAt":"2026-01-02T00:00:00Z"}]}}' "$@" "$1" "$1"
}
page() { printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[%s]}}}}}' "$1"; }
run '{"comments":[],"reviews":[]}' \
	"$(page "$(thread a.js 12 10 false false),$(thread b.js 3 3 true false)")$(page "$(thread c.js null 7 false true)")"
expect "open thread header" pr-discussion.md "## a.js:12 · open"
expect "open thread keeps every comment" pr-discussion.md "reply on a.js"
expect "open thread names the author" pr-discussion.md "alice"
expect "resolved thread header" pr-discussion.md "## b.js:3 · resolved"
expect "resolved thread keeps the start of the finding" pr-discussion.md "finding on b.js second line"
expect "resolved thread counts replies" pr-discussion.md "(1 reply)"
expect_not "resolved thread drops replies" pr-discussion.md "reply on b.js"
expect "outdated thread uses the original line" pr-discussion.md "## c.js:7 · outdated"
big='{"path":"d.js","line":1,"originalLine":1,"isResolved":true,"isOutdated":false,"comments":{"totalCount":120,"nodes":[{"author":{"login":"alice"},"body":"long debate","createdAt":"2026-01-01T00:00:00Z"}]}}'
run '{"comments":[],"reviews":[]}' "$(page "$big")"
expect "reply count uses the total, not the fetched page" pr-discussion.md "(119 replies)"

run '{"comments":[],"reviews":[]}' "" 4
if [[ $rc != 0 && "$out" == *"Error: could not fetch"* ]]; then echo "ok   thread fetch failure is reported"; else
	echo "FAIL thread fetch failure is reported: rc=$rc out=$out"
	fail=1
fi

printf '#!/usr/bin/env bash\nexit 4\n' >"$stub/gh"
out=$(PATH="$stub:$PATH" bash -c 'set -euo pipefail; source "$1"; PR_NUM=1 GH_HOST_NAME=h OWNER=o REPO=r PR_TITLE=T PR_BODY=B; write_pr_context "$2"' _ "$stub/lib.sh" "$stub/ctx2" 2>&1) && rc=0 || rc=$?
if [[ $rc != 0 && "$out" == *"Error: could not fetch"* ]]; then echo "ok   gh failure is reported"; else
	echo "FAIL gh failure is reported: rc=$rc out=$out"
	fail=1
fi
exit "$fail"
