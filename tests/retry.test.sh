#!/bin/sh
. "$(dirname "$0")/lib.sh"
. "$root/lib/retry.sh"

# flaky <n> <stderr line>: fail n times with that line, then print "done"
flaky() {
	_c=$(cat "$SHIM/flaky" 2> /dev/null || echo 0)
	echo $((_c + 1)) > "$SHIM/flaky"
	if [ "$_c" -lt "$1" ]; then
		echo "partial"
		printf '%b\n' "$2" >&2
		return 1
	fi
	echo "done"
}
reset() {
	t_case "$1"
	rm -f "$SHIM/flaky"
}
sleeps() { grep '^SLEEP' "$SHIM/calls" | awk '{ printf "%s ", $2 }'; }

reset "first try"
out=$(retry -- flaky 0 x)
eq "$out" "done"
eq "$(sleeps)" ""

reset "502 twice, then ok"
out=$(retry -- flaky 2 'gh: Bad Gateway (HTTP 502)' 2> "$SHIM/err")
eq "$out" "done" "only the last attempt's stdout"
eq "$(sleeps)" "10 30 "
eq "$(grep -c '^::warning::retry: flaky' "$SHIM/err")" 2 "warnings"

reset "404 is not retried"
rc=0
retry -- flaky 9 'gh: Not Found (HTTP 404)' > /dev/null 2>&1 || rc=$?
eq "$rc" 1 status
eq "$RETRY_HTTP" 404
eq "$RETRY_ATTEMPTS" 1
eq "$(sleeps)" ""

reset "422 goes back to the caller"
rc=0
retry -- flaky 9 'gh: Reference already exists (HTTP 422)' > /dev/null 2>&1 || rc=$?
eq "$RETRY_HTTP" 422
eq "$RETRY_ATTEMPTS" 1

for msg in "curl: (6) Could not resolve host: github.com" \
	"error: RPC failed; curl 92 HTTP/2 stream 5 was not closed cleanly" \
	"fatal: early EOF" "dial tcp: lookup api.github.com: no such host" \
	"curl: (22) The requested URL returned error: 503"; do
	reset "transient: $msg"
	out=$(retry -- flaky 1 "$msg" 2> /dev/null)
	eq "$out" "done"
	eq "$(sleeps)" "10 "
done

reset "429 waits Retry-After"
out=$(retry -- flaky 1 'HTTP/2.0 429 Too Many Requests\nretry-after: 7' 2> /dev/null)
eq "$(sleeps)" "7 "

reset "secondary rate limit without headers waits 60"
out=$(retry -- flaky 1 'gh: You have exceeded a secondary rate limit (HTTP 403)' 2> /dev/null)
eq "$(sleeps)" "60 "

reset "primary rate limit waits for the reset"
RETRY_NOW="echo 1000"
out=$(retry -- flaky 1 'HTTP/2.0 403 Forbidden\nx-ratelimit-remaining: 0\nx-ratelimit-reset: 1100' 2> /dev/null)
eq "$(sleeps)" "101 "
RETRY_NOW="date +%s"

reset "a plain 403 is not retried"
rc=0
retry -- flaky 1 'gh: Resource not accessible by integration (HTTP 403)' > /dev/null 2>&1 || rc=$?
eq "$rc" 1
eq "$(sleeps)" ""

reset "every step, then give up"
rc=0
retry -- flaky 99 'gh: Server Error (HTTP 500)' > "$SHIM/out" 2> /dev/null || rc=$?
eq "$rc" 1
eq "$RETRY_ATTEMPTS" 6 "attempts"
eq "$(sleeps)" "10 30 90 270 600 "
eq "$(cat "$SHIM/out")" partial

reset "the budget stops early"
echo 0 > "$SHIM/clock"
RETRY_NOW="cat $SHIM/clock"
t_tick() { echo $(($(cat "$SHIM/clock") + $1)) > "$SHIM/clock"; }
RETRY_SLEEP=t_tick
rc=0
retry 100 -- flaky 99 'gh: Bad Gateway (HTTP 502)' > /dev/null 2> "$SHIM/err" || rc=$?
eq "$rc" 1
eq "$(cat "$SHIM/clock")" 40 "time slept"
has "$(cat "$SHIM/err")" "100s budget spent"
RETRY_NOW="date +%s"
RETRY_SLEEP=t_sleep

reset "jitter stays within 20%"
RETRY_JITTER=20
i=0
while [ $i -lt 30 ]; do
	RETRY_ATTEMPTS=$i
	j=$(retry_jitter 100)
	[ "$j" -ge 80 ] && [ "$j" -le 120 ] || fail "jitter $j"
	i=$((i + 1))
done
RETRY_JITTER=0

reset "usage"
rc=0
retry flaky > /dev/null 2>&1 || rc=$?
eq "$rc" 2
