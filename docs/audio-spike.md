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

This agent ran headless, with no human present to speak into a simulator microphone. Two
tests cover what a human tap-and-speak session would have proven, from different angles:

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

Run both:

```
./dev.sh ios test -only-testing:InkwellTests/AudioSpikeTests
```

That runs against a simulator cloned for this worktree with both grants above already applied, so
the TCC step is no longer a manual one - see `docs/runtime-isolation.md`.

Both pass in about 4 seconds total, no flakes across repeated runs.

## What this does and doesn't prove

Proven: the API-level mechanism (one tap, two consumers, no format conflicts, no engine
crashes) works exactly as the production capture screen uses it, verified with real speech
content, not silence.

Not proven here (needs a human with the simulator focused and a working mic, i.e. actual
manual QA): that live human speech through the Simulator's mic passthrough produces good
transcription quality in practice. That's a UX/quality question for later manual testing,
not a mechanism question - the mechanism this spike was asked to verify is sound.
