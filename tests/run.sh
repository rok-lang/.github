#!/bin/sh
# Hermetic tests of lib/: gh and curl are the shims in tests/shim, so
# nothing reaches the network.
#
#   tests/run.sh [<name>...]      e.g. tests/run.sh retry record
set -eu
here=$(cd "$(dirname "$0")" && pwd)
fails=0
if [ $# -eq 0 ]; then set -- "$here"/*.test.sh; fi
for t; do
	case $t in */*) ;; *) t=$here/$t.test.sh ;; esac
	name=$(basename "$t" .test.sh)
	if sh "$t"; then
		echo "ok   $name"
	else
		echo "FAIL $name"
		fails=$((fails + 1))
	fi
done
[ "$fails" -eq 0 ] || {
	echo "$fails test file(s) failed"
	exit 1
}
