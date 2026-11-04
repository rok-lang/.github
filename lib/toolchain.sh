#!/bin/sh
# Resolve and install a rok toolchain from GitHub releases. Never reads a
# site: the pipeline must work while rok-lang.org is down or mid-deploy.
#
#   toolchain.sh pin <rok.rokon>             print its toolchain: pin
#   toolchain.sh kind <pin>                  series, exact or pre
#   toolchain.sh resolve <pin>               newest release the pin accepts
#   toolchain.sh triple                      this host's target triple
#   toolchain.sh install [--home <dir>] [--no-attest]
#       (--version <pin> | --pin-file <rok.rokon> | --candidate-run <id>)
#
# A pin is MAJOR.MINOR (newest final release of that series),
# MAJOR.MINOR.PATCH (exactly that) or X.Y.Z-rc.N (that prerelease).
# install prints "version=<v>" and "bin=<dir>" lines.
#
# Environment: ROK_REPO (rok-lang/rok), ROK_DIST (release download base),
# GH_TOKEN for gh.
set -eu
lib=$(cd "$(dirname "$0")" && pwd)
. "$lib/retry.sh"
. "$lib/gh.sh"

: "${ROK_REPO:=rok-lang/rok}"
: "${ROK_DIST:=https://github.com/$ROK_REPO/releases}"

die() {
	echo "::error::install-rok: $*" >&2
	exit 1
}

pin_of() {
	[ -f "$1" ] || die "$1 does not exist"
	_p=$(sed -n 's/^[[:space:]]*toolchain:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1)
	[ -n "$_p" ] || die "$1 pins no toolchain; add toolchain: \"0.2\" to its Package"
	echo "$_p"
}

# pin_kind <pin>: series, exact or pre; fails on anything else.
pin_kind() {
	if echo "$1" | grep -Eq '^[0-9]+\.[0-9]+$'; then
		echo series
	elif echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
		echo exact
	elif echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$'; then
		echo pre
	else
		die "toolchain \"$1\" is not a pin; write a series (\"0.2\"), a release (\"0.2.1\") or a prerelease (\"0.3.0-rc.1\")"
	fi
}

resolve() {
	_k=$(pin_kind "$1")
	_rels=$(gh_releases "$ROK_REPO") || die "cannot list the releases of $ROK_REPO"
	case $_k in
	series)
		_v=$(printf '%s\n' "$_rels" | awk -v p="v$1." '$2 == "false" && $3 == "false" && index($1, p) == 1 && $1 !~ /-/ { print substr($1, 2) }' |
			sort -t . -k 1,1n -k 2,2n -k 3,3n | tail -n 1)
		;;
	*)
		_v=$(printf '%s\n' "$_rels" | awk -v t="v$1" '$1 == t && $3 == "false" { print substr($1, 2) }')
		;;
	esac
	[ -n "$_v" ] || die "no published rok release matches toolchain \"$1\" in $ROK_REPO"
	echo "$_v"
}

triple() {
	case $(uname -m) in
	arm64 | aarch64) _a=aarch64 ;;
	x86_64 | amd64) _a=x86_64 ;;
	*) die "no rok toolchain for the $(uname -m) architecture" ;;
	esac
	case $(uname -s) in
	Darwin) echo "$_a-apple-darwin" ;;
	Linux)
		if ls /lib/ld-musl-* > /dev/null 2>&1; then
			echo "$_a-unknown-linux-musl"
		else
			echo "$_a-unknown-linux-gnu"
		fi
		;;
	MINGW* | MSYS* | CYGWIN*) echo "$_a-pc-windows-msvc" ;;
	*) die "no rok toolchain for $(uname -s)" ;;
	esac
}

sha256_of() {
	if command -v sha256sum > /dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

check_sum() {
	[ -f "$2" ] || die "$(basename "$1") has no .sha256 beside it, so it cannot be checked"
	_want=$(awk '{ print tolower($1); exit }' "$2")
	_got=$(sha256_of "$1")
	[ "$_got" = "$_want" ] || die "$(basename "$1") has SHA-256 $_got, but its .sha256 says $_want"
}

download() {
	retry -- curl -fsSL --proto '=https,file' -o "$2" "$1" || die "cannot download $1"
}

unpack() {
	case $1 in
	*.zip)
		if command -v unzip > /dev/null 2>&1; then
			unzip -q "$1" -d "$2"
		else
			"${SYSTEMROOT:-C:/Windows}/System32/tar.exe" -xf "$1" -C "$2"
		fi
		;;
	*.tar.xz) tar -xJf "$1" -C "$2" ;;
	*) tar -xzf "$1" -C "$2" ;;
	esac || die "cannot unpack $1"
}

