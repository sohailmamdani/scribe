import AVFoundation
import ArgmaxOSS
import CoreML
import Foundation
import OSLog
import UIKit

@MainActor
final class DictationCoordinator: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate {
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
    private var isStartingRecording = false
	private var recordingStartGeneration: UUID?
    private var transcriptionGeneration: UUID?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
	private var lastHeartbeat = Date.distantPast
	private let processID = UUID().uuidString
	private var currentRequestID: String?
	private var requestGate = DictationRequestGate()
	private let pendingRecordingPathKey = "mobile.pendingRecordingPath"
	private let compatibilityPreferenceKey = "mobile.preferCompatibilityModel"
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
		let previousStatus = sharedStore.status
		if previousStatus.isInFlight {
			let message = pendingRecordingURL == nil
				? "Scribe restarted before finishing. Tap Dictate to try again."
				: Self.savedRecordingMessage
			sharedStore.fail(
				message,
				for: previousStatus.requestID,
				processID: processID,
				retryAvailable: pendingRecordingURL != nil
			)
		}
		// A request is durable only after the app has written a matching status.
		// Ignore a legacy handled marker without that atomic acknowledgement so a
		// process killed between claim and status publication can recover it.
		requestGate = DictationRequestGate(
			latestRequest: sharedStore.latestRequest,
			status: sharedStore.status
		)
		// A fresh process invalidates the prior process's advertised session.
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
		guard audioRecorder == nil, !isStartingRecording, !isTranscribing else { return }
        state = .preparing
        do {
            try await prepareModelWithRecovery()
            if canRetryFailedTranscription, state == .preparing {
                state = .failed(Self.savedRecordingMessage)
            } else if state == .preparing {
                state = .ready
            }
        } catch {
            presentModelPreparationFailure(error)
        }
    }

    func handle(url: URL) async {
        guard url.scheme == "scribe", url.host == "wake" else { return }
        _ = await handlePendingKeyboardRequest()
    }

    @discardableResult
    func handlePendingKeyboardRequest() async -> Bool {
        guard let request = sharedStore.latestRequest,
              requestGate.claim(request) else { return false }

		guard request.isFresh() else {
			publishFailure(
				"That dictation request expired. Tap Dictate to try again.",
				for: request.id
			)
			currentRequestID = nil
			return false
		}

        // Claim before awaiting any model, permission, or audio work. The same
        // request can arrive through .task, onOpenURL, scene activation, and
        // session polling; only this first claim is allowed to execute it.
        currentRequestID = request.id
		// Any newer request supersedes a start operation that is still suspended
		// in model or audio-session preparation, including a second Start tap.
		recordingStartGeneration = nil

        switch request.command {
        case .start:
			guard !isTranscribing else {
				publishBusyFailure(for: request.id)
				return true
			}
            publishStatus(.preparing, "Starting Scribe…", for: request.id)
            await startRecording(requestID: request.id)
		case .stop:
			guard audioRecorder != nil, recordingURL != nil else {
				publishFailure("There isn’t an active recording to finish.", for: request.id)
				currentRequestID = nil
				if whisperKit == nil { await prepareModel() }
				else { state = .ready }
				return true
			}
            publishStatus(.transcribing, "Polishing your words…", for: request.id)
            await stopAndTranscribe()
		case .cancel:
			cancelRecording()
			if whisperKit == nil { await prepareModel() }
        case .retry:
			guard !isTranscribing else {
				publishBusyFailure(for: request.id)
				return true
			}
            publishStatus(.preparing, "Retrying saved recording…", for: request.id)
            await retryLastTranscription()
        }
		return true
    }

    // MARK: - Flow session
    //
    // A flow session keeps the microphone alive (via a throwaway keep-alive
    // recorder) so the app stays running in the background and the keyboard
    // can start dictations with a shared-store command instead of opening the
    // app each time. Sessions extend on activity and end after 15 idle
    // minutes, on interruption, or when the user ends them.

    private func prepareAudioSessionForRecording() async -> Bool {
		if isSessionActive, restoreKeepAliveOrEndSession() {
            extendSession()
            return true
        }

        let permissionGranted = await AVAudioApplication.requestRecordPermission()
        guard permissionGranted else {
            let message = "Microphone access is required. Enable it in Settings."
            state = .failed(message)
            publishFailure(message)
            return false
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
            return false
        }

        // The primary recorder starts immediately after this returns. Publish
        // the shared live session only once that recorder is verifiably active;
        // starting a throwaway recorder here adds latency and audio-route churn.
        return true
    }

    func endFlowSession() {
		recordingStartGeneration = nil
        stopKeepAliveRecorder()
        sessionTask?.cancel()
        sessionTask = nil
        isSessionActive = false
        sessionExpiresAt = nil
        sharedStore.endSession(processID: processID)
        if audioRecorder == nil, !isTranscribing {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func extendSession() {
        let expiry = Date().addingTimeInterval(Self.sessionDuration)
		lastHeartbeat = Date()
        sessionExpiresAt = expiry
        sharedStore.extendSession(processID: processID, expiresAt: expiry)
    }

    private func startSessionLoop() {
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.isSessionActive else { return }
				guard self.audioRecorder?.isRecording == true
				        || self.keepAliveRecorder?.isRecording == true else {
					self.handleFlowSessionRecorderStopped()
					return
				}

				if Date().timeIntervalSince(self.lastHeartbeat) >= 2 {
					self.lastHeartbeat = Date()
					self.sharedStore.refreshSessionHeartbeat(processID: self.processID)
				}
                if let expiry = self.sessionExpiresAt, Date() > expiry,
                   self.audioRecorder == nil, !self.isTranscribing {
                    self.endFlowSession()
                    return
                }

				Task { @MainActor [weak self] in
					_ = await self?.handlePendingKeyboardRequest()
				}
            }
        }
    }

    private func startKeepAliveRecorderIfIdle() throws {
        guard audioRecorder == nil, keepAliveRecorder == nil else { return }
        let url = Self.keepAliveURL
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        guard recorder.prepareToRecord(), recorder.record(), recorder.isRecording else {
            throw DictationError.recordingDidNotStart
        }
        keepAliveRecorder = recorder
    }

	@discardableResult
	private func restoreKeepAliveOrEndSession() -> Bool {
		guard isSessionActive else { return false }
		if audioRecorder?.isRecording == true || keepAliveRecorder?.isRecording == true {
			return true
		}

		// A stopped primary recorder means the active recording was lost; do not
		// disguise that as a healthy background session.
		guard audioRecorder == nil else {
			endFlowSession()
			return false
		}

			stopKeepAliveRecorder()
			do {
			try startKeepAliveRecorderIfIdle()
			guard keepAliveRecorder?.isRecording == true else {
				endFlowSession()
				return false
			}
			return true
		} catch {
			logger.error("Could not restore the background audio session: \(error.localizedDescription, privacy: .public)")
			endFlowSession()
			return false
		}
	}

    private func stopKeepAliveRecorder() {
		let recorder = keepAliveRecorder
		keepAliveRecorder = nil
		recorder?.delegate = nil
		recorder?.stop()
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
            publishFailure(Self.savedRecordingMessage, retryAvailable: canRetryFailedTranscription)
        }
        endFlowSession()
    }

    // MARK: - Dictation

    func startRecording(requestID: String? = nil) async {
		if let audioRecorder, !audioRecorder.isRecording {
			handleUnexpectedRecorderFailure()
			return
		}
        guard !isStartingRecording, !isTranscribing, audioRecorder == nil else {
            if audioRecorder != nil {
                publishStatus(.recording, "Listening…", for: requestID ?? currentRequestID)
			} else if let requestID = requestID ?? currentRequestID {
				publishBusyFailure(for: requestID)
            }
            return
        }
        isStartingRecording = true
		let startGeneration = UUID()
		recordingStartGeneration = startGeneration
        defer {
			let wasInvalidated = recordingStartGeneration != startGeneration
			if recordingStartGeneration == startGeneration {
				recordingStartGeneration = nil
			}
			isStartingRecording = false
			if wasInvalidated, state == .preparing, audioRecorder == nil, !isTranscribing {
				if whisperKit != nil {
					state = .ready
				} else {
					Task { [weak self] in await self?.prepareModel() }
				}
			}
		}
        currentRequestID = requestID
		discardPendingRecording()

		publishStatus(.preparing, "Preparing on-device transcription")
		canRetryFailedTranscription = false

        do {
            try await prepareModelWithRecovery()
        } catch {
			guard isCurrentRecordingStart(startGeneration, requestID: requestID) else { return }
            presentModelPreparationFailure(error)
            return
        }
		guard isCurrentRecordingStart(startGeneration, requestID: requestID) else { return }

		let audioSessionReady = await prepareAudioSessionForRecording()
		guard isCurrentRecordingStart(startGeneration, requestID: requestID) else {
			if audioSessionReady, !isSessionActive, audioRecorder == nil {
				try? AVAudioSession.sharedInstance().setActive(
					false,
					options: .notifyOthersOnDeactivation
				)
			}
			return
		}
		guard audioSessionReady else { return }
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
            guard recorder.prepareToRecord(), recorder.record(), recorder.isRecording else {
                throw DictationError.recordingDidNotStart
            }

            recordingURL = url
			pendingRecordingURL = url
			UserDefaults.standard.set(url.path, forKey: pendingRecordingPathKey)
            audioRecorder = recorder
			if !isSessionActive {
				isSessionActive = true
				observeInterruptions()
				startSessionLoop()
			}
			extendSession()
            state = .recording
			publishStatus(.recording, "Listening…")

            meterTask?.cancel()
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.updateMeter()
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
        } catch {
			discardPendingRecording()
			if isSessionActive {
				_ = restoreKeepAliveOrEndSession()
			} else {
				try? AVAudioSession.sharedInstance().setActive(
					false,
					options: .notifyOthersOnDeactivation
				)
			}
            presentRecordingFailure(error)
        }
    }

	private func isCurrentRecordingStart(_ generation: UUID, requestID: String?) -> Bool {
		recordingStartGeneration == generation && currentRequestID == requestID
	}

    func stopAndTranscribe() async {
        guard !isTranscribing, let recorder = audioRecorder, let url = recordingURL else { return }

        audioRecorder = nil
        recordingURL = nil
        recorder.stop()
        meterTask?.cancel()
        meterTask = nil
        audioLevel = 0
        sharedStore.audioLevel = 0
        state = .transcribing
		publishStatus(.transcribing, "Polishing your words…")
		if isSessionActive {
			guard restoreKeepAliveOrEndSession() else {
				let message = "The background session ended. Your recording is saved—tap Retry."
				state = .failed(message)
				canRetryFailedTranscription = true
				publishFailure(message, retryAvailable: true)
				currentRequestID = nil
				return
			}
		}
		await processPendingRecording(at: url)
	}

	func retryLastTranscription() async {
		guard !isTranscribing else {
			let message = "Scribe is still finishing the previous recording. Try again in a moment."
			state = .failed(message)
			canRetryFailedTranscription = pendingRecordingURL != nil
			publishFailure(message, retryAvailable: canRetryFailedTranscription)
			currentRequestID = nil
			return
		}
		guard let url = pendingRecordingURL,
		      FileManager.default.fileExists(atPath: url.path) else {
			discardPendingRecording()
			let message = "The saved recording is no longer available. Please dictate again."
			state = .failed(message)
			publishFailure(message)
			currentRequestID = nil
			return
		}

		state = .transcribing
		publishStatus(.transcribing, "Retrying saved recording…")
		if isSessionActive, !restoreKeepAliveOrEndSession() {
			let message = "The background session ended. Reopen Scribe, then tap Retry."
			state = .failed(message)
			canRetryFailedTranscription = true
			publishFailure(message, retryAvailable: true)
			currentRequestID = nil
			return
		}
		await processPendingRecording(at: url)
	}

	private func processPendingRecording(at url: URL) async {
		guard !isTranscribing else { return }
		isTranscribing = true
		let generation = UUID()
		let resultRequestID = currentRequestID
		transcriptionGeneration = generation
		beginBackgroundTask()

        defer {
			isTranscribing = false
			if transcriptionGeneration == generation { transcriptionGeneration = nil }
			if isSessionActive {
				extendSession()
				_ = restoreKeepAliveOrEndSession()
			} else {
				try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
			}
            endBackgroundTask()
        }

        do {
			let results = try await transcribeWithRecovery(audioURL: url)
			guard transcriptionGeneration == generation else { return }
            let rawText = results.compactMap(\.text).joined(separator: " ")
            let polishedText = TranscriptPolisher.polish(rawText)
            guard !polishedText.isEmpty else { throw DictationError.noSpeechDetected }

			addToHistory(polishedText)
            state = .completed(polishedText)
			canRetryFailedTranscription = false
			if let resultRequestID {
				sharedStore.publish(
					transcript: polishedText,
					for: resultRequestID,
					processID: processID
				)
			}
			discardPendingRecording()
			currentRequestID = nil
		} catch DictationError.noSpeechDetected {
			guard transcriptionGeneration == generation else { return }
			discardPendingRecording()
			let message = DictationError.noSpeechDetected.localizedDescription
			state = .failed(message)
			canRetryFailedTranscription = false
			publishFailure(message, for: resultRequestID)
			currentRequestID = nil
        } catch {
			guard transcriptionGeneration == generation else { return }
			logger.error("Transcription failed after compatibility retry: \(error.localizedDescription, privacy: .public)")
			state = .failed(Self.savedRecordingMessage)
			canRetryFailedTranscription = true
			publishFailure(Self.savedRecordingMessage, for: resultRequestID, retryAvailable: true)
			currentRequestID = nil
        }
    }

    func cancelRecording() {
		recordingStartGeneration = nil
        let recorder = audioRecorder
        audioRecorder = nil
        recordingURL = nil
		transcriptionGeneration = nil
		recorder?.stop()
		discardPendingRecording()
        meterTask?.cancel()
        meterTask = nil
        if isSessionActive {
            extendSession()
			_ = restoreKeepAliveOrEndSession()
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        audioLevel = 0
		canRetryFailedTranscription = false
		if let currentRequestID {
			sharedStore.reset(for: currentRequestID, processID: processID)
			sharedStore.markRequestHandled(currentRequestID)
		}
        currentRequestID = nil
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
			sharedStore.refreshSessionHeartbeat(processID: processID)
		}
    }

	private func prepareModelIfNeeded(mode: ModelMode) async throws {
		if whisperKit != nil, modelMode == mode { return }

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

	private func prepareModelWithRecovery() async throws {
		let preferredMode: ModelMode = UserDefaults.standard.bool(forKey: compatibilityPreferenceKey)
			? .compatibility
			: .balanced
		do {
			try await prepareModelIfNeeded(mode: preferredMode)
		} catch {
			guard preferredMode == .balanced, shouldUseCompatibilityMode(for: error) else { throw error }
			logger.warning("Default Core ML preparation failed; switching to stable CPU mode: \(error.localizedDescription, privacy: .public)")
			publishStatus(
				isTranscribing ? .transcribing : .preparing,
				"Switching to stable on-device mode…"
			)
			whisperKit = nil
			modelMode = nil
			try await prepareModelIfNeeded(mode: .compatibility)
			UserDefaults.standard.set(true, forKey: compatibilityPreferenceKey)
		}
	}

	private func makeWhisperKit(mode: ModelMode) async throws -> WhisperKit {
		let computeOptions: ModelComputeOptions? = mode == .compatibility
			? ModelComputeOptions(
				melCompute: .cpuOnly,
				audioEncoderCompute: .cpuOnly,
				textDecoderCompute: .cpuOnly
			)
			: nil
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
			try await prepareModelWithRecovery()
			guard let whisperKit else { throw DictationError.modelUnavailable }
			return try await whisperKit.transcribe(audioPath: audioURL.path)
		} catch {
			guard modelMode != .compatibility, shouldUseCompatibilityMode(for: error) else { throw error }
			logger.warning("Default Core ML transcription failed; retrying in stable CPU mode: \(error.localizedDescription, privacy: .public)")
			publishStatus(.transcribing, "Switching to stable on-device mode…")
			whisperKit = nil
			modelMode = nil
			try await prepareModelIfNeeded(mode: .compatibility)
			guard let whisperKit else { throw DictationError.modelUnavailable }
			let result = try await whisperKit.transcribe(audioPath: audioURL.path)
			UserDefaults.standard.set(true, forKey: compatibilityPreferenceKey)
			return result
		}
	}

	private func shouldUseCompatibilityMode(for error: Error) -> Bool {
		let nsError = error as NSError
		let haystack = "\(nsError.domain) \(nsError.localizedDescription)".lowercased()
		return haystack.contains("coreml")
			|| haystack.contains("ml program")
			|| haystack.contains("prediction")
			|| haystack.contains("compute device")
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
		publishFailure(message)
	}

	private func presentRecordingFailure(_ error: Error) {
		logger.error("Recording failed: \(error.localizedDescription, privacy: .public)")
		let message = (error as? LocalizedError)?.errorDescription
			?? "Scribe couldn’t start recording. Please try again."
		state = .failed(message)
		canRetryFailedTranscription = false
		publishFailure(message)
	}

	private func publishStatus(
		_ phase: DictationPhase,
		_ message: String,
		for requestID: String? = nil,
		retryAvailable: Bool = false
	) {
		guard let effectiveRequestID = requestID ?? currentRequestID else { return }
		sharedStore.publishStatus(
			for: effectiveRequestID,
			processID: processID,
			phase: phase,
			message: message,
			retryAvailable: retryAvailable
		)
		sharedStore.markRequestHandled(effectiveRequestID)
	}

	private func publishFailure(
		_ message: String,
		for requestID: String? = nil,
		retryAvailable: Bool = false
	) {
		guard let effectiveRequestID = requestID ?? currentRequestID else { return }
		sharedStore.fail(
			message,
			for: effectiveRequestID,
			processID: processID,
			retryAvailable: retryAvailable
		)
		sharedStore.markRequestHandled(effectiveRequestID)
		if currentRequestID == effectiveRequestID {
			currentRequestID = nil
		}
	}

	private func publishBusyFailure(for requestID: String) {
		publishFailure(
			"Scribe is still finishing the previous recording. Try again in a moment.",
			for: requestID,
			retryAvailable: pendingRecordingURL != nil
		)
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
            Task { @MainActor in self?.handleBackgroundTaskExpiration() }
        }
    }

	private func handleBackgroundTaskExpiration() {
		guard isTranscribing else {
			endBackgroundTask()
			return
		}
		transcriptionGeneration = nil
		let message = "iOS paused Scribe before transcription finished. Your recording is saved—tap Retry."
		state = .failed(message)
		canRetryFailedTranscription = pendingRecordingURL != nil
		publishFailure(message, retryAvailable: canRetryFailedTranscription)
		currentRequestID = nil
		endBackgroundTask()
	}

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

	func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
		if recorder === keepAliveRecorder {
			keepAliveRecorder = nil
			handleFlowSessionRecorderStopped()
			return
		}

		guard recorder === audioRecorder else { return }
		if flag {
			Task { await stopAndTranscribe() }
		} else {
			handleUnexpectedRecorderFailure()
		}
	}

	private func handleFlowSessionRecorderStopped() {
		guard isSessionActive else { return }
		if audioRecorder != nil {
			handleUnexpectedRecorderFailure()
			return
		}

		keepAliveRecorder = nil
		let interruptedRequestID = currentRequestID
		let interruptedTranscription = isTranscribing
		if interruptedTranscription {
			transcriptionGeneration = nil
		}
		endFlowSession()

		guard interruptedRequestID != nil || interruptedTranscription else { return }
		canRetryFailedTranscription = pendingRecordingURL != nil
		let message = canRetryFailedTranscription
			? "The background microphone session ended. Your recording is saved—tap Retry."
			: "The background microphone session ended. Tap Dictate to reconnect."
		state = .failed(message)
		publishFailure(
			message,
			for: interruptedRequestID,
			retryAvailable: canRetryFailedTranscription
		)
		currentRequestID = nil
	}

	func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
		guard recorder === audioRecorder || recorder === keepAliveRecorder else { return }
		if let error {
			logger.error("Audio recorder failed: \(error.localizedDescription, privacy: .public)")
		}
		if recorder === keepAliveRecorder {
			keepAliveRecorder = nil
			handleFlowSessionRecorderStopped()
			return
		}
		handleUnexpectedRecorderFailure()
	}

	private func handleUnexpectedRecorderFailure() {
		audioRecorder = nil
		keepAliveRecorder = nil
		recordingURL = nil
		meterTask?.cancel()
		meterTask = nil
		audioLevel = 0
		sharedStore.audioLevel = 0
		endFlowSession()
		canRetryFailedTranscription = pendingRecordingURL != nil
		let message = canRetryFailedTranscription
			? Self.savedRecordingMessage
			: "The microphone stopped unexpectedly. Tap Dictate to try again."
		state = .failed(message)
		publishFailure(message, retryAvailable: canRetryFailedTranscription)
		currentRequestID = nil
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
