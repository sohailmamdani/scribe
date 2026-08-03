import AVFoundation
import ArgmaxOSS
import CoreML
import Foundation
import OSLog
import UIKit

@MainActor
final class DictationCoordinator: NSObject, ObservableObject, AVAudioRecorderDelegate {
	private enum ModelMode: Equatable {
		case balanced
		case compatibility
	}

	struct HistoryItem: Codable, Identifiable {
		let id: UUID
		let text: String
		let createdAt: Date
	}

    enum ViewState: Equatable {
        case preparing
        case ready
        case recording
        case transcribing
        case completed(String)
        case failed(String)
    }

    @Published private(set) var state: ViewState = .preparing
    @Published private(set) var audioLevel: Double = 0
	@Published private(set) var history: [HistoryItem] = []
	@Published private(set) var canRetryFailedTranscription = false
	@Published private(set) var isSessionActive = false
	@Published private(set) var sessionExpiresAt: Date?

    private let logger = Logger(subsystem: "sohail.Scribe.mobile", category: "Dictation")
    private let sharedStore = SharedDictationStore()
    private var whisperKit: WhisperKit?
    private var modelMode: ModelMode?
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
	private var pendingRecordingURL: URL?
    private var meterTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var keepAliveRecorder: AVAudioRecorder?
    private var interruptionObserver: NSObjectProtocol?
    private var isPreparingModel = false
	private var isTranscribing = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
	private var lastHeartbeat = Date.distantPast
	private let pendingRecordingPathKey = "mobile.pendingRecordingPath"
	private static let savedRecordingMessage = "Transcription failed, but your recording is saved. Tap Retry."
	private static let sessionDuration: TimeInterval = 15 * 60

