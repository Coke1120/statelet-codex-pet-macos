import AppKit
import AVFoundation
import Speech

/// Explicit push-to-talk dictation. Audio is never recorded to a file and the
/// recognizer must support on-device processing; there is no cloud fallback.
@MainActor
final class CompanionDictation: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var token: UUID?

    func start() {
        guard !isStarting, !isListening else { return }
        let current = UUID(); token = current; isStarting = true
        SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
            DispatchQueue.main.async {
                guard let self, self.token == current else { return }
                guard authorization == .authorized else {
                    self.fail("Allow Speech Recognition for Statelet in System Settings → Privacy & Security.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    DispatchQueue.main.async {
                        guard self.token == current else { return }
                        guard allowed else {
                            self.fail("Allow Microphone access for Statelet in System Settings → Privacy & Security.")
                            return
                        }
                        self.begin(token: current)
                    }
                }
            }
        }
    }

    private func begin(token current: UUID) {
        guard let recognizer = SFSpeechRecognizer(locale: .current),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            fail("On-device dictation is unavailable for your current language. Type a message or use macOS Dictation.")
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("No microphone is available. Connect a microphone and try again."); return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.engine = engine; self.request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.token == current else { return }
                if let result { self.onText?(result.bestTranscription.formattedString) }
                if result?.isFinal == true { self.stop() }
                else if error != nil { self.fail("Dictation stopped. Check your microphone and try again.") }
            }
        }
        do {
            engine.prepare(); try engine.start()
            isStarting = false; isListening = true
        } catch { fail("The microphone could not start. Check your audio input in System Settings.") }
    }

    func stop() {
        token = nil
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        request?.endAudio(); request = nil
        recognition?.cancel(); recognition = nil
        isListening = false; isStarting = false
    }

    private func fail(_ message: String) { stop(); onError?(message) }
}
