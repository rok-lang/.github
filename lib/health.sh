#!/bin/sh
# Health checks for released components.
#
#   health.sh parse <file>
#       print a /healthz body (healthz/1) as "key value" lines,
#       "status ok|failing" first
#   health.sh check <url> <expect> [<budget_s>]
#       poll until <url> passes or budget_s (default 60) runs out
#   health.sh component <manifest> <id> <version> [<pinned>] [<vars>]
#       every health[] entry of one component, placeholders expanded;
#       {pinned} is resolved from the component's pin when not given,
#       <vars> is a JSON object of more values ({"editor_version": ...})
#
# <url> forms and what <expect> means for each:
#   .../healthz         "key value": status ok, and key has that value
#   https://...         the body contains <expect>, HTTP 200
#   index-lag:<host>    at most <expect> index lines that <host> does not
#                       serve yet (index from ROK_INDEX_REPO)
#   compile:<host>      <host>/api/compile builds a program to wasm
#                       (<expect> is ignored)
#
# Environment: HEALTH_INTERVAL (60), HEALTH_SLEEP, HEALTH_NOW for tests,
# ROK_INDEX_REPO (rok-lang/rokstones.io-index), GH_TOKEN for gh.
set -eu
lib=$(cd "$(dirname "$0")" && pwd)
. "$lib/retry.sh"
. "$lib/gh.sh"
. "$lib/manifest.sh"

: "${HEALTH_INTERVAL:=60}"
: "${HEALTH_SLEEP:=sleep}"
: "${HEALTH_NOW:=date +%s}"
: "${ROK_INDEX_REPO:=rok-lang/rokstones.io-index}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A /healthz body: line 1 "ok" or "failing", then "key value" lines. A
# server that predates healthz/1 names its toolchain "release"; that key
# stands in for "toolchain" until every server sends both.
parse() {
	awk '
		NR == 1 {
			if ($0 != "ok" && $0 != "failing") { print "not a /healthz body: line 1 is \"" $0 "\", want ok or failing" > "/dev/stderr"; bad = 1; exit 1 }
			print "status " $0; next
		}
		NF == 0 { next }
		{
			k = $1; v = $0; sub(/^[^ ]+ +/, "", v)
			if (k == "healthz" && v !~ /^1$/) { print "healthz " v " is newer than this checker reads (1); use a newer rok-lang/.github" > "/dev/stderr"; bad = 1; exit 1 }
			if (!(k in seen)) order[++n] = k
			seen[k] = v
		}
		END {
			if (bad) exit 1
			if (!("toolchain" in seen) && ("release" in seen)) { order[++n] = "toolchain"; seen["toolchain"] = seen["release"] }
			for (i = 1; i <= n; i++) print order[i] " " seen[order[i]]
		}' "$1"
}

# fetch <url> <body file> [<curl args...>]: print the HTTP status; a fresh
# query on every URL makes the CDN ask the origin.
fetch() {
	_u=$1
	_o=$2
	shift 2
	case $_u in *\?*) _u="$_u&check=$($HEALTH_NOW)" ;; *) _u="$_u?check=$($HEALTH_NOW)" ;; esac
	rm -f "$_o"
	_fc=$(curl -sS --max-time 30 -o "$_o" -w '%{http_code}' "$@" "$_u" 2> "$tmp/curl.err") || _fc=000
	# curl's own message only when no answer came
	[ "$_fc" = 000 ] || : > "$tmp/curl.err"
	echo "$_fc"
}

# once <url> <expect>: one try; on failure print why and return 1.
once() {
	case $1 in
	index-lag:*) index_lag "${1#index-lag:}" "$2" ;;
	compile:*) compiles "${1#compile:}" ;;
	*/healthz)
		_c=$(fetch "$1" "$tmp/body")
		[ "$_c" = 200 ] || [ "$_c" = 503 ] || {
			echo "$1: HTTP $_c $(cat "$tmp/curl.err" 2> /dev/null)$(head -c 200 "$tmp/body" 2> /dev/null)"
			return 1
		}
		parse "$tmp/body" > "$tmp/kv" 2> "$tmp/perr" || {
			echo "$1: $(cat "$tmp/perr")"
			return 1
		}
		grep -qx 'status ok' "$tmp/kv" || {
			echo "$1: reports failing: $(tr '\n' ' ' < "$tmp/kv")"
			return 1
		}
		_k=${2%% *}
		_want=${2#* }
		_got=$(awk -v k="$_k" '$1 == k { sub(/^[^ ]+ +/, ""); print; exit }' "$tmp/kv")
		[ "$_got" = "$_want" ] || {
			echo "$1: $_k is \"$_got\", want \"$_want\""
			return 1
		}
		;;
	*)
		_c=$(fetch "$1" "$tmp/body")
		[ "$_c" = 200 ] || {
			echo "$1: HTTP $_c $(cat "$tmp/curl.err" 2> /dev/null)$(head -c 200 "$tmp/body" 2> /dev/null)"
			return 1
		}
		grep -qF -- "$2" "$tmp/body" || {
			echo "$1: no '$2' in: $(head -c 200 "$tmp/body")"
			return 1
		}
		;;
	esac
}

