#!/bin/sh
# shellcheck disable=SC2016 # fixtures are literal shell text
. "$(dirname "$0")/lib.sh"
h=$root/lib/health.sh
web=$SHIM/http

t_case "parse healthz/1"
printf 'ok\nhealthz 1\ntoolchain 0.2.1\nlatest 0.2.1\nfailed_rounds 0\nfuture_key a b\n' > "$SHIM/b"
eq "$(sh "$h" parse "$SHIM/b" | tr '\n' ';')" "status ok;healthz 1;toolchain 0.2.1;latest 0.2.1;failed_rounds 0;future_key a b;"

t_case "parse today's playground body: release stands in for toolchain"
printf 'ok\nrelease 0.2.0\n' > "$SHIM/b"
eq "$(sh "$h" parse "$SHIM/b" | tr '\n' ';')" "status ok;release 0.2.0;toolchain 0.2.0;"
printf 'ok\nrelease 0.2.0\ntoolchain 0.2.1\n' > "$SHIM/b"
eq "$(sh "$h" parse "$SHIM/b" | grep toolchain)" "toolchain 0.2.1" "toolchain wins"

t_case "parse refuses a newer healthz and a non-healthz body"
printf 'ok\nhealthz 2\n' > "$SHIM/b"
err=$(sh "$h" parse "$SHIM/b" 2>&1) && fail "healthz 2 accepted"
has "$err" "newer than this checker reads"
printf '<!doctype html>\n' > "$SHIM/b"
err=$(sh "$h" parse "$SHIM/b" 2>&1) && fail "html accepted"
has "$err" "not a /healthz body"

mkdir -p "$web/rok-lang.org" "$web/playground.rok-lang.org" "$web/rokstones.io/api/v1/stones" "$web/docs.rok-lang.org"