# native_path <path>: a path rok.exe understands on Windows.
native_path() {
	if command -v cygpath > /dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi
}

install() {
	_home=
	_want=
	_pinfile=
	_run=
	_attest=1
	while [ $# -gt 0 ]; do
		case $1 in
		--home) _home=$2 && shift ;;
		--version) _want=$2 && shift ;;
		--pin-file) _pinfile=$2 && shift ;;
		--candidate-run) _run=$2 && shift ;;
		--no-attest) _attest= ;;
		*) die "unknown option $1" ;;
		esac
		shift
	done
	_n=0
	for _x in "$_want" "$_pinfile" "$_run"; do [ -z "$_x" ] || _n=$((_n + 1)); done
	[ "$_n" -eq 1 ] || die "give exactly one of version, pin or candidate-run"
	_home=${_home:-$HOME/.rok}
	_t=$(triple)
	_tmp=$(mktemp -d)
	case $_t in *-windows-*) _exts=zip ;; *) _exts="tar.xz tar.gz" ;; esac
	if [ "$(uname -s)" != Darwin ] && ! command -v xz > /dev/null 2>&1; then
		_exts=$(echo "$_exts" | sed 's/tar.xz //')
	fi

	if [ -n "$_run" ]; then
		gh_run_download "$ROK_REPO" "$_run" 'dist-*' "$_tmp/run" ||
			die "cannot download the dist-* artifacts of $ROK_REPO run $_run"
		_ar=
		for _e in $_exts; do
			_ar=$(find "$_tmp/run" -type f -name "rok-*-$_t.$_e" | head -n 1)
			[ -z "$_ar" ] || break
		done
		[ -n "$_ar" ] || die "run $_run has no $_t archive in its dist-* artifacts"
		_v=$(basename "$_ar" | sed "s/^rok-\(.*\)-$_t\..*/\1/")
		check_sum "$_ar" "$_ar.sha256"
	else
		if [ -n "$_pinfile" ]; then _want=$(pin_of "$_pinfile"); fi
		_v=$(resolve "$_want")
		_ar=
		for _e in $_exts; do
			_u="$ROK_DIST/download/v$_v/rok-$_v-$_t.$_e"
			if retry -- curl -fsSL --proto '=https,file' -o "$_tmp/rok-$_v-$_t.$_e" "$_u" 2> /dev/null; then
				_ar="$_tmp/rok-$_v-$_t.$_e"
				break
			fi
		done
		[ -n "$_ar" ] || die "rok $_v has no $_t archive at $ROK_DIST/download/v$_v/"
		download "$_u.sha256" "$_ar.sha256"
		check_sum "$_ar" "$_ar.sha256"
		if [ -n "$_attest" ]; then
			gh_attest_verify "$_ar" "$ROK_REPO" ||
				die "$(basename "$_ar") has no valid build attestation from $ROK_REPO"
		fi
	fi

	mkdir "$_tmp/files"
	unpack "$_ar" "$_tmp/files"
	_src=$(find "$_tmp/files" -mindepth 2 -maxdepth 2 -name bin -type d | head -n 1)
	[ -n "$_src" ] || die "$(basename "$_ar") is not a rok toolchain (no bin/)"
	_src=$(dirname "$_src")
	_full=$("$_src/bin/rokc" --version | awk 'NR == 1 { print $2 }') || die "cannot run rokc from $(basename "$_ar")"
	[ "$_full" = "$_v" ] || die "$(basename "$_ar") holds rok $_full, not $_v"
	mkdir -p "$_home"
	ROK_HOME=$(native_path "$_home") "$_src/bin/rok" -q toolchain install "$_full" --from "$(native_path "$_src")"
	ROK_HOME=$(native_path "$_home") "$_src/bin/rok" -q toolchain default "$_full"
	"$_home/bin/rok" --version > /dev/null || die "the installed $_home/bin/rok does not run"
	rm -rf "$_tmp"
	echo "version=$_v"
	echo "bin=$_home/bin"
}

cmd=${1:-}
[ $# -eq 0 ] || shift
case $cmd in
pin) pin_of "$1" ;;
kind) pin_kind "$1" ;;
resolve) resolve "$1" ;;
triple) triple ;;
install) install "$@" ;;
*)
	echo "usage: toolchain.sh pin|kind|resolve|triple|install ..." >&2
	exit 2
	;;
esac
