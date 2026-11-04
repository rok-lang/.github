#!/bin/sh
. "$(dirname "$0")/lib.sh"
a=$root/lib/alarm.sh
state '{repos: {"rok-lang/rok": {issues: [
	{number: 1, title: "Nightly CI is failing", body: "", labels: [{name: "alarm"}], state: "closed", comments: []},
	{number: 2, title: "Nightly CI is failing", body: "", labels: [{name: "other"}], state: "open", comments: []}]}}}'
echo "run 1 failed" > "$SHIM/body"
issue() { jq -c --arg n "$1" '.repos["rok-lang/rok"].issues[] | select(.number == ($n | tonumber))' "$SHIM/state.json"; }

t_case "green with no alarm open does nothing"
out=$(sh "$a" rok-lang/rok "Nightly CI is failing" true "$SHIM/body")
has "$out" "action=none"
eq "$(writes)" 0

t_case "red opens a new issue (a closed one, or one without the label, is not reused)"
out=$(sh "$a" rok-lang/rok "Nightly CI is failing" false "$SHIM/body" "alarm,type: bug")
has "$out" "issue=3"
has "$out" "action=opened"
eq "$(issue 3 | jq -r '.labels | map(.name) | join(",")')" "alarm,type: bug"
eq "$(issue 3 | jq -r .body)" "run 1 failed"

t_case "still red comments on it"
echo "run 2 failed" > "$SHIM/body"
out=$(sh "$a" rok-lang/rok "Nightly CI is failing" false "$SHIM/body")
has "$out" "issue=3"
has "$out" "action=updated"
eq "$(issue 3 | jq -r '.comments[-1]')" "run 2 failed"
eq "$(writes)" 1

t_case "a 502 on the comment is retried once, not doubled"
fault 1 502 '^POST repos/rok-lang/rok/issues/3/comments$'
sh "$a" rok-lang/rok "Nightly CI is failing" false "$SHIM/body" > /dev/null 2>&1
eq "$(issue 3 | jq '.comments | length')" 2 "one comment"

t_case "green closes it"
echo "run 3 passed" > "$SHIM/body"
out=$(sh "$a" rok-lang/rok "Nightly CI is failing" true "$SHIM/body")
has "$out" "action=closed"
eq "$(issue 3 | jq -r .state)" closed
eq "$(issue 3 | jq -r '.comments[-1]')" "run 3 passed"

t_case "bad input"
err=$(sh "$a" rok-lang/rok "x" yes "$SHIM/body" 2>&1) && fail "ok=yes accepted"
has "$err" "write true or false"
