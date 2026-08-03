import AVFoundation
import Speech
import XCTest
@testable import Inkwell

/// Proves the load-bearing assumption from the product contract: one
/// microphone tap can feed on-device speech recognition and an audio file
/// writer at the same time, without either consumer starving or corrupting
/// the other.
///
/// This test environment has no human present to speak into a simulator
/// microphone, so it substitutes a bundled, pre-synthesized speech clip
/// (`Fixtures/sample-speech.wav`, generated on-host via `say` + `afconvert`)
/// played through an `AVAudioPlayerNode` inside the same `AVAudioEngine`.
/// The tap-time code under test - `AudioCaptureEngine.beginCapture(tappingNode:bus:to:)`
/// - is byte-for-byte the same method the app uses against the real
/// `inputNode` in production; only the upstream audio source differs.
final class AudioSpikeTests: XCTestCase {

    func testSingleTapFeedsBothRecognitionAndFileWriteSimultaneously() throws {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        try XCTSkipUnless(recognizer?.isAvailable == true, "Speech recognizer not available in this environment")

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let fixtureURL = try XCTUnwrap(
            Bundle(for: AudioSpikeTests.self).url(forResource: "sample-speech", withExtension: "wav"),
            "sample-speech.wav fixture must be bundled in the test target"
        )
        let sourceFile = try AVAudioFile(forReading: fixtureURL)
        let renderFormat = sourceFile.processingFormat
        engine.connect(player, to: engine.mainMixerNode, format: renderFormat)

        // This headless simulator has no real audio output device (CoreAudio
        // HAL returns "!obj" for it), so real-time playback never actually
        // renders a single frame and the tap below would hang forever.
        // Manual/offline rendering drives the exact same node graph and tap
        // callback without touching hardware I/O, so it exercises the same
        // dual-consumer tap mechanism deterministically.
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)

        let capture = AudioCaptureEngine(audioEngine: engine)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkwell-spike-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        addTeardownBlock { try? FileManager.default.removeItem(at: outputURL) }

        let finalTranscriptExpectation = expectation(description: "recognizer produced a final transcript")
        var finalTranscript = ""
        capture.setFinalTranscriptHandler { transcript in
            finalTranscript = transcript
            finalTranscriptExpectation.fulfill()
        }

        // The method under test: ONE tap, installed once, feeding both
        // the recognition request and the audio file from the same buffer.
        try capture.beginCapture(tappingNode: player, bus: 0, to: outputURL)

        player.scheduleFile(sourceFile, at: nil)
        player.play()

