#!/bin/sh
# The release record (record: 1), kept as a JSON block in the release
# issue body between <!-- record:begin --> and <!-- record:end -->, with
# a rendered table between <!-- table:begin --> and <!-- table:end -->.
# Text outside the markers is left alone. The record is evidence and a
# cache; callers re-observe GitHub before they act on it.
#
#   record.sh get <owner/name> <issue>
#   record.sh update <owner/name> <issue> <patch json file>
#   record.sh open <owner/name> <title> <labels> <record json file>
#       find the open issue with that title or create it; print its number
#
# update merges the patch into the record (objects deep, arrays replaced,
# "events" appended unless already there, so a repeated patch is a no-op)
# and prints the result. It refuses a state that goes
# back, ABANDONED after TAGGED, SUPERSEDED before TAGGED, any change after
# a final state, and a record version it does not know.
set -eu
lib=$(cd "$(dirname "$0")" && pwd)
. "$lib/retry.sh"
. "$lib/gh.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

die() {
	echo "::error::record: $*" >&2
	exit 1
}

STATES="PLANNED PREPARED LANDED READY BUILT APPROVED TAGGED DRAFTED PUBLISHED SMOKED FANNED_OUT CONVERGED CLOSED"

# rank <state>: its place in STATES; ABANDONED and SUPERSEDED rank 100.
rank() {
	case $1 in
	ABANDONED | SUPERSEDED)
		echo 100
		return 0
		;;
	esac
	_i=0
	for _s in $STATES; do
		_i=$((_i + 1))
		[ "$_s" != "$1" ] || {
			echo "$_i"
			return 0
		}
	done
	die "unknown state \"$1\"; states are $STATES ABANDONED SUPERSEDED"
}

# extract <body file>: the record JSON, or nothing.
extract() {
	awk '/<!-- record:end -->/ { on = 0 } on && !/^```/ { print } /<!-- record:begin -->/ { on = 1 }' "$1"
}

body_of() {
	gh_issue_get "$1" "$2" > "$tmp/issue" || die "cannot read issue $2 of $1"
	jq -j '.body // ""' "$tmp/issue" > "$tmp/body"
}

get() {
	body_of "$1" "$2"
	extract "$tmp/body" > "$tmp/rec"
	[ -s "$tmp/rec" ] || die "issue $2 of $1 holds no record"
	jq -e . "$tmp/rec" > /dev/null 2>&1 || die "the record in issue $2 of $1 is not valid JSON"
	_v=$(jq -r '.record // empty' "$tmp/rec")
	[ "$_v" = 1 ] || die "issue $2 of $1 holds record version \"$_v\"; this block reads 1"
	jq . "$tmp/rec"
}

# check_move <old state> <new state>
check_move() {
	[ -n "$2" ] && [ "$1" != "$2" ] || return 0
	[ -n "$1" ] || {
		rank "$2" > /dev/null
		return 0
	}
	_o=$(rank "$1")
	_n=$(rank "$2")
	_tagged=$(rank TAGGED)
	case $1 in
	ABANDONED | SUPERSEDED | CLOSED) die "the record is $1, a final state; it cannot become $2" ;;
	esac
	case $2 in
	ABANDONED)
		[ "$_o" -lt "$_tagged" ] || die "$1 is at or past TAGGED: the version is burned, so it cannot be ABANDONED; ship the fix as the next patch (SUPERSEDED)"
		;;
	SUPERSEDED)
		[ "$_o" -ge "$_tagged" ] || die "$1 is before TAGGED: nothing is burned, so ABANDONED fits, not SUPERSEDED"
		;;
	*)
		[ "$_n" -gt "$_o" ] || die "the record is $1; it cannot go back to $2 (a re-dispatch resumes, it does not rewind)"
		;;
	esac
}

render() {
	jq -r '
		def cell: if type == "object" or type == "array" then tojson else tostring end;
		"| | |", "|---|---|",
		"| state | \(.state // "-")\(if .blocked then " (blocked: \(.blocked.reason // "-"))" else "" end) |",
		(["version", "series", "prev", "event", "blocks"][] as $k | select(.[$k] != null) | "| \($k) | \(.[$k] | cell) |"),
		(if .manifest then "| manifest | \(.manifest.repo // "")@\(.manifest.sha // "") |" else empty end),
		(.fanout // {} | to_entries[] | "| \(.key) | \(.value.state // "-")\(if .value.pr then " #\(.value.pr)" else "" end) |")' "$1"
}

write() {
	{
		echo '<!-- table:begin -->'
		render "$2"
		echo
		echo '<!-- table:end -->'
		echo '<!-- record:begin -->'
		echo '```json'
		jq . "$2"
		echo '```'
		echo '<!-- record:end -->'
	} > "$tmp/block"
	# replace the marked blocks, keep the rest
	awk -v blk="$tmp/block" '
		/<!-- table:begin -->/ { skip = 1 }
		/<!-- record:begin -->/ { skip = 1 }
		!skip { print }
		/<!-- table:end -->/ { skip = 0; next }
		/<!-- record:end -->/ { skip = 0; if (!done) { while ((getline l < blk) > 0) print l; done = 1 } }
		END { if (!done) { while ((getline l < blk) > 0) print l } }' "$tmp/body" > "$tmp/newbody"
	# an unchanged body is not written again
	if cmp -s "$tmp/newbody" "$tmp/body"; then return 0; fi
	jq -n --rawfile b "$tmp/newbody" '{body: $b}' > "$tmp/patch.json"
	gh_issue_patch "$1" "$3" "$(cat "$tmp/patch.json")" || die "cannot write issue $3 of $1"
}

update() {
	jq -e 'type == "object"' "$3" > /dev/null 2>&1 || die "the patch $3 is not a JSON object"
	body_of "$1" "$2"
	extract "$tmp/body" > "$tmp/rec"
	if [ -s "$tmp/rec" ]; then
		get "$1" "$2" > "$tmp/old"
	else
		echo '{"record": 1}' > "$tmp/old"
	fi
	jq -e 'has("record") | not' "$3" > /dev/null || [ "$(jq -r .record "$3")" = 1 ] || die "the patch sets record $(jq -r .record "$3"); this block writes 1"
	check_move "$(jq -r '.state // empty' "$tmp/old")" "$(jq -r '.state // empty' "$3")"
	[ -n "$(jq -r '.state // empty' "$3")" ] || [ -n "$(jq -r '.state // empty' "$tmp/old")" ] || die "a new record needs a state"
	jq -s '.[0] as $o | .[1] as $p
		| ($o * ($p | del(.events)))
		| ($o.events // []) as $had
		| .events = ($had + [($p.events // [])[] | select(. as $e | $had | any(. == $e) | not)])
		| .record = 1' "$tmp/old" "$3" > "$tmp/new"
	write "$1" "$tmp/new" "$2"
	jq . "$tmp/new"
}

open_issue() {
	_n=$(gh_issue_find "$1" "$2" open "${3%%,*}")
	if [ -z "$_n" ]; then
		printf '\n' > "$tmp/b0"
		_n=$(gh_issue_create "$1" "$2" "$tmp/b0" "$3") || die "cannot open issue \"$2\" in $1"
	fi
	update "$1" "$_n" "$4" > /dev/null
	echo "$_n"
}

cmd=${1:-}
[ $# -eq 0 ] || shift
case $cmd in
get) get "$1" "$2" ;;
update) update "$1" "$2" "$3" ;;
open) open_issue "$1" "$2" "$3" "$4" ;;
*)
	echo "usage: record.sh get|update|open ..." >&2
	exit 2
	;;
esac
