#!/bin/sh
. "$(dirname "$0")/lib.sh"
tc=$root/lib/toolchain.sh
triple=$(sh "$tc" triple)

state '{repos: {"rok-lang/rok": {releases: [
	{tag_name: "v0.20.0", prerelease: false, draft: false},
	{tag_name: "v0.3.0-rc.1", prerelease: true, draft: false},
	{tag_name: "v0.2.10", prerelease: false, draft: true},
	{tag_name: "v0.2.9", prerelease: false, draft: false},
	{tag_name: "v0.2.1", prerelease: false, draft: false},
	{tag_name: "v0.2.0", prerelease: false, draft: false},
	{tag_name: "v0.1.6", prerelease: false, draft: false}]}}}'

t_case "pin from rok.rokon"
printf 'Package {\n    name: "x",\n    toolchain: "0.2",\n}\n' > "$SHIM/rok.rokon"
eq "$(sh "$tc" pin "$SHIM/rok.rokon")" 0.2
printf 'Package {\n    name: "x",\n}\n' > "$SHIM/none.rokon"
err=$(sh "$tc" pin "$SHIM/none.rokon" 2>&1) && fail "no pin accepted"
has "$err" 'add toolchain: "0.2"'

t_case "resolve"
eq "$(sh "$tc" resolve 0.2)" 0.2.9 "series: newest final, drafts and 0.20 left out"
eq "$(sh "$tc" resolve 0.2.1)" 0.2.1 exact
eq "$(sh "$tc" resolve 0.3.0-rc.1)" 0.3.0-rc.1 prerelease
err=$(sh "$tc" resolve 0.2.10 2>&1) && fail "a draft resolved"
has "$err" 'no published rok release matches toolchain "0.2.10"'
err=$(sh "$tc" resolve 0.4 2>&1) && fail "0.4 resolved"
for bad in "0" "0.2.x" "^0.2" "v0.2" "0.2.0-beta"; do
	err=$(sh "$tc" resolve "$bad" 2>&1) && fail "pin $bad accepted"
	has "$err" 'write a series ("0.2")'
done

# fake_release <version> <dir>: an archive for this host plus .sha256
fake_release() {
	_s=$SHIM/src/rok-$1-$triple
	mkdir -p "$_s/bin"
	cat > "$_s/bin/rokc" << EOS
#!/bin/sh
echo "rokc $1"
EOS
	cat > "$_s/bin/rok" << 'EOS'
#!/bin/sh
[ "$1" = -q ] && shift
case "$1 $2" in
"toolchain install") mkdir -p "$ROK_HOME/toolchains/$3" && cp -R "$5/." "$ROK_HOME/toolchains/$3/" ;;
"toolchain default") mkdir -p "$ROK_HOME/bin" && printf '#!/bin/sh\necho "rok %s"\n' "$3" > "$ROK_HOME/bin/rok" && chmod +x "$ROK_HOME/bin/rok" ;;
*) exit 9 ;;
esac
EOS
	chmod +x "$_s/bin/rok" "$_s/bin/rokc"
	mkdir -p "$2"
	case $triple in
	*windows*) (cd "$SHIM/src" && zip -qr "$2/rok-$1-$triple.zip" "rok-$1-$triple") && _a=$2/rok-$1-$triple.zip ;;
	*) tar -czf "$2/rok-$1-$triple.tar.gz" -C "$SHIM/src" "rok-$1-$triple" && _a=$2/rok-$1-$triple.tar.gz ;;
	esac
	if command -v sha256sum > /dev/null; then _h=$(sha256sum "$_a" | cut -d' ' -f1); else _h=$(shasum -a 256 "$_a" | cut -d' ' -f1); fi
	echo "$_h *$(basename "$_a")" > "$_a.sha256"
}
dl=$SHIM/http/github.com/rok-lang/rok/releases/download
fake_release 0.2.9 "$dl/v0.2.9"

t_case "install the newest of a pin"
out=$(sh "$tc" install --home "$SHIM/home" --pin-file "$SHIM/rok.rokon")
has "$out" "version=0.2.9"
has "$out" "bin=$SHIM/home/bin"
eq "$("$SHIM/home/bin/rok" --version)" "rok 0.2.9"
eq "$(calls '^GET attestation')" 1 "attestation checked"
eq "$(calls 'tar.xz$')" "$(if command -v xz > /dev/null || [ "$(uname -s)" = Darwin ]; then echo 1; else echo 0; fi)" ".tar.xz tried first"

t_case "a lost network on the download is retried"
echo 1 > "$dl/v0.2.9/rok-0.2.9-$triple.tar.gz.net"
rm -rf "${SHIM:?}/home"
sh "$tc" install --home "$SHIM/home" --version 0.2.9 > /dev/null 2>&1 || fail "install after a network error"
eq "$(calls '^SLEEP 10$')" 1
rm -f "$dl/v0.2.9/rok-0.2.9-$triple.tar.gz.net"

t_case "a damaged archive is refused"
cp "$dl/v0.2.9/rok-0.2.9-$triple.tar.gz.sha256" "$SHIM/good.sha256"
echo "0000000000000000000000000000000000000000000000000000000000000000 *x" > "$dl/v0.2.9/rok-0.2.9-$triple.tar.gz.sha256"
err=$(sh "$tc" install --home "$SHIM/h2" --version 0.2.9 2>&1) && fail "bad sum accepted"
has "$err" "but its .sha256 says 0000"
[ ! -e "$SHIM/h2/bin/rok" ] || fail "installed anyway"
cp "$SHIM/good.sha256" "$dl/v0.2.9/rok-0.2.9-$triple.tar.gz.sha256"

t_case "a missing .sha256 is refused"
mv "$dl/v0.2.9/rok-0.2.9-$triple.tar.gz.sha256" "$SHIM/good.sha256"
err=$(sh "$tc" install --home "$SHIM/h3" --version 0.2.9 2>&1) && fail "no sum accepted"
has "$err" "cannot download"
mv "$SHIM/good.sha256" "$dl/v0.2.9/rok-0.2.9-$triple.tar.gz.sha256"

t_case "a failed attestation is refused, unless turned off"
touch "$SHIM/attest-fail"
err=$(sh "$tc" install --home "$SHIM/h4" --version 0.2 2>&1) && fail "bad attestation accepted"
has "$err" "no valid build attestation"
sh "$tc" install --home "$SHIM/h4" --version 0.2 --no-attest > /dev/null || fail "--no-attest"
rm -f "$SHIM/attest-fail"

t_case "a version without an archive"
err=$(sh "$tc" install --home "$SHIM/h5" --version 0.2.1 2>&1) && fail "installed nothing"
has "$err" "rok 0.2.1 has no $triple archive"

t_case "candidate run artifacts"
fake_release 0.2.10 "$SHIM/runs/77/dist-host"
out=$(sh "$tc" install --home "$SHIM/h6" --candidate-run 77)
has "$out" "version=0.2.10"
eq "$(calls '^GET attestation')" 0 "artifacts carry no attestation"
err=$(sh "$tc" install --home "$SHIM/h7" --candidate-run 78 2>&1) && fail "run 78"
has "$err" "cannot download the dist-* artifacts"

t_case "exactly one source"
err=$(sh "$tc" install --version 0.2 --candidate-run 77 2>&1) && fail "two sources"
has "$err" "exactly one of"
