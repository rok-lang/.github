# shellcheck shell=sh
# Readers of release/pipeline.json. Needs jq.

# manifest_component <manifest> <id>: the component as JSON.
manifest_component() {
	jq -ce --arg id "$2" '.components[] | select(.id == $id)' "$1" || {
		echo "::error::no component \"$2\" in $1" >&2
		return 1
	}
}

# manifest_ids <manifest> [<kind>]: component ids, in manifest order.
manifest_ids() {
	jq -r --arg k "${2:-}" '.components[] | select($k == "" or .kind == $k) | .id' "$1"
}

# manifest_vars <version> [<pinned>] [<extra json>]: placeholder values.
manifest_vars() {
	_mv_x=${3:-}
	[ -n "$_mv_x" ] || _mv_x='{}'
	jq -cn --arg v "$1" --arg p "${2:-}" --argjson x "$_mv_x" '
		{version: $v, series: ($v | capture("^(?<s>[0-9]+\\.[0-9]+)").s)}
		+ (if $p == "" then {} else {pinned: $p} end) + $x'
}

# manifest_expand <string> <vars json>: replace {name}; an unknown name
# is an error, so a check never runs against a literal "{pinned}".
manifest_expand() {
	jq -rn --arg s "$1" --argjson v "$2" '
		[$s | scan("\\{([a-z_]+)\\}") | .[0] | select(in($v) | not)] as $miss
		| if ($miss | length) > 0 then
			error("\($s) uses {\($miss[0])}, which this check was not given")
		else
			$s | gsub("\\{(?<k>[a-z_]+)\\}"; $v[.k])
		end'
}