t_case "healthz value"
printf 'ok\ntoolchain 0.2.0\nlatest 0.2.0\nfailed_rounds 0\n' > "$web/rok-lang.org/healthz"
sh "$h" check https://rok-lang.org/healthz "toolchain 0.2.0" 0 > /dev/null || fail "toolchain 0.2.0"
err=$(sh "$h" check https://rok-lang.org/healthz "toolchain 0.2.1" 0 2>&1) && fail "0.2.1 passed"
has "$err" 'toolchain is "0.2.0", want "0.2.1"'
eq "$(calls 'CURL https://rok-lang.org/healthz\?check=')" 2 "cache-busting query"

t_case "a failing server"
printf 'failing\ntoolchain 0.2.0\n' > "$web/rok-lang.org/healthz"
echo 503 > "$web/rok-lang.org/healthz.status"
err=$(sh "$h" check https://rok-lang.org/healthz "toolchain 0.2.0" 0 2>&1) && fail "failing passed"
has "$err" "reports failing"
rm "$web/rok-lang.org/healthz.status"

t_case "poll until the new binary answers"
printf 'ok\nrelease 0.2.0\n' > "$web/playground.rok-lang.org/healthz.1"
printf 'ok\nrelease 0.2.0\n' > "$web/playground.rok-lang.org/healthz.2"
printf 'ok\nrelease 0.2.1\n' > "$web/playground.rok-lang.org/healthz"
out=$(sh "$h" check https://playground.rok-lang.org/healthz "toolchain 0.2.1" 60 2> "$SHIM/err")
has "$out" "ok: https://playground.rok-lang.org/healthz"
eq "$(calls '^SLEEP 5$')" 2 "two waits"
has "$(cat "$SHIM/err")" 'waiting: https://playground.rok-lang.org/healthz: toolchain is "0.2.0"'

t_case "the budget runs out"
echo 0 > "$SHIM/clock"
printf '#!/bin/sh\necho $(($(cat "$SHIM/clock") + $1)) > "$SHIM/clock"\n' > "$SHIM/bin/tick"
chmod +x "$SHIM/bin/tick"
err=$(HEALTH_NOW="cat $SHIM/clock" HEALTH_SLEEP=tick sh "$h" check https://rok-lang.org/healthz "toolchain 9.9.9" 12 2>&1) && fail "passed"
has "$err" "(after 12s)"
eq "$(calls 'CURL https://rok-lang.org/healthz')" 4 "tries at 0 5 10 15"

t_case "body match and status"
printf '{"latest":"0.2.0","released":["0.2.0"]}\n' > "$web/docs.rok-lang.org/versions.json"
sh "$h" check https://docs.rok-lang.org/versions.json '"latest":"0.2.0"' 0 > /dev/null || fail "versions.json"
err=$(sh "$h" check https://docs.rok-lang.org/nope 'x' 0 2>&1) && fail "404 passed"
has "$err" "HTTP 404"

t_case "no network"
echo 1 > "$web/docs.rok-lang.org/versions.json.net"
err=$(sh "$h" check https://docs.rok-lang.org/versions.json '"latest"' 0 2>&1) && fail "no network passed"
has "$err" "Could not resolve host"

t_case "index lag"
state '{repos: {"rok-lang/rokstones.io-index": {files: {main: {
	"config.rokon": "Config { format: 2 }",
	"README.md": "x",
	".github/workflows/deploy.yml": "x",
	"js/on/json": "Stone { name: \"json\", version: \"0.1.0\", deps: [], yanked: false }\nStone { name: \"json\", version: \"0.2.0\", deps: [], yanked: false, toolchain: \"0.2\" }",
	"to/ml/toml": "Stone { name: \"toml\", version: \"0.2.0\", deps: [], yanked: true }"}}}}}'
printf 'Stone { versions: [Version { version: "0.2.0", yanked: false, deps: [] }] }' > "$web/rokstones.io/api/v1/stones/json"
printf 'Stone { versions: [Version { version: "0.2.0", yanked: false, deps: [] }] }' > "$web/rokstones.io/api/v1/stones/toml"
err=$(sh "$h" check index-lag:rokstones.io 0 0 2>&1) && fail "a stale yank passed"
has "$err" "does not serve toml@0.2.0 yet"
sh "$h" check index-lag:rokstones.io 1 0 > /dev/null || fail "lag 1 allowed"
printf 'Stone { versions: [Version { version: "0.2.0", yanked: true, deps: [] }] }' > "$web/rokstones.io/api/v1/stones/toml"
sh "$h" check index-lag:rokstones.io 0 0 > /dev/null || fail "in sync"
eq "$(calls 'CURL https://rokstones.io/api/v1/stones/(json|toml)')" 6 "one request per stone per try"

t_case "compile probe"
mkdir -p "$web/playground.rok-lang.org/api"
printf '\0asm' > "$web/playground.rok-lang.org/api/compile"
echo 'content-type: application/wasm' > "$web/playground.rok-lang.org/api/compile.headers"
sh "$h" check compile:playground.rok-lang.org - 0 > /dev/null || fail "wasm"
echo 'content-type: text/plain' > "$web/playground.rok-lang.org/api/compile.headers"
err=$(sh "$h" check compile:playground.rok-lang.org - 0 2>&1) && fail "text passed"
has "$err" "not wasm"

t_case "component checks from the manifest, pin resolved"
jq '.repos["rok-lang/rok"] = {releases: [{tag_name: "v0.2.0", prerelease: false, draft: false}]}
	| .repos["rok-lang/rok-lang.org"] = {files: {release: {"rok.rokon": "Package {\n    toolchain: \"0.2\",\n}"}}}' \
	"$SHIM/state.json" > "$SHIM/s2" && mv "$SHIM/s2" "$SHIM/state.json"
printf 'ok\ntoolchain 0.2.0\nlatest 0.2.0\nfailed_rounds 0\n' > "$web/rok-lang.org/healthz"
printf 'version="${ROK_VERSION:-0.2.0}"\n' > "$web/rok-lang.org/install.sh"
HEALTH_NOW="date +%s" sh "$h" component "$root/release/pipeline.json" rok-lang.org 0.2.0 > "$SHIM/out" || fail "rok-lang.org: $(cat "$SHIM/out")"
eq "$(grep -c '^ok:' "$SHIM/out")" 2 "both checks"
eq "$(calls 'GET repos/rok-lang/rok-lang.org/contents/rok.rokon\?ref=release')" 1 "pin read at the release branch"

t_case "component: an unknown id, and a check without a given placeholder"
err=$(sh "$h" component "$root/release/pipeline.json" nope 0.2.0 2>&1) && fail "unknown id"
has "$err" 'no component "nope"'
err=$(sh "$h" component "$root/release/pipeline.json" rok.vscode 0.2.0 2>&1) && fail "no editor_version"
has "$err" "uses {editor_version}, which this check was not given"

t_case "component: extra placeholder values"
mkdir -p "$web/open-vsx.org/api/rok-lang"
printf '{"name":"rok","version":"0.2.0"}' > "$web/open-vsx.org/api/rok-lang/rok"
sh "$h" component "$root/release/pipeline.json" rok.vscode 0.2.0 "" '{"editor_version":"0.2.0"}' > /dev/null || fail "editor_version"
