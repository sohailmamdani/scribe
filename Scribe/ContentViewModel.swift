import Foundation
import AppKit
import Combine

class ContentViewModel: ObservableObject {
    private var appState: AppState?
    private var audioRecorder: AudioRecorder!
    private var whisperService: WhisperService!
    private var autoPaste: AutoPaste!
    private var hotkeyManager: HotkeyManager!
    private var cancellables = Set<AnyCancellable>()

    func setup(appState: AppState) {
        self.appState = appState

        whisperService = WhisperService()
        autoPaste = AutoPaste()

        audioRecorder = AudioRecorder { _ in }

        hotkeyManager = HotkeyManager()
        let prefs = Preferences.shared
        registerHotkey(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)

        Publishers.CombineLatest(prefs.$hotkeyKeyCode, prefs.$hotkeyModifiers)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] keyCode, modifiers in
                self?.registerHotkey(keyCode: keyCode, modifiers: modifiers)
                self?.appState?.statusMessage = self?.readyMessage() ?? "Ready"
            }
            .store(in: &cancellables)

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
                        self?.appState?.statusMessage = self?.readyMessage() ?? "Ready"
                    } else {
                        self?.appState?.statusMessage = "Failed to load model"
                    }
                }
            }
        )

        audioRecorder.requestPermission { granted in
            if !granted {
                DispatchQueue.main.async {
                    self.showMicrophonePermissionAlert()
                }
            }
        }
    }

    private func registerHotkey(keyCode: UInt32, modifiers: UInt32) {
        hotkeyManager.register(keyCode: keyCode, modifiers: modifiers) { [weak self] in
            self?.toggleRecording()
        }
    }

    private func readyMessage() -> String {
        "Ready - Press ⌘R or \(Preferences.shared.hotkeyDescription) to record"
    }

    private func recordingMessage() -> String {
        "Recording... (Press ⌘R or \(Preferences.shared.hotkeyDescription) to stop)"
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
        appState.statusMessage = recordingMessage()
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

        whisperService.transcribe(audioData: audioData) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    guard !text.isEmpty else {
                        self?.appState?.statusMessage = "No speech detected"
                        return
                    }

                    self?.appState?.transcriptions.insert(text, at: 0)
                    self?.appState?.statusMessage = self?.readyMessage() ?? "Ready"

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
