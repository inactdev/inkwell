# Runtime isolation between worktrees

Git worktrees isolate source code. They do nothing about runtime: the backend binds a port and
writes into a storage directory, and Xcode/the Simulator have their own machine-wide shared state
(DerivedData, simulator devices, TCC permission grants). Two lanes running this repo at once would
fight over all of it. This is how collisions are made structurally impossible instead of "please
pick a free port" - see issue #3.

`./dev.sh` is the only documented way to run any of this. Don't call `docker compose` or
`xcodebuild` directly - the isolation lives entirely in what `dev.sh` derives and passes to them,
not in the tools themselves.

## Two layers

Xcode and the iOS Simulator cannot run inside a Linux container, so isolation is split across two
layers that both derive from the same worktree hash but use different mechanisms:

1. **Backend + storage** (containerized) - the Go backend, its listen port, and its markdown/git
   storage directory. Isolated with Docker Compose: one project per worktree.
2. **Native iOS build + test** (host-native) - Xcode's build output and the iOS Simulator. Neither
   can be containerized, so isolation here is a distinct DerivedData path plus a dedicated cloned
   simulator device per worktree, not a container boundary.

A lane never chooses between them or has to remember which is which - `./dev.sh` and
`./dev.sh ios ...` cover layer 1 and layer 2 respectively, and both derive from the same source of
truth (`scripts/inkwell-env.sh`).

## How identity is derived

Everything starts from `git rev-parse --show-toplevel` - the worktree's own absolute path, which is
already guaranteed unique per worktree and stable across restarts (same worktree, same path, every
time). `scripts/inkwell-env.sh` hashes that path (`shasum -a 256`) and derives:

| Identity                          | Derivation                                                          | Why this shape |
|------------------------------------|-----------------------------------------------------------------------|----------------|
| Compose project name (`INKWELL_PROJECT_NAME`) | `inkwell-<first 12 hex chars of the hash>`               | Prefixes the container, network, and image names Compose creates - a 48-bit hash makes two worktrees landing on the same name astronomically unlikely. |
| Backend port (`INKWELL_PORT`)      | `20000 + (first 8 hex chars of the hash, mod 10000)`, then scanned forward | A 16-bit port space can't rely on hashing alone to *guarantee* no collision (pigeonhole), so the candidate is only a starting point - see below. |
| Storage dir (`INKWELL_STORAGE_DIR`) | `<worktree>/backend/data`                                           | Needs no hash at all: it's already unique by living inside the worktree's own directory tree, and it's the same path `go run .` uses by default, so switching between `dev.sh` and running the binary directly doesn't move your data. |
| Simulator name (`INKWELL_SIM_NAME`) | `Inkwell-<first 12 hex chars of the hash>`                           | Same hash as the project name, for one name to grep for per worktree. |
| DerivedData path (`INKWELL_DERIVED_DATA`) | `<worktree>/ios/DerivedData`                                   | Same reasoning as storage dir - unique by location, not by hash. |
| Test proxy port (`INKWELL_TEST_PROXY_PORT`) | `40000 + (hex chars 17-24 of the hash, mod 10000)`, then scanned forward by the same `inkwell_free_port` | A distinct hash slice and base range from the backend port, so the two can never land on the same candidate for one worktree. Only `tools/blackhole-proxy` binds it, for `OfflineSyncUITests`; it keeps no state, so unlike the backend port it needn't stay stable across restarts - it's launched fresh every `dev.sh ios test`. |
| Test proxy URL (`INKWELL_TEST_PROXY_URL`) | `http://127.0.0.1:<INKWELL_TEST_PROXY_PORT>`                    | What `dev.sh ios test` bakes into the Test scheme and the test hands to the app under test, in place of the real backend URL. |

**The port is the one identity a hash genuinely can't make collision-*proof*** (65536 possible
values, an unbounded number of possible worktrees). `inkwell_free_port` closes that gap: starting
at the hashed candidate, it checks whether anything is actually listening on it; if so, it checks
whether the listener is *this worktree's own* previous container (via a `com.inkwell.worktree`
label Compose attaches - see `docker-compose.yml`) and reuses it if so, or walks forward to the
next port if it's a genuine stranger (another worktree's hash collision, or an unrelated process).
That makes the port assignment self-healing against the one case pure hashing can't rule out, while
staying deterministic for the overwhelmingly common case where the hash alone never collides.

## Why Docker Compose

Checked what's actually installed before assuming: OrbStack and Apple's `container` CLI are not
present on this machine; Docker Desktop is, with the `docker compose` v2 plugin already working.
Compose's per-project resource naming (`COMPOSE_PROJECT_NAME`) is exactly the primitive this needs
- set it from the worktree hash and container/network/image names all inherit it for free - and it
adds nothing to the backend itself: `backend/Dockerfile` builds the existing zero-dependency binary
unchanged (plus `git`, which the backend already shells out to), so `go.mod` never grows a runtime
dependency. If OrbStack or `container` get installed later, this compose file is portable to either
with no changes - both speak the same Compose format - so there's no cost to revisiting the choice
once they're available.

