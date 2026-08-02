# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Interface between the iOS app and the Go backend: `docs/api-contract.md`. Treat it as load-bearing - later lanes depend on these shapes.
- Audio spike result and how it was verified in a headless simulator (no live mic): `docs/audio-spike.md`.
- Running anything (backend or iOS) day to day: `./dev.sh` from the repo root, never `go run .` /
  `xcodegen generate` / `xcodebuild` directly - it gives the current worktree its own port,
  storage, DerivedData path, and cloned simulator so parallel worktrees can't collide at runtime.
  `./dev.sh` with no arguments ends with the app built, installed, and launched on that simulator,
  not just the environment prepared. See `docs/runtime-isolation.md`.
- `ios/Inkwell.xcodeproj` is generated, not committed. Run `./dev.sh ios generate` after pulling or
  after adding/removing source files, before opening it in Xcode - `./dev.sh ios build|test`
  regenerate it themselves first.
- Simulator + XCUITest sharp edges hit while building this (all in this repo's headless dev environment, no human at the simulator):
  - `xcrun simctl privacy grant` has no `speech-recognition` service on Xcode 16.4 - grant it by editing `TCC.db` directly (`~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Library/TCC/TCC.db`, table `access`, `service='kTCCServiceSpeechRecognition'`, set `auth_value=2`). `microphone` works normally via `simctl privacy grant`. `./dev.sh ios sim` does both once, on a shared template device, and every worktree's simulator inherits them via `simctl clone` - no need to repeat this by hand per worktree.
  - `xcrun simctl uninstall` resets TCC grants for that bundle id even though the identity is nominally per-bundle-id, not per-install - re-grant after every uninstall/reinstall.
  - The app's container path from `xcrun simctl get_app_container <device> <bundle-id> data` changes on every fresh install (new UUID) - re-fetch it fresh each time rather than caching it across test runs, when polling on-disk state from outside the test.
  - `xcodebuild test`'s own setup time (build + install + launch, before "Test Case started") is highly variable in this environment - tens of seconds is normal, over a minute is not unusual. Don't assume a fixed short setup window when orchestrating anything time-sensitive around a test run.
  - `AVAudioEngine` real-time playback silently never renders in this headless environment (no real audio output device - CoreAudio HAL reports `!obj`). Use `enableManualRenderingMode(.offline, ...)` + `renderOffline` to drive the engine deterministically for tests instead.
- Shell job-control sharp edge, not simulator-specific: to test `./dev.sh`'s Ctrl-C handling non-interactively, don't background it with a trailing `&` in your own shell - bash sets SIGINT to ignored for asynchronous jobs and no trap inside the child can override that, so it'll look like Ctrl-C does nothing. Launch it as a true foreground command (e.g. this harness's own background-task tracking) and signal that real PID instead.
- `xcrun simctl` has no touch/tap injection - to actually drive the UI (not just view or install it) in this headless environment, run an XCUITest (`ios/InkwellUITests`); `xcrun xcresulttool export attachments --path <bundle>.xcresult --output-path <dir>` pulls out any `XCTAttachment` screenshots it captured along the way.
- The app's mark (`ios/Inkwell/Capture/InkwellShape.swift` / `InkwellView.swift`) is a hand-traced SwiftUI reproduction of `design/inkwell.svg` (the owner's source artwork), not a generic shape - see that file's viewBox math (`InkwellArt.pt`/`InkwellArt.len`) before changing its geometry, and re-derive `InkwellView`'s `openingSize`/`openingOffsetY`/`markSize`/`containerSize` from the SVG's ink-face ellipse (not eyeballed) if the mark's size or proportions change.
- This headless Simulator's hardware `inputNode` reliably delivers *no* audio signal at all (confirmed: 10s of listening produced byte-identical screenshots and an untouched transcript, and separately confirmed by direct RMS measurement even while playing real speech through the host's own speakers into the listening window) - it is not a source of real speech, but it *is* a free, deterministic way to exercise a capture segment's silence/failure paths without a fixture. `AudioCaptureEngine.silenceTimeout` and the recognizer's error callback exist because that silence used to be indistinguishable from the recognizer quietly working: nothing surfaced it to `CaptureViewModel`/the UI (see `ios/InkwellTests/AudioSpikeTests.swift`'s `testRealInputNodeSilenceIsReportedRatherThanHangingForever` and `ios/InkwellUITests/VoiceCaptureFailureUITests.swift`). Any future change to the capture failure path should keep exercising it this way rather than only through a mock engine - it's the closest thing to a real recognizer failure this environment can produce on demand. This silence is "no audio reaches the tap," not "the recognizer fails" - `AudioCaptureEngine` tracks per-segment whether any buffer crossed a small RMS floor and reports `RecognitionFailureReason.noAudioDetected` vs `.recognitionFailed` accordingly, since the two need different remedies (mic/audio-input routing vs. just retry); see `docs/audio-spike.md`'s field-report follow-up for how this was diagnosed, including why host-level mic permission for Simulator.app and the Simulator's own audio-input device selection are both invisible/unsettable headlessly.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
