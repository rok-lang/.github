<p align="center">
  <img src="https://raw.githubusercontent.com/rok-lang/web/main/assets/rok-transparent-512.png" alt="Rok" width="96">
</p>

<h1 align="center">rok-lang/.github</h1>

<p align="center">
  The org profile, the shared workflows, and the building blocks of the Rok release pipeline.
</p>

## What is here

| Path | What |
|---|---|
| `profile/README.md` | The org profile page |
| `.github/workflows/content.yml`, `deploy.yml` | Reusable workflows of the content repos and sites |
| `release/pipeline.json` | The manifest: every component a Rok release reaches, and what each one receives |
| `release/pipeline.schema.json` | Its JSON Schema (`schema: 1`) |
| `actions/<name>/action.yml` | Composite actions (below) |
| `lib/*.sh` | The shell the actions run; every GitHub API call goes through `lib/gh.sh`, every retry through `lib/retry.sh` |
| `tests/` | Hermetic tests of `lib/`, with fake `gh` and `curl` in `tests/shim/` |
| `rulesets/release-tags.json` | The tag ruleset this repo gets (same as rok's) |

## Versioning

- Releases are immutable tags `vMAJOR.MINOR.PATCH`. There is no moving `v1` tag; a moving tag
  would change every caller at once, untested.
- Callers pin an exact tag, never `@main`:
  `uses: rok-lang/.github/actions/install-rok@v1.0.0`.
  Dependabot (`github-actions` ecosystem) bumps the pins.
- A new optional input, a new manifest kind or a new probe is a minor release. A fix is a patch.
  A removed or renamed input, or a changed default, is a major release, and the previous major
  keeps working for one Rok series.
- The actions find `lib/` and `release/` through `github.action_path`, so an action at `v1.2.0`
  always runs the `lib/` of `v1.2.0`.

## Actions

Every action takes a `token` input that defaults to `github.token`; give it only the
permissions listed.

### `install-rok`

Installs a Rok toolchain from GitHub releases (never from a site), checks the archive against its
`.sha256`, and by default verifies its build attestation with `gh attestation verify`. Works on
Linux, macOS and Windows runners. Puts `bin` on `PATH` and sets `ROK_HOME`.

| Input | Default | |
|---|---|---|
| `version` | | A toolchain pin: `0.2` (the newest 0.2.x), `0.2.1` (exactly), `0.3.0-rc.1` |
| `pin` | | Path of a `rok.rokon`; installs what its `toolchain:` pin accepts |
| `candidate-run` | | A run id of `rok-lang/rok`; installs this host's archive from its `dist-*` artifacts (needs `actions: read`) |
| `home` | `~/.rok` | `ROK_HOME` |
| `attest` | `true` | Verify the build attestation (release installs only) |
| `repo` | `rok-lang/rok` | The toolchain repository |

Give exactly one of `version`, `pin`, `candidate-run`. Outputs: `version` (e.g. `0.2.1`), `bin`.
Permissions: `contents: read`.

### `health-check`

Polls until a check passes or its budget runs out, with a fresh query on every URL so the CDN
answers from the origin. With `component`, runs every `health[]` entry of that manifest
component, placeholders expanded.

| Input | Default | |
|---|---|---|
| `component` | | A manifest id; needs `version` |
| `version` | | Fills `{version}` and `{series}` |
| `pinned` | resolved | Fills `{pinned}`; by default the newest release the component's pin accepts |
| `vars` | | More values as JSON, e.g. `{"editor_version": "0.2.1"}` |
| `manifest` | this version's | Path of a manifest |
| `url`, `expect`, `budget` | `budget: 60` | One check instead of a component |
| `interval` | `60` | Seconds between tries |

What `expect` means depends on the URL:

- `https://.../healthz`: a `/healthz` body (line 1 `ok` or `failing`, then `key value` lines;
  `healthz 1`); `expect` is `key value`, and the server must report `ok`. A body that names the
  toolchain `release` (the playground today) is read as `toolchain`. A `healthz` newer than 1 is
  refused with a hint to update the blocks.
- other `https://...`: HTTP 200 and the body contains `expect`.
- `index-lag:<host>`: at most `expect` stones whose newest index line `<host>` does not serve yet.
- `compile:<host>`: `<host>/api/compile` builds a program to wasm.

No outputs; the step fails with the last reason. Permissions: `contents: read`.

### `alarm`

One issue per title, kept in step with a check: opened on the first red, commented on while red,
closed on the first green. An open issue with the same title and first label is reused.

| Input | Default | |
|---|---|---|
| `title` | required | The alarm's identity |
| `ok` | required | `true` or `false` |
| `body` | required | What happened, with links |
| `labels` | `alarm` | Labels of a new issue; the first narrows the search |
| `repo` | this repo | |

Outputs: `issue`, `action` (`opened`, `updated`, `closed`, `none`). Permissions: `issues: write`.

### `app-token`

Mints a token of the `rok-lang-release` App for named repositories and permissions, through
`actions/create-github-app-token` (SHA-pinned). The token is revoked when the job ends.

| Input | |
|---|---|
| `app-id`, `private-key` | The App's ID (or client ID) and key, from the environment secrets `RELEASE_APP_ID` and `RELEASE_APP_KEY` |
| `repositories` | `rok, docs` or `rok-lang/rok`; required, so no token covers the whole org |
| `permissions` | `contents:write, pull-requests:write`; required |

Allowed permissions: `contents`, `pull-requests`, `issues`, `actions`, `statuses` (read or
write), `administration` and `metadata` (read). `workflows` is refused: the App never writes
workflow files. Missing credentials fail the step and say which secrets to set. Output: `token`.

### `record`

Reads or updates the release record (`record: 1`), a JSON block in the release issue between
`<!-- record:begin -->` and `<!-- record:end -->`, with a table rendered above it. Text outside
the markers is left alone. The record is evidence and a cache, never the authority: re-observe
GitHub before acting on it.

| Input | Default | |
|---|---|---|
| `issue` | | The release issue |
| `title` | | Without `issue`: reuse the open issue with this title, or open it |
| `labels` | `release` | Labels of a new issue |
| `patch` | | A JSON object merged in (objects deeply, arrays replaced, `events` appended); empty reads |
| `repo` | this repo | |

A patch is refused when its `state` goes back, when it marks a release `ABANDONED` at or after
`TAGGED` (that version is burned) or `SUPERSEDED` before it, or when the record is already final
(`CLOSED`, `ABANDONED`, `SUPERSEDED`). A failed step is recorded as `blocked: {state, reason}`;
the state stays at the last good one. A patch that changes nothing writes nothing.
Outputs: `issue`, `record` (compact JSON), `state`. Permissions: `issues: write`.

## Retries

`lib/retry.sh` runs a command again on network errors, HTTP 5xx, 429 and rate limits, and git's
`RPC failed`, `early EOF` and `Could not resolve host`, after 10, 30, 90, 270 and 600 s (+-20%
jitter), within a budget (default 1100 s). A rate limit waits `Retry-After` or until
`x-ratelimit-reset` instead. Any other 4xx returns at once; on a 409 or 422 the caller looks at
GitHub again rather than repeating the write. Each retry is logged as a `::warning::`.

## The manifest

`release/pipeline.json` is plain JSON so that a runner can read it with `jq` even when the
newest Rok is broken. Host targets stay in `rok-lang/rok` `release-targets.json`, and deploy
addresses stay in the private infra repo; the manifest only names them.

To add a component of an existing kind, add one entry to `components` and open a PR:

```json
{ "id": "yaml", "kind": "stone", "repo": "rok-lang/yaml",
  "on": { "patch": "verify", "series": "pin-pr" },
  "pin": { "file": "rok.rokon", "ref": "main" },
  "publish": { "block": "stone-publish.yml", "registry": "rokstones.io", "environment": "release" },
  "checks": ["ci.yml"], "next": true, "gate": "block", "owner": "me" }
```

- `id` is unique; it names the component in records, alarms and run names.
- `checks` lists workflow files that exist in the repo today.
- `health[]` entries use `{version}`, `{series}`, `{prev}`, `{pinned}` or `{editor_version}`;
  `{pinned}` needs a `pin`.
- `gate` (`warn` or `block`) needs `next: true`.

CI validates the manifest against the schema, then `lib/manifest-check.sh --live` checks it
against GitHub: every repo exists, every `checks` workflow is there, every pin file holds a
toolchain pin, and the smoke runners match the toolchain's targets. A new kind needs a new
minor release of the blocks.

## Testing

```sh
tests/run.sh               # every test file
tests/run.sh retry record  # some
```

The tests put `tests/shim` first on `PATH`: a fake `gh` over a small GitHub in a JSON file, and
a fake `curl` over fixture files. Both log every call and inject faults (`502`, `429`, secondary
rate limit, lost network) per call, so the retry policy, idempotent writes and every refusal are
checked without the network. Needs `sh`, `jq`, `awk`, `tar`.

CI (`.github/workflows/ci.yml`) runs actionlint, shellcheck (also over the actions' `run:`
blocks), shfmt (`-sr`), zizmor, these tests on Linux and macOS, the manifest checks, and a real
`install-rok` on Linux, macOS and Windows.
