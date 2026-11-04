#!/bin/sh
# Cross-check release/pipeline.json beyond its JSON Schema.
#
#   manifest-check.sh [--live] <manifest>
#
# Offline: unique ids, one org, known placeholders, {pinned} only with a
# pin, deploy only on sites, health URLs that parse, smoke runners named.
# --live (gh, GH_TOKEN) also asks GitHub: every repo exists, every
# checks[] workflow is there, every pin file parses as a toolchain pin,
# and the toolchain's targets file and smoke runners agree. A private
# repo the token cannot see is a notice, not an error.
set -eu
lib=$(cd "$(dirname "$0")" && pwd)
. "$lib/retry.sh"
. "$lib/gh.sh"

live=
if [ "${1:-}" = --live ]; then
	live=1
	shift
fi
[ $# -eq 1 ] || {
	echo "usage: manifest-check.sh [--live] <manifest>" >&2
	exit 2
}
m=$1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
errors=0
err() {
	echo "::error file=$m::$*" >&2
	errors=$((errors + 1))
}

jq -e . "$m" > /dev/null 2>&1 || {
	err "not valid JSON"
	exit 1
}

# One line per finding; empty when the manifest is consistent.
jq -r '
	def strings_of: [.. | strings];
	(.components | group_by(.id)[] | select(length > 1) | "id \(.[0].id) is used \(length) times"),
	(.components[] | select(.repo | startswith("rok-lang/") | not) | "\(.id): repo \(.repo) is outside rok-lang"),
	(.components[] | . as $c | strings_of[] | scan("\\{([a-z_]+)\\}") | .[0]
		| select(IN("version", "series", "prev", "pinned", "editor_version") | not)
		| "\($c.id): unknown placeholder {\(.)}"),
	(.components[] | select(.pin == null) | . as $c | [.health[]? | .url, .expect] | map(select(contains("{pinned}")))
		| select(length > 0) | "\($c.id): uses {pinned} but has no pin"),
	(.components[] | select(.deploy != null and .kind != "site") | "\(.id): deploy is for sites, not \(.kind)"),
	(.components[] | select(.gate != null and .next != true) | "\(.id): gate without next: true has nothing to gate on"),
	(.components[] | . as $c | .health[]? | .url
		| select(test("^(https://[a-z0-9.-]+\\.[a-z]+(/[^ ]*)?|index-lag:[a-z0-9.-]+\\.[a-z]+|compile:[a-z0-9.-]+\\.[a-z]+)$") | not)
		| "\($c.id): health URL \(.) does not parse"),
	(.components[] | . as $c | .health[]? | select(.url | test("/healthz$")) | .expect
		| select(test("^[a-z_]+ [^ ]+$") | not)
		| "\($c.id): a /healthz check expects \"key value\", not \"\(.)\"")
' "$m" > "$tmp/offline"
while IFS= read -r line; do err "$line"; done < "$tmp/offline"

if [ -n "$live" ]; then
	jq -r '[.toolchain.repo] + [.components[].repo] | unique[]' "$m" > "$tmp/repos"
	: > "$tmp/hidden"
	while read -r r; do
		rc=0
		gh_repo_exists "$r" < /dev/null 2> /dev/null || rc=$?
		case $rc in
		0) ;;
		1)
			if [ "$(jq -r --arg r "$r" '[.components[] | select(.repo == $r) | .kind] | all(. == "infra")' "$m")" = true ]; then
				echo "::notice::$r is not visible to this token (private); its checks are skipped"
				echo "$r" >> "$tmp/hidden"
			else
				err "repo $r does not exist"
			fi
			;;
		*) err "cannot tell whether $r exists (GitHub API failing)" ;;
		esac
	done < "$tmp/repos"

	jq -r '.components[] | .repo as $r | .checks[]? | "\($r) \(.)"' "$m" | sort -u > "$tmp/checks"
	while read -r r w; do
		! grep -qx "$r" "$tmp/hidden" || continue
		gh_api GET "repos/$r/contents/.github/workflows/$w" < /dev/null > /dev/null 2>&1 ||
			err "$r has no .github/workflows/$w (listed in checks)"
	done < "$tmp/checks"

	jq -r '.components[] | select(.pin) | "\(.id) \(.repo) \(.pin.file) \(.pin.ref)"' "$m" > "$tmp/pins"
	while read -r id r f ref; do
		if ! gh_file "$r" "$f" "$ref" < /dev/null > "$tmp/pin" 2> /dev/null; then
			err "$id: $r has no $f on $ref"
			continue
		fi
		p=$("$lib/toolchain.sh" pin "$tmp/pin" 2>&1) || {
			p=${p#::error::install-rok: }
			err "$id: $r $f@$ref${p#"$tmp/pin"}"
			continue
		}
		k=$("$lib/toolchain.sh" kind "$p" 2>&1) || {
			err "$id: $r $f@$ref: ${k#::error::install-rok: }"
			continue
		}
		[ "$k" = series ] || echo "::notice::$id pins $k toolchain \"$p\"; a series pin follows patches by itself"
	done < "$tmp/pins"

	tr=$(jq -r .toolchain.repo "$m")
	tf=$(jq -r .toolchain.targets_file "$m")
	if gh_file "$tr" "$tf" < /dev/null > "$tmp/targets" 2> /dev/null && jq -e .targets "$tmp/targets" > /dev/null 2>&1; then
		for s in $(jq -r '.toolchain.smoke[]' "$m"); do
			jq -e --arg s "$s" 'any(.targets[]; .["runs-on"] == $s)' "$tmp/targets" > /dev/null ||
				err "smoke runner $s is not the runs-on of any target in $tr $tf"
		done
	else
		err "$tr has no readable $tf"
	fi
	rw=$(jq -r .toolchain.release_workflow "$m")
	gh_api GET "repos/$tr/contents/.github/workflows/$rw" > /dev/null 2>&1 || err "$tr has no .github/workflows/$rw"
fi

if [ "$errors" -gt 0 ]; then
	echo "$m: $errors problem(s)" >&2
	exit 1
fi
echo "$m: ok${live:+ (live)}"
