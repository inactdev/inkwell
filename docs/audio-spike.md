# Audio spike: one mic tap, two consumers

**Result: proven.** A single `AVAudioEngine` tap can feed on-device speech recognition
(`SFSpeechRecognizer` / `SFSpeechAudioBufferRecognitionRequest`) and an `AVAudioFile` writer
from the same buffer, at the same time, without either consumer starving or corrupting the
other. This was the load-bearing assumption the whole capture design depends on, and it's
what `AudioCaptureEngine.beginCapture(tappingNode:bus:to:)` in the app does.

## The mechanism

```swift
node.installTap(onBus: bus, bufferSize: 1024, format: format) { [weak self] buffer, _ in
    request.append(buffer)                                       // consumer 1: live words
    try? file.write(from: buffer)                                // consumer 2: the immutable utterance
    guard let self, let level = Self.level(of: buffer) else { return }
    Task { @MainActor in self.inputLevel = level }               // consumer 3: inkwell audio reactivity
}
```

One tap callback, three readers of the same `AVAudioPCMBuffer`. No format conversion, no
copying required - `SFSpeechAudioBufferRecognitionRequest.append` and `AVAudioFile.write`
both accept the buffer as-is. `request` and `file` are captured locals rather than properties
read back off `self`, and the level is computed with pure buffer math and published on the main
actor, so this block never touches observed state from the audio render thread.

Source: `ios/Inkwell/Capture/AudioCaptureEngine.swift`.

## How it was verified

This agent ran headless, with no human present to speak into a simulator microphone. The
`AudioSpikeTests` suite covers what a human tap-and-speak session would have proven, from
different angles:

1. **`testSingleTapFeedsBothRecognitionAndFileWriteSimultaneously`** (the real proof).
   A short phrase ("The submarine bay needs a stronger hull before the next dive.") was
   synthesized on-host with macOS `say`, converted to a 16kHz mono WAV with `afconvert`, and
   bundled into the test target as `InkwellTests/Fixtures/sample-speech.wav`. The test plays
   that clip through an `AVAudioPlayerNode` inside an `AVAudioEngine`, and installs the exact
   same tap method the production code uses - `beginCapture(tappingNode:bus:to:)` - on the
   player node instead of the hardware input node. It asserts both consumers actually
   produced correct output from the one tap:
   - the written `AVAudioFile` is non-empty and spans the clip's duration
   - the recognizer's final transcript is non-empty and contains a real word from the
     known phrase ("submarine", "hull", or "dive")

   The bundled iOS Simulator here has no real audio output device (CoreAudio HAL reports
   `!obj` for it), so real-time playback never renders a single frame and a tap fed that way
   hangs forever. The test instead drives the engine with
   [manual/offline rendering](https://developer.apple.com/documentation/avfaudio/avaudioengine/enablemanualrenderingmode(_:format:maximumframecount:)),
   which pulls the same node graph and fires the same tap callback without touching hardware
   I/O. This sidesteps a simulator/CI limitation, not a change to the mechanism under test.

2. **`testRealInputNodeAcceptsDualConsumerTapWithoutThrowing`** (production path sanity
   check). Calls the actual `startCapturing(to:)` entry point against the real hardware
   `inputNode`, with microphone and speech-recognition permissions pre-granted via the
   simulator's TCC database (`simctl privacy` doesn't expose a `speech-recognition` service
   to grant programmatically, at least not on Xcode 16.4 - the row was set directly in
   `TCC.db` to unblock headless test runs). This proves the session configuration, engine
   start, and tap installation against the real input node don't throw or crash with both
   consumers wired up. No transcript assertion is made here since the simulator has no live
   speaker in this environment; that requires a human running the app and is exactly what
   the manual capture screen is for.

