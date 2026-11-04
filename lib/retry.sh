# shellcheck shell=sh
# retry [<budget_s>] -- <cmd...>
#
# Run cmd; on a transient failure run it again after 10 30 90 270 600 s
# (+-20% jitter), never past budget_s (default 1100) since the first try.
# Transient: network errors, HTTP 5xx, 429 and rate limits, git "RPC
# failed", "early EOF" and "Could not resolve host". A rate limit waits
# Retry-After or until x-ratelimit-reset instead of the backoff step.
# Anything else, 409 and 422 included, returns at once with cmd's status
# so the caller re-observes before it writes again.
#
# cmd's stdout and stderr are held until it finishes, so only the last
# attempt's output reaches the caller. RETRY_HTTP is the last HTTP status
# found in cmd's stderr (empty if none), RETRY_ATTEMPTS the attempts made.
#
# Tests set RETRY_SLEEP (the sleep command), RETRY_DELAYS, RETRY_JITTER
# and RETRY_NOW (prints epoch seconds).

: "${RETRY_DELAYS:=10 30 90 270 600}"
: "${RETRY_JITTER:=20}"
: "${RETRY_SLEEP:=sleep}"
: "${RETRY_NOW:=date +%s}"

# retry_classify <stderr file>: set RETRY_HTTP, RETRY_CLASS (transient,
# ratelimit or fatal) and, for a rate limit, RETRY_WAIT.
retry_classify() {
	RETRY_HTTP=$(sed -n \
		-e 's/.*(HTTP \([0-9][0-9][0-9]\)).*/\1/p' \
		-e 's/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' \
		-e 's/.*returned error: \([0-9][0-9][0-9]\).*/\1/p' \
		-e 's/^HTTP \([0-9][0-9][0-9]\)$/\1/p' "$1" | tail -n 1)
	_rc_after=$(sed -n 's/^[Rr]etry-[Aa]fter: *\([0-9][0-9]*\).*/\1/p' "$1" | tail -n 1)
	_rc_reset=$(sed -n 's/^[Xx]-[Rr]ate[Ll]imit-[Rr]eset: *\([0-9][0-9]*\).*/\1/p' "$1" | tail -n 1)
	_rc_left=$(sed -n 's/^[Xx]-[Rr]ate[Ll]imit-[Rr]emaining: *\([0-9][0-9]*\).*/\1/p' "$1" | tail -n 1)
	RETRY_CLASS=fatal
	RETRY_WAIT=
	if [ "$RETRY_HTTP" = 429 ] || grep -qi 'secondary rate limit' "$1" ||
		{ [ "$RETRY_HTTP" = 403 ] && { [ "$_rc_left" = 0 ] || grep -qi 'rate limit' "$1"; }; }; then
		RETRY_CLASS=ratelimit
		if [ -n "$_rc_after" ]; then
			RETRY_WAIT=$_rc_after
		elif [ -n "$_rc_reset" ]; then
			RETRY_WAIT=$((_rc_reset - $($RETRY_NOW) + 1))
			[ "$RETRY_WAIT" -gt 0 ] || RETRY_WAIT=1
		else
			RETRY_WAIT=60
		fi
		return 0
	fi
	case $RETRY_HTTP in
	5[0-9][0-9])
		RETRY_CLASS=transient
		return 0
		;;
	[0-9][0-9][0-9]) return 0 ;;
	esac
	if grep -Eqi 'RPC failed|early EOF|Could not resolve host|no such host|dial tcp|connection reset|connection refused|i/o timeout|TLS handshake timeout|unexpected EOF|error connecting to|^curl: \((5|6|7|28|35|52|55|56)\)' "$1"; then
		RETRY_CLASS=transient
	fi
}

# retry_jitter <seconds>: seconds +- RETRY_JITTER percent.
retry_jitter() {
	awk -v d="$1" -v j="$RETRY_JITTER" -v s="$$$RETRY_ATTEMPTS$(date +%s)" \
		'BEGIN { srand(s % 2147483647); printf "%d\n", d * (1 + (rand() * 2 - 1) * j / 100) + 0.5 }'
}

retry() {
	_r_budget=1100
	if [ "${1:-}" != -- ]; then
		_r_budget=$1
		shift
	fi
	if [ "${1:-}" != -- ]; then
		echo "usage: retry [<budget_s>] -- <cmd...>" >&2
		return 2
	fi
	shift
	_r_out=$(mktemp)
	_r_err=$(mktemp)
	_r_start=$($RETRY_NOW)
	_r_delays=$(printf '%s\n' "$RETRY_DELAYS" | awk '{ $1 = $1; print }')
	RETRY_ATTEMPTS=0
	while :; do
		RETRY_ATTEMPTS=$((RETRY_ATTEMPTS + 1))
		_r_rc=0
		"$@" > "$_r_out" 2> "$_r_err" || _r_rc=$?
		if [ "$_r_rc" -eq 0 ]; then
			RETRY_HTTP=
			break
		fi
		retry_classify "$_r_err"
		[ "$RETRY_CLASS" != fatal ] || break
		# the next backoff step; a rate limit uses one up too
		[ -n "$_r_delays" ] || break
		_r_next=${_r_delays%% *}
		case $_r_delays in *" "*) _r_delays=${_r_delays#* } ;; *) _r_delays= ;; esac
		if [ "$RETRY_CLASS" = ratelimit ]; then
			_r_wait=$RETRY_WAIT
			_r_why="rate limited"
		else
			_r_wait=$(retry_jitter "$_r_next")
			_r_why=${RETRY_HTTP:+HTTP $RETRY_HTTP}
			_r_why=${_r_why:-network error}
		fi
		if [ $(($($RETRY_NOW) - _r_start + _r_wait)) -gt "$_r_budget" ]; then
			echo "::warning::retry: $*: $_r_why; ${_r_budget}s budget spent, giving up" >&2
			break
		fi
		echo "::warning::retry: $*: $_r_why (attempt $RETRY_ATTEMPTS), next in ${_r_wait}s" >&2
		$RETRY_SLEEP "$_r_wait"
	done
	cat "$_r_out"
	cat "$_r_err" >&2
	rm -f "$_r_out" "$_r_err"
	return "$_r_rc"
}