# index_lag <host> <max>: the last line of each stone file in the index
# must be served by https://<host>/api/v1/stones/<name>.
index_lag() {
	gh_files "$ROK_INDEX_REPO" main > "$tmp/files" 2> "$tmp/gherr" || {
		echo "index-lag: cannot list $ROK_INDEX_REPO: $(tail -n 1 "$tmp/gherr")"
		return 1
	}
	_lag=0
	_missing=
	grep -v -e '^\.' -e '\.md$' -e '^config\.rokon$' "$tmp/files" > "$tmp/stones" || true
	while read -r _f; do
		gh_file "$ROK_INDEX_REPO" "$_f" main < /dev/null > "$tmp/raw" 2> /dev/null || {
			echo "index-lag: cannot read $_f from $ROK_INDEX_REPO"
			return 1
		}
		tail -n 1 "$tmp/raw" > "$tmp/line"
		_nvy=$(sed -n 's/^Stone { name: "\([^"]*\)", version: "\([^"]*\)".* yanked: \([a-z]*\).*/\1 \2 \3/p' "$tmp/line")
		[ -n "$_nvy" ] || continue
		_name=${_nvy%% *}
		_yanked=${_nvy##* }
		_ver=${_nvy#* }
		_ver=${_ver% *}
		_c=$(fetch "https://$1/api/v1/stones/$_name" "$tmp/stone" < /dev/null)
		if [ "$_c" != 200 ] || ! grep -qF "Version { version: \"$_ver\", yanked: $_yanked," "$tmp/stone"; then
			_lag=$((_lag + 1))
			_missing="$_missing $_name@$_ver"
		fi
	done < "$tmp/stones"
	[ "$_lag" -le "$2" ] || {
		echo "index-lag: $1 does not serve$_missing yet"
		return 1
	}
}

compiles() {
	_c=$(fetch "https://$1/api/compile" "$tmp/wasm" -D "$tmp/hdr" --data-binary 'fn main() { println("ok"); }')
	[ "$_c" = 200 ] || {
		echo "compile:$1: HTTP $_c: $(head -c 200 "$tmp/wasm" 2> /dev/null)"
		return 1
	}
	grep -qi '^content-type: application/wasm' "$tmp/hdr" || {
		echo "compile:$1: the answer is not wasm"
		return 1
	}
}

check() {
	_budget=${3:-60}
	_end=$(($($HEALTH_NOW) + _budget))
	while :; do
		if _why=$(once "$1" "$2"); then
			echo "ok: $1 ($2)"
			return 0
		fi
		if [ "$($HEALTH_NOW)" -ge "$_end" ]; then
			echo "::error::$_why (after ${_budget}s)" >&2
			return 1
		fi
		echo "waiting: $_why" >&2
		$HEALTH_SLEEP "$HEALTH_INTERVAL"
	done
}

# pinned_of <component json>: the release its pin accepts today.
pinned_of() {
	_repo=$(printf '%s\n' "$1" | jq -r .repo)
	_pf=$(printf '%s\n' "$1" | jq -r '.pin.file // empty')
	[ -n "$_pf" ] || {
		echo "::error::$(printf '%s\n' "$1" | jq -r .id) uses {pinned} but has no pin" >&2
		return 1
	}
	gh_file "$_repo" "$_pf" "$(printf '%s\n' "$1" | jq -r '.pin.ref // "main"')" > "$tmp/pin.rokon" || {
		echo "::error::cannot read $_pf of $_repo" >&2
		return 1
	}
	"$lib/toolchain.sh" resolve "$("$lib/toolchain.sh" pin "$tmp/pin.rokon")"
}

component() {
	_entry=$(manifest_component "$1" "$2") || exit 1
	_pinned=${4:-}
	if [ -z "$_pinned" ] && printf '%s\n' "$_entry" | jq -e '[.health[]? | .url, .expect] | any(contains("{pinned}"))' > /dev/null; then
		_pinned=$(pinned_of "$_entry") || exit 1
	fi
	_vars=$(manifest_vars "$3" "$_pinned" "${5:-}")
	_n=$(printf '%s\n' "$_entry" | jq '.health // [] | length')
	[ "$_n" -gt 0 ] || {
		echo "$2 has no health checks in the manifest"
		return 0
	}
	_fail=0
	_i=0
	while [ "$_i" -lt "$_n" ]; do
		_h=$(printf '%s\n' "$_entry" | jq -c ".health[$_i]")
		_i=$((_i + 1))
		_u=$(manifest_expand "$(printf '%s\n' "$_h" | jq -r .url)" "$_vars") || exit 1
		_e=$(manifest_expand "$(printf '%s\n' "$_h" | jq -r .expect)" "$_vars") || exit 1
		check "$_u" "$_e" "$(printf '%s\n' "$_h" | jq -r '.budget_s // 60')" || _fail=1
	done
	return "$_fail"
}

cmd=${1:-}
[ $# -eq 0 ] || shift
case $cmd in
parse) parse "$1" ;;
check) check "$@" ;;
component) component "$@" ;;
*)
	echo "usage: health.sh parse|check|component ..." >&2
	exit 2
	;;
esac
