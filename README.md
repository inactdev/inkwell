# Inkwell

Capturing an idea should be faster than forgetting it. Inkwell is a well you tap: it listens,
words appear, you hit done, and it's safe on the phone before anything touches a network. This
is the **walking skeleton** - one screen, local persistence, a local backend, and sync between
them - that three later lanes build on. See `/docs/api-contract.md` for the interface between
the two halves and `/docs/audio-spike.md` for the proof that the core audio mechanism works.

## The two halves

- **`ios/`** - the SwiftUI app. One screen: tap the inkwell, dictate, tap the words to edit,
  done saves instantly and locally, no network involved.
- **`backend/`** - a small Go server. Receives a captured inkling, writes it as markdown with
  YAML front matter into a git repo, and commits.

## Running the stack

Every worktree gets its own backend port, storage directory, and (for iOS) simulator, derived
automatically - so two lanes never collide at runtime the way they would fighting over the same
port and data. `./dev.sh` is the only documented way to run any of it; see
`docs/runtime-isolation.md` for how and why.

```
./dev.sh
```

Starts the backend in the foreground, on this worktree's own port and storage - no more typing
than `go run .` was. `./dev.sh info` prints exactly what got derived; `./dev.sh down` stops it.
`go run .` from `backend/` (see `backend/README.md`) still works for quick backend-only iteration,
just without the isolation - fine for a single lane, not for running two at once.

## Running the iOS app

Requires Xcode 16.4 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install
xcodegen`) - the `.xcodeproj` is generated from `ios/project.yml` and isn't committed.

```
./dev.sh ios generate
open ios/Inkwell.xcodeproj
```

This bakes this worktree's backend URL into the generated project's Run and Test schemes, so the
app already reaches its own worktree's backend in the simulator - nothing to edit by hand. Build
and run on an iPhone 16 simulator (Product > Run). Grant microphone and speech recognition access
when prompted - tapping the well starts a dictation segment, so capture needs both, and declining
either leaves nothing to capture with. Tapping the words hands over the keyboard, so they can be
typed or corrected by hand from there.

Test suites: `InkwellTests` (the audio spike proof, plus the capture state-machine regressions -
duplicate inklings, a failed save, interrupted segments) and `InkwellUITests` (the capture flow,
the offline-then-sync scenario, and a long dictation staying scrollable on screen, driven through
the real UI). `./dev.sh ios test` builds and runs them against a simulator device cloned just for
this worktree, so two worktrees testing at once don't share a device, DerivedData, or app install
(see `docs/runtime-isolation.md`) - equivalent to Xcode's Test navigator or
`xcodebuild test -only-testing:<TargetName>/<ClassName>`, minus the collision risk.

## Why Go for the backend

The backend's whole job is: accept a small JSON+audio payload, write markdown, run `git commit`.
It runs on a small VPS for one person, and needs to still work in ten years with basically no
maintenance - that's the constraint that mattered most in choosing a stack, more than any team's
familiarity with a particular language.

Go compiles to a single static binary with no runtime to install, update, or eventually rot out
from under it - copy the binary to the VPS and run it. The standard library covers everything
this needs (`net/http` for the server, `encoding/json`, `os/exec` to shell out to the system
`git`), so the backend has **zero external dependencies** - nothing in `go.mod` to go stale,
get yanked, or need a security patch a decade from now. Even the front matter is hand-rolled
(`backend/frontmatter.go`) rather than pulling in a YAML library, since the schema is three plain
scalar fields with nothing that needs real YAML parsing. A person with just Go's standard tooling
(itself famously stable across major versions) can read, build, and run this entire backend
without resolving a single dependency tree.

The tradeoff is writing a little more code by hand (form parsing, the front-matter format) than a
framework-heavy stack would need. For a service this small, that's a good trade against "no
runtime or dependency rot to maintain."

## What's deliberately not here

Per the product contract, this lane does not include: App Intents/Siri/the Action Button/widgets
(the "capture door"), the real browse experience or search, server-side parsing or research
agents, anything GitHub, or deployment (the backend runs locally; a VPS is a config change to
`--addr`/`--storage-dir`, not a code change). See `/docs/api-contract.md` for the full picture of
what's intentionally deferred to later lanes.

## Repo layout

```
ios/              SwiftUI app (project.yml is the source of truth; .xcodeproj is generated)
backend/          Go backend (Dockerfile builds it for dev.sh; the binary itself is unchanged)
scripts/          dev.sh's per-worktree identity derivation
dev.sh            the only documented way to run the stack - see docs/runtime-isolation.md
docker-compose.yml   backend/storage isolation layer, driven by dev.sh
docs/
  api-contract.md         the JSON/endpoint/front-matter contract between the two halves
  audio-spike.md           the audio spike result, proven, with how it was verified
  runtime-isolation.md     why/how two worktrees never collide at runtime
  screenshots/              capture flow + offline-sync evidence, at iPhone size
```
