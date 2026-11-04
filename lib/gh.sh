# shellcheck shell=sh
# Every GitHub API call of the blocks goes through here, so a change in
# GitHub's behaviour is fixed in one file. Needs gh (GH_TOKEN), jq, and
# retry.sh sourced first.

# gh_api_once <method> <path> [gh api args...]: print the body. On a
# failure, stderr gets gh's message plus the status line and rate-limit
# headers, which retry() reads.
gh_api_once() {
	_ga_m=$1
	_ga_p=$2
	shift 2
	_ga_f=$(mktemp)
	_ga_rc=0
	gh api --include --method "$_ga_m" "$_ga_p" "$@" > "$_ga_f" || _ga_rc=$?
	# headers end at the first empty line
	tr -d '\r' < "$_ga_f" | awk 'body { print; next } /^$/ { body = 1 }'
	if [ "$_ga_rc" -ne 0 ]; then
		tr -d '\r' < "$_ga_f" | awk '/^$/ { exit } { print }' |
			grep -Ei '^HTTP/|^retry-after:|^x-ratelimit-(reset|remaining):' >&2 || true
	fi
	rm -f "$_ga_f"
	return "$_ga_rc"
}

# gh_api <method> <path> [gh api args...]: gh_api_once under retry.
gh_api() {
	retry -- gh_api_once "$@"
}

# gh_api_lines <path> <jq>: every page of a list, one jq result per line.
gh_api_lines() {
	retry -- gh api --paginate "$1" --jq "$2"
}

# gh_status: the HTTP status of the last failed gh_api call.
gh_status() {
	echo "${RETRY_HTTP:-}"
}

# gh_repo_exists <owner/name>: 0 yes, 1 no (404), 2 cannot tell.
gh_repo_exists() {
	if gh_api GET "repos/$1" > /dev/null 2>&1; then return 0; fi
	[ "$(gh_status)" = 404 ] && return 1
	return 2
}

# gh_file <owner/name> <path> [<ref>]: the file's content.
gh_file() {
	_gf=$(gh_api GET "repos/$1/contents/$2${3:+?ref=$3}") || return 1
	printf '%s\n' "$_gf" | jq -r '.content | gsub("\n"; "") | @base64d'
}

# gh_files <owner/name> <ref>: the path of every blob in the tree.
gh_files() {
	_gf=$(gh_api GET "repos/$1/git/trees/$2?recursive=1") || return 1
	printf '%s\n' "$_gf" | jq -r '.tree[] | select(.type == "blob") | .path'
}

# gh_releases <owner/name>: "<tag> <prerelease> <draft>" per release.
gh_releases() {
	gh_api_lines "repos/$1/releases?per_page=100" '.[] | "\(.tag_name) \(.prerelease) \(.draft)"'
}

# gh_issue_find <owner/name> <title> <state> [<label>]: the number of the
# newest issue (not PR) with exactly that title; empty if none.
gh_issue_find() {
	_gl=$(gh_api_lines "repos/$1/issues?state=$3&per_page=100${4:+&labels=$(gh_urlencode "$4")}" \
		'.[] | select(.pull_request == null) | "\(.number)\t\(.title)"') || return 1
	printf '%s\n' "$_gl" | awk -F '\t' -v t="$2" '$2 == t { print $1 }' | sort -n | tail -n 1
}

# gh_issue_get <owner/name> <number>: the issue as JSON.
gh_issue_get() {
	gh_api GET "repos/$1/issues/$2"
}

# gh_issue_create <owner/name> <title> <body file> [<labels, comma list>]:
# print the new number.
gh_issue_create() {
	_gi_in=$(mktemp)
	jq -n --arg t "$2" --rawfile b "$3" --arg l "${4:-}" \
		'{title: $t, body: $b, labels: ($l | split(",") | map(gsub("^ +| +$"; "")) | map(select(. != "")))}' > "$_gi_in"
	_gi_rc=0
	_gi_out=$(gh_api POST "repos/$1/issues" --input "$_gi_in") || _gi_rc=$?
	rm -f "$_gi_in"
	[ "$_gi_rc" -eq 0 ] || return "$_gi_rc"
	printf '%s\n' "$_gi_out" | jq -r .number
}

# gh_issue_patch <owner/name> <number> <json>: edit body, state, title.
gh_issue_patch() {
	_gi_in=$(mktemp)
	printf '%s\n' "$3" > "$_gi_in"
	_gi_rc=0
	gh_api PATCH "repos/$1/issues/$2" --input "$_gi_in" > /dev/null || _gi_rc=$?
	rm -f "$_gi_in"
	return "$_gi_rc"
}

# gh_issue_comment <owner/name> <number> <body file>
gh_issue_comment() {
	_gi_in=$(mktemp)
	jq -n --rawfile b "$3" '{body: $b}' > "$_gi_in"
	_gi_rc=0
	gh_api POST "repos/$1/issues/$2/comments" --input "$_gi_in" > /dev/null || _gi_rc=$?
	rm -f "$_gi_in"
	return "$_gi_rc"
}

# gh_run_download <owner/name> <run id> <pattern> <dir>
gh_run_download() {
	retry -- gh run download "$2" -R "$1" -p "$3" -D "$4"
}

# gh_attest_verify <file> <owner/name>: Sigstore provenance of a release
# asset, built by a workflow of that repo.
gh_attest_verify() {
	retry -- gh attestation verify "$1" --repo "$2" > /dev/null
}

gh_urlencode() {
	jq -rn --arg s "$1" '$s | @uri'
}