    override init() {
        super.init()
		if let data = UserDefaults.standard.data(forKey: "mobile.dictationHistory"),
		   let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
			history = decoded
		}
		if let path = UserDefaults.standard.string(forKey: pendingRecordingPathKey),
		   FileManager.default.fileExists(atPath: path) {
			pendingRecordingURL = URL(fileURLWithPath: path)
			canRetryFailedTranscription = true
		}
		if Date().timeIntervalSince(sharedStore.updatedAt) > 300 {
			if pendingRecordingURL == nil {
				sharedStore.reset()
			} else {
				sharedStore.fail(Self.savedRecordingMessage, retryAvailable: true)
			}
		}
		// A fresh launch means any previously advertised session is gone.
		sharedStore.endSession()
    }

    deinit {
        meterTask?.cancel()
        sessionTask?.cancel()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func prepareModel() async {
        state = .preparing
        do {
            try await prepareModelIfNeeded(mode: .balanced)
            if canRetryFailedTranscription, state == .preparing {
                state = .failed(Self.savedRecordingMessage)
                sharedStore.fail(Self.savedRecordingMessage, retryAvailable: true)
            } else if state == .preparing {
                state = .ready
            }
        } catch {
            presentModelPreparationFailure(error)
        }
    }

    func handle(url: URL) async {
        guard url.scheme == "scribe" else { return }
        switch url.host {
        case "dictate":
            await startRecording()
        case "retry":
            await retryLastTranscription()
        default:
            break
        }
    }

    func handlePendingKeyboardCommand() async {
        switch sharedStore.consumeCommand() {
        case .start:
            await startRecording()
        case .stop:
            await stopAndTranscribe()
        case .cancel:
            cancelRecording()
        case .retry:
            await retryLastTranscription()
        case .none:
            break
        }
    }

    // MARK: - Flow session
    //
    // A flow session keeps the microphone alive (via a throwaway keep-alive
    // recorder) so the app stays running in the background and the keyboard
    // can start dictations with a shared-store command instead of opening the
    // app each time. Sessions extend on activity and end after 15 idle
    // minutes, on interruption, or when the user ends them.

    func startFlowSession() async {
        if isSessionActive {
            extendSession()
            return
        }

        let permissionGranted = await AVAudioApplication.requestRecordPermission()
        guard permissionGranted else {
            let message = "Microphone access is required. Enable it in Settings."
            state = .failed(message)
            sharedStore.fail(message)
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true)
        } catch {
            presentRecordingFailure(error)
            return
        }

        isSessionActive = true
        extendSession()
        startKeepAliveRecorderIfIdle()
        observeInterruptions()
        startSessionLoop()
    }

    func endFlowSession() {
        stopKeepAliveRecorder()
        sessionTask?.cancel()
        sessionTask = nil
        isSessionActive = false
        sessionExpiresAt = nil
        sharedStore.endSession()
        if audioRecorder == nil, !isTranscribing {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func extendSession() {
        let expiry = Date().addingTimeInterval(Self.sessionDuration)
        sessionExpiresAt = expiry
        sharedStore.sessionActive = true
        sharedStore.sessionExpiresAt = expiry
        sharedStore.sessionHeartbeat = Date()
    }

    private func startSessionLoop() {
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.isSessionActive else { return }

                self.sharedStore.sessionHeartbeat = Date()
                if let expiry = self.sessionExpiresAt, Date() > expiry,
                   self.audioRecorder == nil, !self.isTranscribing {
                    self.endFlowSession()
                    return
                }

                switch self.sharedStore.consumeCommand() {
                case .start:
                    await self.startRecording()
                case .stop:
                    await self.stopAndTranscribe()
                case .cancel:
                    self.cancelRecording()
                case .retry:
                    await self.retryLastTranscription()
                case .none:
                    break
                }
            }
        }
    }

    private func startKeepAliveRecorderIfIdle() {
        guard isSessionActive, audioRecorder == nil, keepAliveRecorder == nil else { return }
        let url = Self.keepAliveURL
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue,
        ]
        keepAliveRecorder = try? AVAudioRecorder(url: url, settings: settings)
        keepAliveRecorder?.record()
    }

    private func stopKeepAliveRecorder() {
        keepAliveRecorder?.stop()
        keepAliveRecorder = nil
        try? FileManager.default.removeItem(at: Self.keepAliveURL)
    }

    private static var keepAliveURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scribe-keepalive.m4a")
    }

    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption()
            }
        }
    }

    private func handleAudioInterruption() {
        if audioRecorder != nil {
            audioRecorder?.stop()
            audioRecorder = nil
            recordingURL = nil
            meterTask?.cancel()
            meterTask = nil
            audioLevel = 0
            sharedStore.audioLevel = 0
            canRetryFailedTranscription = pendingRecordingURL != nil
            state = .failed(Self.savedRecordingMessage)
            sharedStore.fail(Self.savedRecordingMessage, retryAvailable: canRetryFailedTranscription)
        }
        endFlowSession()
    }

    // MARK: - Dictation

    func startRecording() async {
        guard audioRecorder == nil else { return }
		discardPendingRecording()

        sharedStore.phase = .preparing
        sharedStore.message = "Preparing on-device transcription"
		sharedStore.retryAvailable = false
		canRetryFailedTranscription = false

        do {
            try await prepareModelIfNeeded(mode: .balanced)
        } catch {
            presentModelPreparationFailure(error)
            return
        }

        await startFlowSession()
        guard isSessionActive else { return }
        stopKeepAliveRecorder()

        do {
            let url = try makePendingRecordingURL()
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw DictationError.recordingDidNotStart
            }

            recordingURL = url
			pendingRecordingURL = url
			UserDefaults.standard.set(url.path, forKey: pendingRecordingPathKey)
            audioRecorder = recorder
            state = .recording
            sharedStore.phase = .recording
            sharedStore.message = "Listening…"

            meterTask?.cancel()
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.updateMeter()
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        } catch {
			discardPendingRecording()
			startKeepAliveRecorderIfIdle()
            presentRecordingFailure(error)
        }
    }

    func stopAndTranscribe() async {
        guard let recorder = audioRecorder, let url = recordingURL else { return }

        recorder.stop()
        audioRecorder = nil
        recordingURL = nil
        meterTask?.cancel()
        meterTask = nil
        audioLevel = 0
        sharedStore.audioLevel = 0
        state = .transcribing
        sharedStore.phase = .transcribing
        sharedStore.message = "Polishing your words…"
		await processPendingRecording(at: url)
	}

	func retryLastTranscription() async {
		guard !isTranscribing else { return }
		guard let url = pendingRecordingURL,
		      FileManager.default.fileExists(atPath: url.path) else {
			discardPendingRecording()
			let message = "The saved recording is no longer available. Please dictate again."
			state = .failed(message)
			sharedStore.fail(message)
			return
		}

		state = .transcribing
		sharedStore.phase = .transcribing
		sharedStore.message = "Retrying saved recording…"
		await processPendingRecording(at: url)
	}

	private func processPendingRecording(at url: URL) async {
		guard !isTranscribing else { return }
		isTranscribing = true
		beginBackgroundTask()

        defer {
			isTranscribing = false
			if isSessionActive {
				extendSession()
				startKeepAliveRecorderIfIdle()
			} else {
				try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
			}
            endBackgroundTask()
        }

        do {
			let results = try await transcribeWithRecovery(audioURL: url)
            let rawText = results.compactMap(\.text).joined(separator: " ")
            let polishedText = TranscriptPolisher.polish(rawText)
            guard !polishedText.isEmpty else { throw DictationError.noSpeechDetected }

			addToHistory(polishedText)
            state = .completed(polishedText)
			canRetryFailedTranscription = false
            sharedStore.publish(transcript: polishedText)
			discardPendingRecording()
		} catch DictationError.noSpeechDetected {
			discardPendingRecording()
			let message = DictationError.noSpeechDetected.localizedDescription
			state = .failed(message)
			canRetryFailedTranscription = false
			sharedStore.fail(message)
        } catch {
			logger.error("Transcription failed after compatibility retry: \(error.localizedDescription, privacy: .public)")
			state = .failed(Self.savedRecordingMessage)
			canRetryFailedTranscription = true
			sharedStore.fail(Self.savedRecordingMessage, retryAvailable: true)
        }
    }

    func cancelRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        recordingURL = nil
		discardPendingRecording()
        meterTask?.cancel()
        meterTask = nil
        if isSessionActive {
            extendSession()
            startKeepAliveRecorderIfIdle()
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        audioLevel = 0
		canRetryFailedTranscription = false
        sharedStore.reset()
        state = whisperKit == nil ? .preparing : .ready
    }

    private func updateMeter() {
        guard let recorder = audioRecorder else { return }
        recorder.updateMeters()
        let normalized = max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 55) / 55))
        audioLevel = normalized
        sharedStore.audioLevel = normalized
		if Date().timeIntervalSince(lastHeartbeat) > 2 {
			lastHeartbeat = Date()
			sharedStore.message = "Listening…"
		}
    }

	private func prepareModelIfNeeded(mode: ModelMode) async throws {
		if whisperKit != nil { return }

		if isPreparingModel {
			while isPreparingModel {
				try await Task.sleep(for: .milliseconds(100))
			}
			guard whisperKit != nil else { throw DictationError.modelUnavailable }
			return
		}

		isPreparingModel = true
		defer { isPreparingModel = false }
		whisperKit = try await makeWhisperKit(mode: mode)
		modelMode = mode
	}

	private func makeWhisperKit(mode: ModelMode) async throws -> WhisperKit {
		let computeUnits: MLComputeUnits = mode == .balanced ? .cpuAndGPU : .cpuOnly
		let computeOptions = ModelComputeOptions(
			melCompute: computeUnits,
			audioEncoderCompute: computeUnits,
			textDecoderCompute: computeUnits
		)
		let config = WhisperKitConfig(
			model: "openai_whisper-base",
			computeOptions: computeOptions,
			verbose: false,
			prewarm: true,
			load: true
		)
		return try await WhisperKit(config)
	}

	private func transcribeWithRecovery(audioURL: URL) async throws -> [TranscriptionResult] {
		do {
			try await prepareModelIfNeeded(mode: modelMode ?? .balanced)
			guard let whisperKit else { throw DictationError.modelUnavailable }
			return try await whisperKit.transcribe(audioPath: audioURL.path)
		} catch {
			logger.warning("Primary Core ML transcription failed; retrying CPU-only: \(error.localizedDescription, privacy: .public)")
			sharedStore.phase = .preparing
			sharedStore.message = "Retrying in compatibility mode…"
			whisperKit = nil
			modelMode = nil
			try await prepareModelIfNeeded(mode: .compatibility)
			guard let whisperKit else { throw DictationError.modelUnavailable }
			return try await whisperKit.transcribe(audioPath: audioURL.path)
		}
	}

	private func makePendingRecordingURL() throws -> URL {
		let folder = try FileManager.default.url(
			for: .applicationSupportDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		).appendingPathComponent("PendingDictations", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		return folder
			.appendingPathComponent("scribe-\(UUID().uuidString)")
			.appendingPathExtension("m4a")
	}

	private func discardPendingRecording() {
		if let pendingRecordingURL {
			try? FileManager.default.removeItem(at: pendingRecordingURL)
		}
		pendingRecordingURL = nil
		UserDefaults.standard.removeObject(forKey: pendingRecordingPathKey)
	}

	private func presentModelPreparationFailure(_ error: Error) {
		logger.error("Model preparation failed: \(error.localizedDescription, privacy: .public)")
		let message = "Scribe couldn’t prepare the on-device model. Check your connection and try again."
		state = .failed(message)
		canRetryFailedTranscription = false
		sharedStore.fail(message)
	}

	private func presentRecordingFailure(_ error: Error) {
		logger.error("Recording failed: \(error.localizedDescription, privacy: .public)")
		let message = (error as? LocalizedError)?.errorDescription
			?? "Scribe couldn’t start recording. Please try again."
		state = .failed(message)
		canRetryFailedTranscription = false
		sharedStore.fail(message)
	}

	private func addToHistory(_ text: String) {
		history.insert(HistoryItem(id: UUID(), text: text, createdAt: Date()), at: 0)
		history = Array(history.prefix(50))
		if let encoded = try? JSONEncoder().encode(history) {
			UserDefaults.standard.set(encoded, forKey: "mobile.dictationHistory")
		}
	}

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Finish Scribe transcription") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

private enum DictationError: LocalizedError {
    case recordingDidNotStart
    case modelUnavailable
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .recordingDidNotStart:
            "Scribe couldn’t start recording."
        case .modelUnavailable:
            "The on-device transcription model isn’t ready."
        case .noSpeechDetected:
            "Scribe didn’t hear any speech. Please try again."
        }
    }
}
