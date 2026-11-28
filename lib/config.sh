#!/usr/bin/env bash
# The optional config file. Functions only.

# Prints the config file's path: ${XDG_CONFIG_HOME:-$HOME/.config}/gh-pr-review/config.json.
config_file() {
	echo "${XDG_CONFIG_HOME:-$HOME/.config}/gh-pr-review/config.json"
}

# Prints the value at <jq-path> in the config file (a string raw, anything else as compact JSON), or <default> when
# the file is missing or the value is missing, null or "". A file that is not one JSON object is an error that names it.
config_get() { # <jq-path> <default>
	local file
	file=$(config_file)
	if [[ ! -e "$file" ]]; then
		printf '%s\n' "$2"
		return 0
	fi
	if ! jq -se 'length == 1 and (.[0] | type) == "object"' "$file" >/dev/null 2>&1; then
		echo "Error: invalid config file (not one JSON object): $file" >&2
		return 1
	fi
	jq -rc --arg d "$2" "($1) as \$v | if \$v == null or \$v == \"\" then \$d else \$v end" "$file" 2>/dev/null || {
		echo "Error: could not read $1 from the config file: $file" >&2
		return 1
	}
}
