# shellcheck shell=sh
# Sourced by each *.test.sh: a fresh $SHIM, the shims first on PATH, and
# assertions. A failed assertion ends the file with status 1.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
SHIM=$(mktemp -d)
export SHIM
trap 'rm -rf "$SHIM"' EXIT
PATH=$root/tests/shim:$PATH
export PATH
# never wait in tests; log the waits instead
RETRY_SLEEP="t_sleep"
RETRY_JITTER=0
HEALTH_SLEEP="t_sleep"
HEALTH_INTERVAL=5
export RETRY_SLEEP RETRY_JITTER HEALTH_SLEEP HEALTH_INTERVAL
mkdir -p "$SHIM/bin"
# shellcheck disable=SC2016 # literal script
printf '#!/bin/sh\necho "SLEEP $1" >> "$SHIM/calls"\n' > "$SHIM/bin/t_sleep"
chmod +x "$SHIM/bin/t_sleep"
PATH=$SHIM/bin:$PATH
: > "$SHIM/calls"

case_name=
t_case() {
	case_name=$1
	: > "$SHIM/calls"
	rm -f "$SHIM"/faults "$SHIM"/faults.* "$SHIM"/hits.*
}

fail() {
	echo "  $case_name: $*" >&2
	exit 1
}

eq() { # <got> <want> [<what>]
	[ "$1" = "$2" ] || fail "${3:-value}: got [$1], want [$2]"
}

has() { # <haystack> <needle> [<what>]
	case $1 in *"$2"*) ;; *) fail "${3:-output}: no [$2] in [$1]" ;; esac
}

hasnt() {
	case $1 in *"$2"*) fail "${3:-output}: unexpected [$2] in [$1]" ;; esac
}

# calls <ERE>: how many logged calls match
calls() {
	grep -Ec -- "$1" "$SHIM/calls" || true
}

# writes: logged API calls that change state
writes() {
	calls '^(POST|PATCH|PUT|DELETE) '
}

state() { # <jq program>: set up the fake GitHub
	jq -n "$1" > "$SHIM/state.json"
}

fault() { # <count> <kind> <ERE>
	echo "$1 $2 $3" >> "$SHIM/faults"
}
