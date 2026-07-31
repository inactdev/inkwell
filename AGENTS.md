# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Interface between the iOS app and the Go backend: `docs/api-contract.md`. Treat it as load-bearing - later lanes depend on these shapes.
- Audio spike result and how it was verified in a headless simulator (no live mic): `docs/audio-spike.md`.
- Running anything (backend or iOS) day to day: `./dev.sh` from the repo root, never `go run .` /
  `xcodegen generate` / `xcodebuild` directly - it gives the current worktree its own port,
  storage, DerivedData path, and cloned simulator so parallel worktrees can't collide at runtime.
  See `docs/runtime-isolation.md`.
- `ios/Inkwell.xcodeproj` is generated, not committed. Run `./dev.sh ios generate` after pulling or
  after adding/removing source files, before opening in Xcode or running `xcodebuild`.
- Simulator + XCUITest sharp edges hit while building this (all in this repo's headless dev environment, no human at the simulator):
  - `xcrun simctl privacy grant` has no `speech-recognition` service on Xcode 16.4 - grant it by editing `TCC.db` directly (`~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Library/TCC/TCC.db`, table `access`, `service='kTCCServiceSpeechRecognition'`, set `auth_value=2`). `microphone` works normally via `simctl privacy grant`. `./dev.sh ios sim` does both once, on a shared template device, and every worktree's simulator inherits them via `simctl clone` - no need to repeat this by hand per worktree.
  - `xcrun simctl uninstall` resets TCC grants for that bundle id even though the identity is nominally per-bundle-id, not per-install - re-grant after every uninstall/reinstall.
  - The app's container path from `xcrun simctl get_app_container <device> <bundle-id> data` changes on every fresh install (new UUID) - re-fetch it fresh each time rather than caching it across test runs, when polling on-disk state from outside the test.
  - `xcodebuild test`'s own setup time (build + install + launch, before "Test Case started") is highly variable in this environment - tens of seconds is normal, over a minute is not unusual. Don't assume a fixed short setup window when orchestrating anything time-sensitive around a test run.
  - `AVAudioEngine` real-time playback silently never renders in this headless environment (no real audio output device - CoreAudio HAL reports `!obj`). Use `enableManualRenderingMode(.offline, ...)` + `renderOffline` to drive the engine deterministically for tests instead.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
