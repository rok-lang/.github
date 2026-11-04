#!/bin/sh
# shellcheck disable=SC2016 # fixtures are literal shell text
. "$(dirname "$0")/lib.sh"
. "$root/lib/retry.sh"
. "$root/lib/gh.sh"

state '{repos: {"rok-lang/rok": {
	releases: [
		{tag_name: "v0.2.1", prerelease: false, draft: true},
		{tag_name: "v0.2.0", prerelease: false, draft: false}],
	files: {main: {"rok.rokon": "Package {\n    toolchain: \"0.2\",\n}\n"}},
	issues: [
		{number: 1, title: "Nightly CI is failing", body: "", labels: [{name: "alarm"}], state: "closed", comments: []},
		{number: 2, title: "Nightly CI is failing", body: "", labels: [{name: "alarm"}], state: "open", comments: []},
		{number: 3, title: "Nightly CI is failing!", body: "", labels: [{name: "alarm"}], state: "open", comments: []}]}}}'

t_case "repo exists"
gh_repo_exists rok-lang/rok || fail "rok-lang/rok"
rc=0
gh_repo_exists rok-lang/nope 2> /dev/null || rc=$?
eq "$rc" 1 "missing repo"

t_case "5xx twice, then the answer"
fault 2 502 '^GET repos/rok-lang/rok$'
gh_repo_exists rok-lang/rok || fail "after two 502s"
eq "$(calls '^GET repos/rok-lang/rok$')" 3 "attempts"
eq "$(calls '^SLEEP')" 2 "waits"

t_case "a lost network is retried"
fault 1 net '^GET repos/rok-lang/rok$'
gh_repo_exists rok-lang/rok || fail "after a network error"
eq "$(calls '^SLEEP 10$')" 1

t_case "429 waits the Retry-After header"
fault 1 429 '^GET repos/rok-lang/rok$'
gh_repo_exists rok-lang/rok || fail "after a 429"
eq "$(calls '^SLEEP 2$')" 1 "Retry-After: 2"

t_case "secondary rate limit"
fault 1 403rl '^GET repos/rok-lang/rok$'
gh_repo_exists rok-lang/rok || fail "after a secondary rate limit"
eq "$(calls '^SLEEP 60$')" 1

t_case "unknown is 2 when the API keeps failing"
fault 9 502 '^GET repos/rok-lang/rok$'
rc=0
gh_repo_exists rok-lang/rok 2> /dev/null || rc=$?
eq "$rc" 2

t_case "file content"
eq "$(gh_file rok-lang/rok rok.rokon main | sed -n 2p)" '    toolchain: "0.2",'

t_case "releases"
eq "$(gh_releases rok-lang/rok | tr '\n' ';')" "v0.2.1 false true;v0.2.0 false false;"

t_case "issue by exact title, open only"
eq "$(gh_issue_find rok-lang/rok "Nightly CI is failing" open alarm)" 2
eq "$(gh_issue_find rok-lang/rok "Nightly CI is failing" all)" 2 "newest of all"
eq "$(gh_issue_find rok-lang/rok "Nightly" open)" ""

t_case "create, patch, comment"
printf 'line 1\n"quoted" `ticks`\n' > "$SHIM/b"
n=$(gh_issue_create rok-lang/rok "Release 0.2.1" "$SHIM/b" "release, alarm")
eq "$n" 4
eq "$(jq -r '.repos["rok-lang/rok"].issues[3].body' "$SHIM/state.json")" "$(cat "$SHIM/b")" body
eq "$(jq -r '.repos["rok-lang/rok"].issues[3].labels | map(.name) | join(",")' "$SHIM/state.json")" "release,alarm"
gh_issue_comment rok-lang/rok 4 "$SHIM/b"
gh_issue_patch rok-lang/rok 4 '{"state":"closed"}'
eq "$(jq -r '.repos["rok-lang/rok"].issues[3].state' "$SHIM/state.json")" closed
eq "$(writes)" 3

t_case "a failed write is not retried on 422"
fault 9 422 '^POST repos/rok-lang/rok/issues$'
rc=0
gh_issue_create rok-lang/rok x "$SHIM/b" > /dev/null 2>&1 || rc=$?
eq "$rc" 1
eq "$(calls '^POST repos/rok-lang/rok/issues$')" 1
