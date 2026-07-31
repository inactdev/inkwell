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

## Running the backend

```
cd backend
go run . --addr 127.0.0.1:8080 --storage-dir ./data
```

`--storage-dir` is `git init`'d automatically on first run if it isn't already a repo. Both
flags have env var equivalents (`INKWELL_ADDR`, `INKWELL_STORAGE_DIR`) - see `backend/README.md`.
Run `go test ./...` from `backend/` for the test suite.

## Running the iOS app

Requires Xcode 16.4 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install
xcodegen`) - the `.xcodeproj` is generated from `ios/project.yml` and isn't committed.

```
cd ios
xcodegen generate
open Inkwell.xcodeproj
```

Build and run on an iPhone 16 simulator (Product > Run, or `xcodebuild ... -destination
'platform=iOS Simulator,name=iPhone 16'`). The app talks to `http://127.0.0.1:8080` by default,
which reaches the Mac's own backend directly from the simulator - override with the
`INKWELL_BACKEND_URL` environment variable if you're running the backend elsewhere. Grant
microphone and speech recognition access when prompted to use dictation; typing works either way.

Test suites: `InkwellTests` (the audio spike proof, plus the capture state-machine regressions -
duplicate inklings, a failed save, an interrupted segment) and `InkwellUITests` (the capture flow
and the offline-then-sync scenario, driven through the real UI). Run via Xcode's Test navigator or
`xcodebuild test -only-testing:<TargetName>/<ClassName>`.

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
backend/          Go backend
docs/
  api-contract.md       the JSON/endpoint/front-matter contract between the two halves
  audio-spike.md         the audio spike result, proven, with how it was verified
  screenshots/            capture flow + offline-sync evidence, at iPhone size
```