## What happens on a third worktree, a fourth, ...

Nothing to edit. Each new worktree hashes to its own port/project/storage/simulator the first time
`./dev.sh` runs in it, the same way the second one did. There's no port list, allocation file, or
registry to update - the worktree's own path *is* the registry key.

## Commands

```
./dev.sh                regenerate the Xcode project, ensure + boot this worktree's simulator,
                          then start the backend (foreground; Ctrl-C stops it). The iOS half is
                          best-effort: no Xcode/xcodegen and it continues backend-only.
./dev.sh down            stop it, and delete this worktree's simulator + DerivedData
./dev.sh ps               show this worktree's backend container
./dev.sh logs             follow this worktree's backend logs
./dev.sh info             print this worktree's derived port/storage/simulator/etc
./dev.sh ios generate    regenerate the Xcode project with this worktree's backend URL baked in
./dev.sh ios sim          ensure + boot this worktree's simulator, print its UDID
./dev.sh ios test         xcodebuild test against this worktree's simulator + DerivedData
./dev.sh ios build        xcodebuild build, same isolation
./dev.sh ios clean        backstop: delete this worktree's simulator + DerivedData now
```

`go run .` inside `backend/` still works exactly as before (see `backend/README.md`) - useful for
quick iteration on the backend alone - but it isn't isolated from another worktree's `go run .`,
and it's the same reason `xcodegen generate` / `xcodebuild` shouldn't be run directly either: they
lose the per-worktree derivation. `./dev.sh` is the only path that carries it, and it's not more
typing than what it replaces.

## How the app finds its own backend

`ios/Inkwell/Sync/AppConfig.swift` reads `INKWELL_BACKEND_URL` baked into the app's own
`Info.plist` at build time (`dev.sh ios generate` sets it as a build setting, resolved into
Info.plist by Xcode's own `$(VAR)` processing). This is deliberately *not* a scheme-level
environment variable: `XCUIApplication().launch()` in a UI test does not reliably inherit the
Xcode scheme's environment variables - only the process that invokes it does - so a UI test's
app-under-test would otherwise silently fall back to the hardcoded `127.0.0.1:8080` default and
sync to the wrong (or no) backend. Confirmed by pointing a decoy backend at `8080` and watching a
UI-test-driven capture land there instead of the real one, with `xcodebuild test` still reporting
success throughout (the sync failure is swallowed, by design, per `docs/api-contract.md`'s offline
semantics) - baking the URL into the bundle instead makes it correct regardless of which process
does the launching. An actual `INKWELL_BACKEND_URL` environment variable still overrides it, for
pointing a running app at a different backend by hand.

## The iOS Simulator: one clone per worktree

AGENTS.md documents that granting `speech-recognition` access requires editing `TCC.db` directly -
`simctl privacy` has no service for it. Re-doing that by hand for every worktree would be exactly
the kind of thing this task exists to eliminate. Instead, `dev.sh ios sim` maintains one
machine-wide template simulator (`InkwellSimTemplate`, created once) with both the microphone grant
(via `simctl privacy`) and the speech-recognition grant (via the `TCC.db` edit) already applied, and
every worktree gets its own simulator via `xcrun simctl clone` of that template.

`simctl clone` copies the entire device data volume, including `TCC.db` - confirmed by creating a
template, granting both permissions, cloning it, and inspecting the clone's `TCC.db` directly - so
every per-worktree clone starts already granted, with no manual step and no risk of one lane's
`simctl uninstall` resetting another lane's grants (per AGENTS.md's note that grants reset on
uninstall even though the identity is nominally per-bundle-id): each worktree's simulator, and
therefore its TCC state, is entirely its own device.

### ...and it deletes itself again

A clone costs 1-3GB. One per worktree that outlives the lane is a real amount of disk to leak, and
"remember to run the cleanup command" is the same class of thing as "remember to pick a free port" -
so teardown is automatic, on two independent triggers:

1. **The stack comes down.** `./dev.sh down` deletes this worktree's simulator and its DerivedData
   right after taking the compose project down - not behind a flag.
2. **The device is shut down**, whether or not `dev.sh down` is ever run - quitting Simulator.app,
   `xcrun simctl shutdown`, shutting it down from the UI. Every path that boots this worktree's
   simulator also arms `scripts/inkwell-sim-watcher.sh`: a small detached (`nohup`ed, SIGHUP/SIGINT-
   ignoring) process that polls that one UDID and, the moment it is no longer `Booted`, deletes the
   device and DerivedData and exits. It survives the `dev.sh` that spawned it, including a Ctrl-C of
   `dev.sh ios test`, which shares its process group. A pidfile keyed by UDID
   (`$TMPDIR/inkwell-sim-watcher-<udid>.pid`, claimed atomically via `ln -s` with the watcher's own
   pid) keeps repeated `dev.sh` runs from stacking up watchers on the same device.

`./dev.sh ios clean` is the manual backstop for when neither fired - a machine crash, a `kill -9`'d
watcher - and deletes this worktree's simulator (in whatever state) and DerivedData on demand.
