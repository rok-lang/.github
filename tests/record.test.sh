#!/bin/sh
. "$(dirname "$0")/lib.sh"
r=$root/lib/record.sh
state '{repos: {"rok-lang/rok": {issues: []}}}'
body() { jq -r --arg n "$1" '.repos["rok-lang/rok"].issues[] | select(.number == ($n | tonumber)) | .body' "$SHIM/state.json"; }
patch() {
	printf '%s\n' "$1" > "$SHIM/p.json"
	sh "$r" update rok-lang/rok 1 "$SHIM/p.json"
}

t_case "open creates the issue with the first record"
echo '{"version":"0.2.1","series":"0.2","event":"patch","state":"PLANNED","events":[{"state":"PLANNED"}]}' > "$SHIM/r.json"
n=$(sh "$r" open rok-lang/rok "Release 0.2.1" release "$SHIM/r.json")
eq "$n" 1
has "$(body 1)" '<!-- record:begin -->'
has "$(body 1)" '| state | PLANNED |'
eq "$(sh "$r" get rok-lang/rok 1 | jq -c '{record, state, version}')" '{"record":1,"state":"PLANNED","version":"0.2.1"}'

t_case "open again reuses it"
n=$(sh "$r" open rok-lang/rok "Release 0.2.1" release "$SHIM/r.json")
eq "$n" 1
eq "$(calls '^POST repos/rok-lang/rok/issues$')" 0

t_case "update merges deep, appends events, keeps human text"
jq --arg b "Notes by hand.

$(body 1)

Footer by hand." '.repos["rok-lang/rok"].issues[0].body = $b' "$SHIM/state.json" > "$SHIM/s" && mv "$SHIM/s" "$SHIM/state.json"
patch '{"state":"PREPARED","prepare":{"branch":"release/0.2.1"},"events":[{"state":"PREPARED"}]}' > /dev/null
patch '{"prepare":{"commit":"abc"},"fanout":{"docs":{"state":"sent"}}}' > "$SHIM/out"
eq "$(jq -c .prepare "$SHIM/out")" '{"branch":"release/0.2.1","commit":"abc"}'
eq "$(jq -c '[.events[].state]' "$SHIM/out")" '["PLANNED","PREPARED"]'
has "$(body 1)" "Notes by hand."
has "$(body 1)" "Footer by hand."
has "$(body 1)" "| docs | sent |"
eq "$(body 1 | grep -c 'record:begin')" 1 "one record block"

t_case "the same state again is fine"
patch '{"state":"PREPARED"}' > /dev/null || fail "same state"

t_case "a state never goes back"
err=$(patch '{"state":"PLANNED"}' 2>&1) && fail "went back"
has "$err" "cannot go back to PLANNED"
eq "$(sh "$r" get rok-lang/rok 1 | jq -r .state)" PREPARED

t_case "unknown state"
err=$(patch '{"state":"DONE"}' 2>&1) && fail "DONE accepted"
has "$err" 'unknown state "DONE"'

t_case "blocked is a field, the state stays"
patch '{"blocked":{"state":"LANDED","reason":"main moved"}}' > /dev/null
has "$(body 1)" "PREPARED (blocked: main moved)"

t_case "ABANDONED only before TAGGED"
patch '{"state":"TAGGED","blocked":null}' > /dev/null
err=$(patch '{"state":"ABANDONED"}' 2>&1) && fail "abandoned after TAGGED"
has "$err" "the version is burned"
patch '{"state":"SUPERSEDED","superseded_by":"0.2.2"}' > /dev/null || fail "superseded"
err=$(patch '{"state":"CLOSED"}' 2>&1) && fail "changed after a final state"
has "$err" "a final state"

t_case "SUPERSEDED needs TAGGED"
echo '{"version":"0.2.2","state":"BUILT"}' > "$SHIM/r2.json"
n=$(sh "$r" open rok-lang/rok "Release 0.2.2" release "$SHIM/r2.json")
printf '{"state":"SUPERSEDED"}\n' > "$SHIM/p.json"
err=$(sh "$r" update rok-lang/rok "$n" "$SHIM/p.json" 2>&1) && fail "superseded before TAGGED"
has "$err" "ABANDONED fits"

t_case "a newer record version is refused"
jq '.repos["rok-lang/rok"].issues[1].body |= sub("\"record\": 1"; "\"record\": 2")' "$SHIM/state.json" > "$SHIM/s" && mv "$SHIM/s" "$SHIM/state.json"
err=$(sh "$r" get rok-lang/rok 2 2>&1) && fail "record 2 read"
has "$err" "record version \"2\"; this block reads 1"

t_case "writes go through retry"
fault 2 502 '^PATCH repos/rok-lang/rok/issues/1$'
echo '{"version":"0.2.3","state":"PLANNED"}' > "$SHIM/r3.json"
n=$(sh "$r" open rok-lang/rok "Release 0.2.3" release "$SHIM/r3.json" 2> /dev/null)
eq "$(calls '^SLEEP')" 0 "issue 3 untouched by issue 1 faults"
fault 1 502 "^PATCH repos/rok-lang/rok/issues/$n\$"
printf '{"state":"PREPARED"}\n' > "$SHIM/p.json"
sh "$r" update rok-lang/rok "$n" "$SHIM/p.json" > /dev/null 2>&1 || fail "update after a 502"
eq "$(calls '^SLEEP 10$')" 1

t_case "a missing record"
printf 'x\n' > "$SHIM/b"
jq '.repos["rok-lang/rok"].issues += [{number: 9, title: "t", body: "plain", labels: [], state: "open", comments: []}]' "$SHIM/state.json" > "$SHIM/s" && mv "$SHIM/s" "$SHIM/state.json"
err=$(sh "$r" get rok-lang/rok 9 2>&1) && fail "no record read"
has "$err" "holds no record"

t_case "a repeated patch writes nothing"
printf '{"state":"PREPARED","events":[{"state":"PREPARED"}]}\n' > "$SHIM/p.json"
sh "$r" update rok-lang/rok "$n" "$SHIM/p.json" > /dev/null
: > "$SHIM/calls"
sh "$r" update rok-lang/rok "$n" "$SHIM/p.json" > /dev/null
eq "$(writes)" 0
