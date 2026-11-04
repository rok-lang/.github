#!/bin/sh
# One alarm issue per title: open it on the first failure, comment on it
# while it stays red, close it on the first green.
#
#   alarm.sh <owner/name> <title> <ok: true|false> <body file> [<labels>]
#
# The first label (default "alarm") narrows the search; an issue a human
# opened by hand with the same title and label is reused. Prints
# "issue=<n>" and "action=opened|updated|closed|none".
set -eu
lib=$(cd "$(dirname "$0")" && pwd)
. "$lib/retry.sh"
. "$lib/gh.sh"

[ $# -ge 4 ] || {
	echo "usage: alarm.sh <owner/name> <title> <ok> <body file> [<labels>]" >&2
	exit 2
}
repo=$1
title=$2
ok=$3
body=$4
labels=${5:-alarm}
first=${labels%%,*}
case $ok in
true | false) ;;
*)
	echo "::error::alarm: ok is \"$ok\"; write true or false" >&2
	exit 2
	;;
esac
[ -n "$title" ] || {
	echo "::error::alarm: the title is empty" >&2
	exit 2
}

issue=$(gh_issue_find "$repo" "$title" open "$first")
action=none
if [ "$ok" = false ]; then
	if [ -n "$issue" ]; then
		gh_issue_comment "$repo" "$issue" "$body"
		action=updated
	else
		issue=$(gh_issue_create "$repo" "$title" "$body" "$labels")
		action=opened
	fi
elif [ -n "$issue" ]; then
	gh_issue_comment "$repo" "$issue" "$body"
	gh_issue_patch "$repo" "$issue" '{"state":"closed","state_reason":"completed"}'
	action=closed
fi
echo "issue=$issue"
echo "action=$action"