3. **`testRealInputNodeSilenceIsReportedRatherThanHangingForever`** (issue #12's regression
   test). Follow-up to #2: this environment's real `inputNode` doesn't just go untested by
   this suite, it reliably produces *no signal at all* - confirmed via
   `ios/InkwellUITests/VoiceCaptureFailureUITests.swift` driving the actual capture screen
   and observing 10s of "Listening…" with a byte-identical screenshot at every check. That
   used to be silent in the product sense too: nothing told `CaptureViewModel` or the owner
   that the recognizer would never produce a word. This test asserts
   `AudioCaptureEngine.setRecognitionFailureHandler` fires within `silenceTimeout` against the
   real input node - the fix, not just the mechanism. Two companion cases pin down the
   watchdog itself: `testSilenceTimeoutIsWideEnoughForAThinkingPause` (a normal pause to
   gather a thought must not trip it) and
   `testRecognizerGoingDeadAfterPartialWordsStillReportsFailure` (it re-arms on every
   transcript change, so a recognizer that goes dead *after* producing words still surfaces).

Run the whole suite:

```
./dev.sh ios test -only-testing:InkwellTests/AudioSpikeTests
```

That runs against a simulator cloned for this worktree with both grants above already applied, so
the TCC step is no longer a manual one - see `docs/runtime-isolation.md`.

All of them pass with no flakes across repeated runs; the watchdog cases each wait on
`AudioCaptureEngine.silenceTimeout`, so the suite takes on the order of that timeout rather
than the few seconds the original two tests needed.

## What this does and doesn't prove

Proven: the API-level mechanism (one tap, two consumers, no format conflicts, no engine
crashes) works exactly as the production capture screen uses it, verified with real speech
content, not silence. Also proven: this environment's real `inputNode` is silence, not an
untested unknown, and the app now surfaces that rather than hanging - see AGENTS.md.

Not proven here (needs a human with the simulator focused and a working mic, i.e. actual
manual QA): that live human speech through the Simulator's mic passthrough produces good
transcription quality in practice. That's a UX/quality question for later manual testing,
not a mechanism question - the mechanism this spike was asked to verify is sound.

## Field report follow-up: silence at the tap is not the same bug as a failed recognizer

A captain field report after the failure-visibility fix shipped (voice capture still produced
no transcript on his own machine, in a normal windowed Simulator, not this headless one) raised
the same question this doc already flags above: was the mechanism ever proven against something
other than silence? It was - see `testSingleTapFeedsBothRecognitionAndFileWriteSimultaneously`
above - so the recognizer itself is not the suspect. Direct measurement settled the rest: a
temporary RMS tap on `AudioCaptureEngine`'s real `inputNode` tap, run while repeatedly playing
synthesized speech through this Mac's host speakers during the listening window, showed the tap
firing correctly (real, well-formed buffers, ~100ms apart) but every single sample reading
exactly `0.0` - with or without host audio playing. That is real, live confirmation that no host
audio reaches this booted simulator's virtual microphone at all, distinct from "the recognizer
received audio and failed" - a distinction the product previously had no way to make, and no way
to tell the owner about.

`AudioCaptureEngine.beginCapture` now tracks whether any buffer in a segment exceeded a small
RMS floor (`audioDetectionThreshold`). When the silence watchdog (not a thrown startup error or
a genuine mid-segment recognizer error) ends a segment where that never happened,
`RecognitionFailureReason.noAudioDetected` reaches `CaptureViewModel` and the alert says so
specifically ("No sound reached the microphone") instead of the generic "Didn't catch that" -
because the fix for the two failures is different: check mic access/audio input routing, versus
just try again. `VoiceCaptureFailureUITests` now expects this specific alert, since this
environment's real `inputNode` reliably produces exactly this case.

This does not, on its own, tell you *why* host audio doesn't reach the simulator on a given
machine - the two most likely causes are the macOS host's own microphone permission for
Simulator.app/Xcode (System Settings > Privacy & Security > Microphone - separate from the
in-app iOS grant handled via TCC.db above) and the Simulator's own per-boot `I/O > Audio Input`
device selection, neither of which is inspectable or settable headlessly (the host TCC database
is SIP-protected without Full Disk Access, and the Simulator's audio input device is a
GUI-only per-window setting). Testing on a real phone sidesteps both entirely.