        let pumpBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)
        )
        // Render an extra second past the clip's length so the recognizer has
        // trailing silence to settle on a final result before we call endAudio.
        let framesToRender = sourceFile.length + AVAudioFramePosition(renderFormat.sampleRate)
        var framesRendered: AVAudioFramePosition = 0
        while framesRendered < framesToRender {
            pumpBuffer.frameLength = 0
            let status = try engine.renderOffline(engine.manualRenderingMaximumFrameCount, to: pumpBuffer)
            switch status {
            case .success:
                framesRendered += AVAudioFramePosition(pumpBuffer.frameLength)
            case .insufficientDataFromInputNode:
                framesRendered += AVAudioFramePosition(engine.manualRenderingMaximumFrameCount)
            case .cannotDoInCurrentContext:
                continue
            case .error:
                XCTFail("renderOffline returned .error")
                return
            @unknown default:
                XCTFail("renderOffline returned an unknown status")
                return
            }
        }

        capture.stopCapture(tappedNode: player, bus: 0)
        engine.stop()

        wait(for: [finalTranscriptExpectation], timeout: 15)

        // --- Consumer 1: the file writer produced a real, non-empty audio file ---
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attributes[.size] as? Int) ?? 0
        XCTAssertGreaterThan(fileSize, 1000, "audio file should contain real PCM data, not be empty/near-empty")

        let writtenFile = try AVAudioFile(forReading: outputURL)
        XCTAssertGreaterThan(writtenFile.length, 0, "written audio file should have non-zero frame length")
        let writtenDurationSeconds = Double(writtenFile.length) / writtenFile.processingFormat.sampleRate
        XCTAssertGreaterThan(writtenDurationSeconds, 1.0, "written audio should span most of the ~2.8s source clip")

        // --- Consumer 2: the recognizer transcribed real words from the same tap ---
        XCTAssertFalse(finalTranscript.isEmpty, "recognizer should have produced a non-empty transcript")
        let normalized = finalTranscript.lowercased()
        XCTAssertTrue(
            normalized.contains("submarine") || normalized.contains("hull") || normalized.contains("dive"),
            "transcript should contain recognizable words from the known source clip, got: \(finalTranscript)"
        )

        // What the one tap actually produced, printed so the spike's result is
        // legible in a test log rather than only as a green checkmark.
        print("""
        SPIKE EVIDENCE | one tap, two consumers
        SPIKE EVIDENCE | source clip: sample-speech.wav, \(String(format: "%.2f", Double(sourceFile.length) / renderFormat.sampleRate))s
        SPIKE EVIDENCE | consumer 1 (AVAudioFile): \(writtenFile.length) frames, \
        \(String(format: "%.2f", writtenDurationSeconds))s, \(fileSize) bytes
        SPIKE EVIDENCE | consumer 2 (SFSpeechRecognizer): "\(finalTranscript)"
        """)
    }

    /// Sanity check that the production path - tapping the real hardware
    /// `inputNode` - starts cleanly with both consumers attached. The
    /// simulator has no live speaker in this environment so no assertion is
    /// made about transcript content here; this only proves the engine,
    /// session, tap installation, and dual-consumer wiring don't throw or
    /// crash against the real input node.
    func testRealInputNodeAcceptsDualConsumerTapWithoutThrowing() throws {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        try XCTSkipUnless(recognizer?.isAvailable == true, "Speech recognizer not available in this environment")

        let granted = try awaitAuthorization()
        try XCTSkipUnless(granted, "Microphone/speech authorization not granted in this environment")

        let capture = AudioCaptureEngine()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkwell-spike-hw-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        addTeardownBlock { try? FileManager.default.removeItem(at: outputURL) }

        XCTAssertNoThrow(try capture.startCapturing(to: outputURL))
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        capture.stopCapturing()
    }

    /// Issue #12 / the captain's report on 2026-07-31: tapping the well against
    /// the real hardware `inputNode` in this headless Simulator produces no
    /// transcript and no error, ever - proven by
    /// `VoiceCaptureFailureUITests` (10s of "Listening…" with a byte-identical
    /// screenshot at every check). That's this environment's actual instance
    /// of "no usable audio ever reaches the recognizer"; a real device could
    /// hit the same silent dead end for other reasons (session
    /// misconfiguration that doesn't throw, a stalled recognizer). Either
    /// way, this is the regression test for the fix: the real production
    /// entry point, against the real input node, must not be able to sit
    /// there silently past `AudioCaptureEngine.silenceTimeout`.
    func testRealInputNodeSilenceIsReportedRatherThanHangingForever() throws {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        try XCTSkipUnless(recognizer?.isAvailable == true, "Speech recognizer not available in this environment")

        let granted = try awaitAuthorization()
        try XCTSkipUnless(granted, "Microphone/speech authorization not granted in this environment")

        let capture = AudioCaptureEngine()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkwell-spike-silence-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        addTeardownBlock { try? FileManager.default.removeItem(at: outputURL) }

        let failureExpectation = expectation(description: "silence was reported as a failure")
        // The watchdog and a late recognizer error can both legitimately
        // report the same dead segment - either one proves the fix.
        failureExpectation.assertForOverFulfill = false
        nonisolated(unsafe) var reportedReason: RecognitionFailureReason?
        capture.setRecognitionFailureHandler { reason in
            reportedReason = reason
            failureExpectation.fulfill()
        }

        try capture.startCapturing(to: outputURL)
        wait(for: [failureExpectation], timeout: AudioCaptureEngine.silenceTimeout + 5)
        XCTAssertTrue(capture.transcript.isEmpty, "this environment has no live mic input to produce real words from")
        // Real, non-fake proof of the no-audio classification: this
        // environment's real hardware inputNode reliably delivers zero
        // signal (confirmed by direct RMS measurement while feeding it real
        // host audio - every buffer read exactly 0.0), so a fix that
        // distinguishes "no audio" from "recognizer failed" must classify
        // this exact real-world case as noAudioDetected, not a generic failure.
        XCTAssertEqual(
            reportedReason, .noAudioDetected,
            "zero real signal ever reached the tap this segment - this must be reported as no audio detected, not a generic recognition failure"
        )

        capture.stopCapturing()
    }

    /// The timeout exists to catch a dead recognizer, not a thinking owner:
    /// a normal pause to gather a thought before speaking (or between
    /// sentences) must not be treated as a failure. Anything under 10s was
    /// reported as tearing the owner out of listening mid-composition.
    func testSilenceTimeoutIsWideEnoughForAThinkingPause() {
        XCTAssertGreaterThanOrEqual(
            AudioCaptureEngine.silenceTimeout, 10,
            "a pause to gather a thought must not be mistaken for a dead recognizer"
        )
    }

    /// A review finding caught the threshold being documented as a raw RMS
    /// floor while actually compared against the 0...1 value scaled for the
    /// inkwell's visual reaction (`rms * 8`, clamped to 1) - an effective
    /// floor 8x lower than its own doc comment claimed. Now that
    /// `audioDetectionThreshold` is compared directly against `rms(of:)`'s
    /// raw output, this pins both ends of that boundary with buffers of
    /// exactly known RMS (a constant-amplitude signal's RMS is that same
    /// amplitude), rather than trusting the doc comment's arithmetic again.
    func testAudioDetectionThresholdIsRawRMSNotTheScaledVisualLevel() throws {
        let threshold = AudioCaptureEngine.audioDetectionThreshold

        let silence = try makeConstantAmplitudeBuffer(amplitude: 0, frameCount: 1024)
        let silenceRMS = try XCTUnwrap(AudioCaptureEngine.rms(of: silence))
        XCTAssertEqual(silenceRMS, 0, "exact silence must read as exactly 0 raw RMS")
        XCTAssertFalse(silenceRMS > threshold, "silence itself must never cross the detection threshold")

        let justAbove = try makeConstantAmplitudeBuffer(amplitude: threshold * 1.5, frameCount: 1024)
        let aboveRMS = try XCTUnwrap(AudioCaptureEngine.rms(of: justAbove))
        XCTAssertGreaterThan(aboveRMS, threshold, "a buffer with real signal above the floor must classify as audio detected")

        let justBelow = try makeConstantAmplitudeBuffer(amplitude: threshold * 0.5, frameCount: 1024)
        let belowRMS = try XCTUnwrap(AudioCaptureEngine.rms(of: justBelow))
        XCTAssertLessThan(belowRMS, threshold, "a buffer below the floor must stay classified as noise, not audio")
    }

    private func makeConstantAmplitudeBuffer(amplitude: Float, frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<Int(frameCount) {
            samples[i] = amplitude
        }
        return buffer
    }

    /// The watchdog must re-arm on every transcript change, not only cover
    /// a segment that never produced anything: a recognizer that emits
    /// words and then goes dead mid-segment - no further partials, no
    /// error - used to be invisible, because the first partial result
    /// disarmed the one-shot timer for good. Real partials are produced
    /// here by offline-rendering the bundled speech clip through the tap,
    /// then the recognizer is starved (no more audio, no endAudio) and the
    /// failure must still surface within the silence window.
    ///
    /// Only a failure that fires *after* words were on record proves the
    /// re-arm - a fire with an empty transcript is the segment-start
    /// watchdog, which the old one-shot design already had, so it must not
    /// satisfy this test. The first partial must also land well inside
    /// `silenceTimeout`, or that start-anchored fire could get there first
    /// and mask whether re-arming happened at all.
    func testRecognizerGoingDeadAfterPartialWordsStillReportsFailure() throws {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        try XCTSkipUnless(recognizer?.isAvailable == true, "Speech recognizer not available in this environment")

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let fixtureURL = try XCTUnwrap(
            Bundle(for: AudioSpikeTests.self).url(forResource: "sample-speech", withExtension: "wav"),
            "sample-speech.wav fixture must be bundled in the test target"
        )
        let sourceFile = try AVAudioFile(forReading: fixtureURL)
        let renderFormat = sourceFile.processingFormat
        engine.connect(player, to: engine.mainMixerNode, format: renderFormat)
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)

        let capture = AudioCaptureEngine(audioEngine: engine)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkwell-spike-dead-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        addTeardownBlock { try? FileManager.default.removeItem(at: outputURL) }

        let fireLog = RecognitionFailureFireLog()
        let qualifyingFailure = expectation(description: "a failure fired after real words were already on record")
        qualifyingFailure.assertForOverFulfill = false
        capture.setRecognitionFailureHandler { [weak capture] reason in
            guard let capture else { return }
            let transcriptAtFire = capture.transcript
            fireLog.record(transcript: transcriptAtFire, reason: reason)
            if !transcriptAtFire.isEmpty {
                qualifyingFailure.fulfill()
            }
        }

        try capture.beginCapture(tappingNode: player, bus: 0, to: outputURL)
        player.scheduleFile(sourceFile, at: nil)
        player.play()

        let pumpBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)
        )
        var framesRendered: AVAudioFramePosition = 0
        while framesRendered < sourceFile.length {
            pumpBuffer.frameLength = 0
            let status = try engine.renderOffline(engine.manualRenderingMaximumFrameCount, to: pumpBuffer)
            switch status {
            case .success:
                framesRendered += AVAudioFramePosition(pumpBuffer.frameLength)
            case .insufficientDataFromInputNode:
                framesRendered += AVAudioFramePosition(engine.manualRenderingMaximumFrameCount)
            case .cannotDoInCurrentContext:
                continue
            case .error:
                XCTFail("renderOffline returned .error")
                return
            @unknown default:
                XCTFail("renderOffline returned an unknown status")
                return
            }
        }

        let firstPartialDeadline = Date().addingTimeInterval(5)
        while capture.transcript.isEmpty && Date() < firstPartialDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard !capture.transcript.isEmpty else {
            XCTFail("the first partial must arrive well inside silenceTimeout, or a segment-start watchdog fire could masquerade as the re-arm under test")
            capture.stopCapture(tappedNode: player, bus: 0)
            engine.stop()
            return
        }
        let wordsProducedAt = Date()
        XCTAssertTrue(
            fireLog.entries.allSatisfy { !$0.transcript.isEmpty },
            "no failure may fire before words were produced - that would be the start-anchored watchdog, not the re-arm"
        )

        // From here the recognizer gets nothing more, ever - the mid-segment
        // death the re-arming watchdog exists to catch.
        wait(for: [qualifyingFailure], timeout: AudioCaptureEngine.silenceTimeout + 10)

        let qualifyingFires = fireLog.entries.filter { !$0.transcript.isEmpty }
        XCTAssertTrue(
            qualifyingFires.contains { $0.firedAt > wordsProducedAt },
            "the failure must have fired after the words were on record - only that proves the deadline re-armed on progress"
        )
        XCTAssertTrue(
            qualifyingFires.allSatisfy { $0.reason == .recognitionFailed },
            "real audio was fed through the tap this segment - a fire with words already on record must never be misclassified as no audio detected"
        )

        capture.stopCapture(tappedNode: player, bus: 0)
        engine.stop()
    }

    private func awaitAuthorization() throws -> Bool {
        let exp = expectation(description: "authorization")
        var granted = false
        Task {
            granted = await AudioCaptureEngine.requestAuthorization()
            exp.fulfill()
        }
        // The grants themselves are pre-seeded in this environment, but the
        // very first authorization round-trip after a fresh simulator
        // boot/install has been observed to take longer than 10s while the
        // speech/TCC daemons spin up - seen once as a real CI-style flake.
        wait(for: [exp], timeout: 30)
        return granted
    }
}

/// Latches, per `onRecognitionFailure` fire, when it fired and what the
/// transcript held at that instant - the two facts that distinguish a
/// re-armed post-words watchdog fire from the segment-start fire the old
/// one-shot design already produced.
private final class RecognitionFailureFireLog: @unchecked Sendable {
    private let lock = NSLock()
    private var fires: [(firedAt: Date, transcript: String, reason: RecognitionFailureReason)] = []

    func record(transcript: String, reason: RecognitionFailureReason) {
        lock.lock()
        defer { lock.unlock() }
        fires.append((firedAt: Date(), transcript: transcript, reason: reason))
    }

    var entries: [(firedAt: Date, transcript: String, reason: RecognitionFailureReason)] {
        lock.lock()
        defer { lock.unlock() }
        return fires
    }
}
