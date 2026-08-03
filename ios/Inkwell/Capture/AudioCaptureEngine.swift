import AVFoundation
import Speech

/// What `CaptureViewModel` needs from a capture surface. `AudioCaptureEngine`
/// is the one production implementation; the seam exists so the view model's
/// state rules - which own the "these words are live" invariant - can be
/// tested without a microphone, a speech authorization grant, or a running
/// audio session.
protocol CaptureEngine: AnyObject, Sendable {
    var transcript: String { get }
    var inputLevel: Float { get }
    func requestAuthorization() async -> Bool
    func startCapturing(to fileURL: URL) throws
    func stopCapturing()
    /// Called when the system takes the audio session away mid-segment.
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void)
    /// Called when a segment can no longer produce a transcript: the
    /// recognizer settled with an error, or made no transcript progress for
    /// `AudioCaptureEngine.silenceTimeout` - whether it never produced a
    /// word or went dead after some. Without this, a dead recognizer and a
    /// quietly-working one are indistinguishable from the UI: both just
    /// show "Listening…" forever.
    func setRecognitionFailureHandler(_ handler: @escaping @Sendable (RecognitionFailureReason) -> Void)
}

/// Distinguishes *why* a segment produced nothing, so the alert can say
/// something more useful than "didn't catch that" when the real cause is
/// that no audio ever reached the microphone at all - e.g. a simulator
/// whose host mic access or audio input routing isn't set up, confirmed by
/// direct RMS measurement to be indistinguishable, from the tap's own
/// perspective, from a dead recognizer unless the level is tracked.
enum RecognitionFailureReason: Sendable, Equatable {
    /// The silence watchdog fired and every buffer this segment measured at
    /// or below the noise floor - nothing, not even a mumble, ever arrived.
    case noAudioDetected
    /// The recognizer settled with an error, or the watchdog fired after
    /// audio was actually observed this segment - a real recognition
    /// failure, not an absent input.
    case recognitionFailed
}

/// Feeds one microphone tap to two independent consumers at once:
/// on-device speech recognition (for live words) and a written audio file
/// (the immutable utterance). This is the audio spike the product contract
/// asked to have proven before anything else was built.
/// The tap block runs on the audio render thread and the recognizer calls
/// back on its own queue; both hand their results to the main actor rather
/// than touching observed state directly, which is what makes this safe to
/// hold and read from SwiftUI.
@Observable
final class AudioCaptureEngine: CaptureEngine, @unchecked Sendable {

    enum CaptureError: Error, Equatable {
        case recognizerUnavailable
        case speechAuthorizationDenied
        case microphoneAuthorizationDenied
        case audioFileCreationFailed
    }

