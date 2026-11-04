#!/bin/sh
. "$(dirname "$0")/lib.sh"
. "$root/lib/manifest.sh"
c=$root/lib/manifest-check.sh
m=$root/release/pipeline.json

t_case "placeholders"
v=$(manifest_vars 0.2.1 0.2.0)
eq "$(manifest_expand "toolchain {pinned} of {series}, v{version}" "$v")" "toolchain 0.2.0 of 0.2, v0.2.1"
err=$(manifest_expand "x {prev}" "$v" 2>&1) && fail "unknown placeholder expanded"
has "$err" "uses {prev}"
eq "$(manifest_expand "{editor_version}" "$(manifest_vars 0.2.1 "" '{"editor_version":"0.2.0"}')")" 0.2.0

t_case "component lookup"
eq "$(manifest_component "$m" docs | jq -r .repo)" rok-lang/docs
eq "$(manifest_ids "$m" stone | tr '\n' ' ')" "json toml http markdown rok-syntax "

t_case "the manifest passes offline"
sh "$c" "$m" > /dev/null || fail "offline check"

# bad <jq edit> <message>
bad() {
	jq "$1" "$m" > "$SHIM/bad.json"
	err=$(sh "$c" "$SHIM/bad.json" 2>&1) && fail "accepted: $1"
	has "$err" "$2"
}
t_case "offline findings"
bad '.components += [.components[0]]' "id milestone is used 2 times"
bad '.components[0].repo = "someone/rok"' "outside rok-lang"
bad '.components[2].health[0].expect = "{tag}"' "unknown placeholder {tag}"
bad '(.components[] | select(.id == "rok-lang.org")) |= del(.pin)' "uses {pinned} but has no pin"
bad '(.components[] | select(.id == "json")).deploy = {via: "infra", workflow: "x.yml", box: "x"}' "deploy is for sites"
bad '(.components[] | select(.id == "docs")).health[0].url = "http://docs.rok-lang.org/x"' "does not parse"
bad '(.components[] | select(.id == "docs")).gate = "warn"' "gate without next"
bad '(.components[] | select(.id == "rok-lang.org")).health[0].expect = "0.2.0"' 'expects "key value"'

# a GitHub where every fact of the manifest is true
live_state() {
	jq -n --slurpfile m "$m" '
		def wf(fs): reduce fs[] as $f ({}; .[".github/workflows/\($f)"] = "on: push");
		{repos: (reduce ($m[0].components[] | select(.kind != "infra")) as $c ({};
			.[$c.repo].files.main += wf($c.checks // [])
			| if $c.pin then .[$c.repo].files[$c.pin.ref][$c.pin.file] = "Package {\n    toolchain: \"0.2\",\n}" else . end))}
		| .repos["rok-lang/rok"].files.main["release-targets.json"] = ({targets: [{"runs-on": "ubuntu-24.04"}, {"runs-on": "macos-26"}, {"runs-on": "windows-2022"}]} | tojson)
		| .repos["rok-lang/rok"].files.main[".github/workflows/release.yml"] = "on: push"' > "$SHIM/state.json"
}

t_case "live: all true"
live_state
out=$(sh "$c" --live "$m" 2>&1) || fail "live: $out"
has "$out" "rok-lang/infra is not visible to this token"

t_case "live: a missing workflow, a bad pin, a missing repo"
jq '.repos["rok-lang/rok.vim"].files.main = {}
	| .repos["rok-lang/json"].files.main["rok.rokon"] = "Package {\n    toolchain: \"^0.2\",\n}"
	| del(.repos["rok-lang/toml"])' "$SHIM/state.json" > "$SHIM/s" && mv "$SHIM/s" "$SHIM/state.json"
err=$(sh "$c" --live "$m" 2>&1) && fail "accepted"
has "$err" "rok-lang/rok.vim has no .github/workflows/sync.yml"
has "$err" 'json: rok-lang/json rok.rokon@main: toolchain "^0.2" is not a pin'
has "$err" "repo rok-lang/toml does not exist"

t_case "live: an exact pin is a notice"
live_state
jq '.repos["rok-lang/http"].files.main["rok.rokon"] = "Package {\n    toolchain: \"0.2.0\",\n}"' "$SHIM/state.json" > "$SHIM/s" && mv "$SHIM/s" "$SHIM/state.json"
out=$(sh "$c" --live "$m" 2>&1) || fail "exact pin refused"
has "$out" 'http pins exact toolchain "0.2.0"'

t_case "live: a file without a pin"
live_state
jq '.repos["rok-lang/markdown"].files.main["rok.rokon"] = "Package {\n}"' "$SHIM/state.json" > "$SHIM/s" && mv "$SHIM/s" "$SHIM/state.json"
err=$(sh "$c" --live "$m" 2>&1) && fail "accepted"
has "$err" 'markdown: rok-lang/markdown rok.rokon@main pins no toolchain'

t_case "live: a smoke runner no target uses"
live_state
jq '.repos["rok-lang/rok"].files.main["release-targets.json"] = ({targets: [{"runs-on": "ubuntu-24.04"}]} | tojson)' "$SHIM/state.json" > "$SHIM/s" && mv "$SHIM/s" "$SHIM/state.json"
err=$(sh "$c" --live "$m" 2>&1) && fail "accepted"
has "$err" "smoke runner macos-26 is not the runs-on"
