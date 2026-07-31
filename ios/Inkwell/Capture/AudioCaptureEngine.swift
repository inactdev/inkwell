import AVFoundation
import Speech

/// Feeds one microphone tap to two independent consumers at once:
/// on-device speech recognition (for live words) and a written audio file
/// (the immutable utterance). This is the audio spike the product contract
/// asked to have proven before anything else was built.
/// The tap block runs on the audio render thread and the recognizer calls
/// back on its own queue; both hand their results to the main actor rather
/// than touching observed state directly, which is what makes this safe to
/// hold and read from SwiftUI.
@Observable
final class AudioCaptureEngine: @unchecked Sendable {

    enum CaptureError: Error, Equatable {
        case recognizerUnavailable
        case speechAuthorizationDenied
        case microphoneAuthorizationDenied
        case audioFileCreationFailed
    }

    /// Internal (not private) set so CaptureViewModelTests can inject a
    /// delayed post-stop delivery without real speech, reproducing the
    /// exact race that scoping in CaptureViewModel guards against.
    var transcript: String = ""
    private(set) var isRecording = false
    /// 0...1, driven by the same tap, for the inkwell's reaction to real audio.
    private(set) var inputLevel: Float = 0

    @ObservationIgnored private let audioEngine: AVAudioEngine
    @ObservationIgnored private let speechRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var audioFile: AVAudioFile?
    @ObservationIgnored private var onFinalTranscript: ((String) -> Void)?
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

    /// Production entry point: taps the real hardware input node.
    /// Writes the utterance audio to `fileURL` while `transcript` updates live.
    func startCapturing(to fileURL: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        try beginCapture(tappingNode: audioEngine.inputNode, bus: 0, to: fileURL)
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
            guard let self, let level = Self.level(of: buffer) else { return }
            Task { @MainActor in
                guard self.isRecording, self.generation == generation else { return }
                self.inputLevel = level
            }
        }

        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
        isRecording = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let settled = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard self.generation == generation else { return }
                if let text {
                    self.transcript = text
                }
                if settled {
                    self.onFinalTranscript?(self.transcript)
                }
            }
        }
    }

    /// Test hook: called when the recognizer settles on a final result or errors out.
    func setFinalTranscriptHandler(_ handler: @escaping (String) -> Void) {
        onFinalTranscript = handler
    }

    func stopCapturing() {
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
    func stopCapture(tappedNode node: AVAudioNode, bus: Int) {
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
    private static func level(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        var sum: Float = 0
        let samples = channelData[0]
        for i in 0..<frameCount {
            sum += samples[i] * samples[i]
        }
        let rms = sqrt(sum / Float(frameCount))
        return min(1, rms * 8)
    }
}
