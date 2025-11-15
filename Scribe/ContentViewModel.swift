import Foundation
import AppKit
import Combine

class ContentViewModel: ObservableObject {
    private var appState: AppState?
    private var audioRecorder: AudioRecorder!
    private var whisperService: WhisperService!
    private var autoPaste: AutoPaste!
    private var hotkeyManager: HotkeyManager!

    func setup(appState: AppState) {
        self.appState = appState

        // Initialize services
        whisperService = WhisperService()
        autoPaste = AutoPaste()

        // Initialize audio recorder with callback
        audioRecorder = AudioRecorder { [weak self] audioData in
            // Handle audio data if needed during recording
        }

        // Setup global hotkey (Cmd+Option+Ctrl+V)
        hotkeyManager = HotkeyManager()
        hotkeyManager.register(key: .v, modifiers: [.command, .option, .control]) { [weak self] in
            self?.toggleRecording()
        }

        // Load Whisper model
        appState.isLoading = true
        appState.statusMessage = "Loading Whisper model..."

        whisperService.loadModel(
            onProgress: { [weak self] message in
                DispatchQueue.main.async {
                    self?.appState?.statusMessage = message
                }
            },
            completion: { [weak self] success in
                DispatchQueue.main.async {
                    self?.appState?.isLoading = false
                    if success {
                        self?.appState?.statusMessage = "Ready - Press ⌘R or ⌘⌥⌃V to record"
                    } else {
                        self?.appState?.statusMessage = "Failed to load model"
                    }
                }
            }
        )

        // Check microphone permission
        audioRecorder.requestPermission { granted in
            if !granted {
                DispatchQueue.main.async {
                    self.showMicrophonePermissionAlert()
                }
            }
        }
    }

    func toggleRecording() {
        guard let appState = appState else { return }

        if appState.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard let appState = appState else { return }
        guard audioRecorder.startRecording() else {
            appState.statusMessage = "Failed to start recording"
            return
        }

        appState.isRecording = true
        appState.statusMessage = "Recording... (Press ⌘R or ⌘⌥⌃V to stop)"
    }

    private func stopRecording() {
        guard let appState = appState else { return }

        let audioData = audioRecorder.stopRecording()
        appState.isRecording = false
        appState.statusMessage = "Processing..."

        guard let audioData = audioData else {
            appState.statusMessage = "No audio recorded"
            return
        }

        // Transcribe the audio
        whisperService.transcribe(audioData: audioData) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    guard !text.isEmpty else {
                        self?.appState?.statusMessage = "No speech detected"
                        return
                    }

                    // Add to transcriptions
                    self?.appState?.transcriptions.insert(text, at: 0)
                    self?.appState?.statusMessage = "Ready - Press ⌘R or ⌘⌥⌃V to record"

                    // Auto-paste if enabled
                    if self?.appState?.autoPasteEnabled == true {
                        self?.autoPaste.paste(text)
                    }

                case .failure(let error):
                    self?.appState?.statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    func setWindowFloating(_ floating: Bool) {
        // Get the main window
        if let window = NSApplication.shared.windows.first {
            window.level = floating ? .floating : .normal
        }
    }

    private func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "Scribe needs access to your microphone to record audio. Please grant permission in System Settings > Privacy & Security > Microphone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
