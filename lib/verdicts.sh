#!/usr/bin/env bash
# Verdict lines shared by the review run, the records and the tests. Functions only.

# Lowercased value of the last "<label>:" or "<label>?" line (markdown marks allowed around the label).
# The delimiter must follow the label, so prose such as "Approach notes: …" never matches.
last_verdict() {
	{ grep -iE "^[[:space:]*_>-]*$1[*_]*[?:]" <<<"$2" || true; } | tail -n1 |
		sed 's/^[^?:]*[?:]//; s/[*_`.]//g; s/^ *//; s/ *$//' | tr '[:upper:]' '[:lower:]'
}