    /// How long a segment can run without any transcript progress - measured
    /// from the last partial result, or from the segment's start if none has
    /// arrived yet - before the recognizer is treated as dead rather than
    /// quietly working, e.g. no audio is actually reaching it. Long enough
    /// that a normal pause to gather a thought doesn't trip it; short enough
    /// that the owner isn't left staring at "Listening…" indefinitely.
    ///
    /// `INKWELL_SILENCE_TIMEOUT_OVERRIDE` (same launch-environment seam as
    /// `INKWELL_BACKEND_URL` in AppConfig) lets a UI test that needs to hold
    /// `.listening` open - this headless simulator's segments never receive
    /// audio, so the watchdog otherwise always ends them - widen the window
    /// instead of racing the production value. Unset means 10, everywhere.
    static let silenceTimeout: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["INKWELL_SILENCE_TIMEOUT_OVERRIDE"],
           let seconds = TimeInterval(raw), seconds > 0 {
            return seconds
        }
        return 10
    }()

    private(set) var transcript: String = ""
    private(set) var isRecording = false
    /// 0...1, driven by the same tap, for the inkwell's reaction to real audio.
    private(set) var inputLevel: Float = 0

    /// Raw RMS below this reads as noise-floor silence rather than real
    /// input - proven by direct measurement (RMS logged while feeding this
    /// exact tap real audio from the host, both spoken and via a
    /// synthesized clip played through system output) that genuine silence
    /// here reads as exactly 0.0 RMS with no variance, so any small margin
    /// above zero already separates "nothing arrived" from "something did."
    /// Deliberately raw RMS, not the 0...1 value `inputLevel` displays -
    /// comparing against a UI-scaled number would make this threshold's
    /// effective floor a function of that scaling factor instead of what it
    /// says on its face.
    @ObservationIgnored static let audioDetectionThreshold: Float = 0.00125
    /// Multiplies raw RMS into the 0...1 range `inputLevel` uses for the
    /// inkwell's visual reaction to real audio - a UI scaling choice,
    /// unrelated to `audioDetectionThreshold`.
    @ObservationIgnored private static let visualLevelGain: Float = 8

    @ObservationIgnored private let audioEngine: AVAudioEngine
    @ObservationIgnored private let speechRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var audioFile: AVAudioFile?
    @ObservationIgnored private var onFinalTranscript: ((String) -> Void)?
    @ObservationIgnored private var onInterruption: (@Sendable () -> Void)?
    @ObservationIgnored private var onRecognitionFailure: (@Sendable (RecognitionFailureReason) -> Void)?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var silenceWatchdog: Task<Void, Never>?
    /// Whether any buffer this segment has measured above the noise floor -
    /// the fact that distinguishes "no audio ever reached the mic" from an
    /// ordinary recognition failure when the watchdog fires.
    @ObservationIgnored private var observedAudioThisSegment = false
    /// Bumped per capture segment so a callback from a segment that has
    /// already been stopped can't publish over the current one's state.
    @ObservationIgnored private var generation = 0

    init(audioEngine: AVAudioEngine = AVAudioEngine(), locale: Locale = Locale(identifier: "en-US")) {
        self.audioEngine = audioEngine
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    static func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func requestAuthorization() async -> Bool {
        await Self.requestAuthorization()
    }

    /// Production entry point: taps the real hardware input node.
    /// Writes the utterance audio to `fileURL` while `transcript` updates live.
    func startCapturing(to fileURL: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        try beginCapture(tappingNode: audioEngine.inputNode, bus: 0, to: fileURL)
        observeInterruptions()
    }

    /// A call, Siri, or an alarm deactivates the session out from under us and
    /// the engine stops - no further audio or transcript will ever arrive on
    /// this segment. Tear it down for real and tell the owner, so nothing is
    /// left claiming to be listening to a microphone that is gone.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard rawType == AVAudioSession.InterruptionType.began.rawValue else { return }
            self.stopCapturing()
            self.onInterruption?()
        }
    }

    /// Shared mechanism, exposed so the spike can be proven against a
    /// synthetic source (a scheduled file player) as well as the real mic -
    /// the tap-time code that fans out to both consumers is identical either way.
    func beginCapture(tappingNode node: AVAudioNode, bus: Int, to fileURL: URL) throws {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw CaptureError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request
        transcript = ""
        observedAudioThisSegment = false
        generation &+= 1
        let generation = self.generation

        let format = node.outputFormat(forBus: bus)
        let file = try makeAudioFile(at: fileURL, format: format)
        audioFile = file

        node.removeTap(onBus: bus)
        node.installTap(onBus: bus, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // The one tap, feeding both consumers from the same buffer.
            // Both are captured locals, never read back off `self`, so the
            // render thread never touches observed state.
            request.append(buffer)
            try? file.write(from: buffer)
            guard let self, let rms = Self.rms(of: buffer) else { return }
            Task { @MainActor in
                guard self.isRecording, self.generation == generation else { return }
                self.inputLevel = min(1, rms * Self.visualLevelGain)
                if rms > Self.audioDetectionThreshold {
                    self.observedAudioThisSegment = true
                }
            }
        }

        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
        isRecording = true
        watchForSilence(generation: generation)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let settled = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard self.generation == generation else { return }
                if let text, text != self.transcript {
                    self.transcript = text
                    self.watchForSilence(generation: generation)
                }
                if settled {
                    self.onFinalTranscript?(self.transcript)
                }
                // Only a genuine mid-segment failure, not the settle that
                // follows a deliberate stopCapturing() - stopCapturing()
                // already flips isRecording off before cancelling the task,
                // so a cancellation's own completion can't be mistaken for one.
                if error != nil, self.isRecording {
                    self.onRecognitionFailure?(.recognitionFailed)
                }
            }
        }
    }

    /// The recognizer can go completely silent - no partial result, no
    /// error, ever - if no usable audio is reaching it at all (seen in this
    /// project's headless Simulator, where the mic tap gets no signal; also
    /// possible on-device if the input format or session is wrong in some
    /// way that doesn't throw). It can equally die *after* producing words,
    /// again with no error. Without this, either looks identical to a
    /// recognizer that's still quietly working: "Listening…" forever. Armed
    /// at segment start and re-armed on every transcript change, so it fires
    /// only after `silenceTimeout` with no progress at all.
    private func watchForSilence(generation: Int) {
        silenceWatchdog?.cancel()
        silenceWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.silenceTimeout))
            guard !Task.isCancelled else { return }
            guard let self, self.isRecording, self.generation == generation else { return }
            self.onRecognitionFailure?(self.observedAudioThisSegment ? .recognitionFailed : .noAudioDetected)
        }
    }

    /// Test hook: called when the recognizer settles on a final result or errors out.
    func setFinalTranscriptHandler(_ handler: @escaping (String) -> Void) {
        onFinalTranscript = handler
    }

    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
        onInterruption = handler
    }

    func setRecognitionFailureHandler(_ handler: @escaping @Sendable (RecognitionFailureReason) -> Void) {
        onRecognitionFailure = handler
    }

    func stopCapturing() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionRequest = nil
        recognitionTask = nil
        audioFile = nil
        isRecording = false
        inputLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Test-only teardown for a tap installed on an arbitrary node (e.g. a player node).
    /// Unlike `stopCapturing()`, this deliberately keeps `recognitionRequest`
    /// and `recognitionTask` alive: offline rendering feeds audio faster than
    /// recognition processes it, so at this point the request still holds
    /// queued, unprocessed audio - releasing it here drops that backlog and
    /// truncates the final transcript a caller waits for after this returns.
    /// The references are released with the engine itself at test teardown.
    func stopCapture(tappedNode node: AVAudioNode, bus: Int) {
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        node.removeTap(onBus: bus)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        audioFile = nil
        isRecording = false
    }

    private func makeAudioFile(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            throw CaptureError.audioFileCreationFailed
        }
    }

    /// Pure buffer math, safe to run on the render thread. Nil means this
    /// buffer carries nothing to measure, so the level should be left as-is.
    /// Returns raw RMS - callers scale it for visualization (`visualLevelGain`)
    /// or compare it directly against `audioDetectionThreshold`, as needed;
    /// this function itself makes no judgment about either.
    static func rms(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        var sum: Float = 0
        let samples = channelData[0]
        for i in 0..<frameCount {
            sum += samples[i] * samples[i]
        }
        return sqrt(sum / Float(frameCount))
    }
}
