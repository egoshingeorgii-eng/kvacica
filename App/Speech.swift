import AVFoundation
import Observation
import Speech

/// Text-to-speech with the closest available voice: Serbian, else Croatian, else Bosnian.
@MainActor
final class Speaker {
    let voice: AVSpeechSynthesisVoice?
    /// Shown in Settings so it's clear which voice is speaking.
    let voiceDescription: String
    private let synthesizer = AVSpeechSynthesizer()

    init() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        func best(_ language: String) -> AVSpeechSynthesisVoice? {
            voices.filter { $0.language.hasPrefix(language) }.max { $0.quality.rawValue < $1.quality.rawValue }
        }
        if let v = best("sr") {
            voice = v
            voiceDescription = String(localized: "Serbian voice: \(v.name)")
        } else if let v = best("hr") {
            voice = v
            voiceDescription = String(localized: "Croatian voice (\(v.name)) — pronunciation close, accent differs")
        } else if let v = best("bs") {
            voice = v
            voiceDescription = String(localized: "Bosnian voice (\(v.name)) — pronunciation close, accent differs")
        } else {
            voice = nil
            voiceDescription = String(localized: "No Serbian, Croatian or Bosnian voice installed, so the speak button is hidden. Add one in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
        }
    }

    var isAvailable: Bool { voice != nil }

    func speak(_ text: String) {
        guard let voice else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesizer.speak(utterance)
    }
}

/// Push-to-talk transcription, only when the system recognizes Serbian, Croatian or Bosnian.
@MainActor @Observable
final class SpeechInput {
    let locale: Locale? = {
        let supported = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier.replacingOccurrences(of: "_", with: "-") })
        return ["sr-RS", "hr-HR", "bs-BA"].first(where: supported.contains).map(Locale.init(identifier:))
    }()
    private(set) var isListening = false
    /// Microphone loudness while listening, 0…1.
    private(set) var level: Float = 0

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    var isAvailable: Bool { locale != nil }

    func start(onText: @escaping (String) -> Void) {
        guard let locale, !isListening else { return }
        isListening = true
        Task {
            guard await Self.authorize() else {
                isListening = false
                return
            }
            // The key may already be released while the permission prompt was up.
            guard isListening else { return }
            begin(locale: locale, onText: onText)
        }
    }

    #if DEBUG
    /// The perf bench: listening and the mic level without a microphone.
    func debugFake(listening: Bool, level: Float) {
        isListening = listening
        self.level = level
    }
    #endif

    func stop() {
        guard isListening else { return }
        isListening = false
        level = 0
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
    }

    private func begin(locale: Locale, onText: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            isListening = false
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let input = engine.inputNode
        let tap = Self.tap(request) { [weak self] level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isListening else { return }
                    self.level = level
                }
            }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: tap)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            isListening = false
            return
        }
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler(onText))
    }

    // Built outside the main actor: these run on audio / recognition threads.
    private nonisolated static func tap(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        onLevel: @escaping (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            // Map roughly -50 dB (room noise) … -10 dB (speaking up) onto 0…1.
            let decibels = 20 * log10(max(rms, 1e-6))
            onLevel(min(max((decibels + 50) / 40, 0), 1))
        }
    }

    private nonisolated static func handler(_ onText: @escaping (String) -> Void) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            DispatchQueue.main.async { onText(text) }
        }
    }

    private nonisolated static func authorize() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}
