import AVFoundation
import ArgmaxOSS
import CoreML
import Foundation
import OSLog
import UIKit

/// The flow engine owns the microphone for the entire background session.
/// Arming this sink turns its existing input tap from a discard-only keepalive
/// into a recorder without stopping or reacquiring the audio route.
private final class FlowAudioCaptureSink: @unchecked Sendable {
	private let lock = NSLock()
	private var file: AVAudioFile?
	private var writeError: NSError?
	private var normalizedLevel: Double = 0

	var isCapturing: Bool {
		lock.withLock { file != nil }
	}

	var audioLevel: Double {
		lock.withLock { normalizedLevel }
	}

	func start(url: URL, format: AVAudioFormat) throws {
		let newFile = try AVAudioFile(forWriting: url, settings: format.settings)
		lock.withLock {
			file = newFile
			writeError = nil
			normalizedLevel = 0
		}
	}

	func consume(_ buffer: AVAudioPCMBuffer) {
		lock.withLock {
			guard let file else { return }
			do {
				try file.write(from: buffer)
				normalizedLevel = Self.level(for: buffer)
			} catch {
				writeError = error as NSError
				self.file = nil
				normalizedLevel = 0
			}
		}
	}

	@discardableResult
	func stop() -> NSError? {
		lock.withLock {
			file = nil
			normalizedLevel = 0
			let error = writeError
			writeError = nil
			return error
		}
	}

	func takeWriteError() -> NSError? {
		lock.withLock {
			let error = writeError
			writeError = nil
			return error
		}
	}

	private static func level(for buffer: AVAudioPCMBuffer) -> Double {
		guard let samples = buffer.floatChannelData?.pointee,
		      buffer.frameLength > 0 else { return 0 }
		var sum: Float = 0
		for index in 0..<Int(buffer.frameLength) {
			let sample = samples[index]
			sum += sample * sample
		}
		let rms = sqrt(Double(sum) / Double(buffer.frameLength))
		let decibels = 20 * log10(max(rms, 0.000_001))
		return max(0, min(1, (decibels + 55) / 55))
	}
}

@MainActor
final class DictationCoordinator: NSObject, ObservableObject {
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
	@Published private(set) var activeModelName = "Preparing the transcription model"
	@Published private(set) var modelInstallationProgress: Double?
	@Published private(set) var modelInstallationMessage = ""
	var hasLoadedModel: Bool { whisperKit != nil }

    private let logger = Logger(subsystem: "sohail.Scribe.mobile", category: "Dictation")
    private let sharedStore = SharedDictationStore()
	private let refiner = TranscriptRefiner()
	private static let refinementPreferenceKey = "mobile.refineWithOnDeviceModel"
	/// Defaults on where the model is available; the toggle only has to persist
	/// an explicit opt-out.
	@Published var usesOnDeviceRefinement: Bool = UserDefaults.standard
		.object(forKey: "mobile.refineWithOnDeviceModel") as? Bool ?? true {
		didSet {
			UserDefaults.standard.set(usesOnDeviceRefinement, forKey: Self.refinementPreferenceKey)
		}
	}
	@Published private(set) var refinementReadiness: TranscriptRefiner.Readiness = .notReady

	func refreshRefinementReadiness() async {
		refinementReadiness = await refiner.readiness
	}
    private var whisperKit: WhisperKit?
    private var modelProfile: ScribeModelProfile?
	private let captureSink = FlowAudioCaptureSink()
    private var recordingURL: URL?
	private var pendingRecordingURL: URL?
	private var pendingRecordingRequestID: String?
    private var meterTask: Task<Void, Never>?
	private var sessionTask: Task<Void, Never>?
	private var preparationHeartbeatTask: Task<Void, Never>?
	private var backgroundFallbackPreparationTask: Task<Void, Error>?
	private var keepAliveEngine: AVAudioEngine?
    private var interruptionObserver: NSObjectProtocol?
    private var isPreparingModel = false
	private var isTranscribing = false
    private var isStartingRecording = false
	private var recordingStartGeneration: UUID?
    private var transcriptionGeneration: UUID?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
	private var modelPreparationTaskID: UIBackgroundTaskIdentifier = .invalid
	private var memoryWarningObserver: NSObjectProtocol?
	private var lastHeartbeat = Date.distantPast
	private var lastRecordingStatusRefresh = Date.distantPast
	private let processID = UUID().uuidString
	private var currentRequestID: String?
	private var requestGate = DictationRequestGate()
	private let pendingRecordingPathKey = "mobile.pendingRecordingPath"
	private let pendingRecordingRequestIDKey = "mobile.pendingRecordingRequestID"
	/// Keys written by builds that persisted a model downgrade. Background
	/// recovery is session-only now, so these stale preferences are discarded.
	private let legacyPreferenceKeys = [
		"mobile.preferCompatibilityModel",
		"mobile.compatibilityProfileSignature.v2",
		"mobile.modelFallback.signature.v3",
		"mobile.modelFallback.consecutiveFailures.v3",
		"mobile.modelFallback.lastFailureAt.v3",
	]
	private static let savedRecordingMessage = "Transcription failed, but your recording is saved. Tap Retry."
	private static let sessionDuration: TimeInterval = 15 * 60
	/// Generous enough for a long utterance on Large-v3 plus a model reload;
	/// far shorter than "forever", which is what a hang previously got.
	private static let transcriptionWatchdogTimeout: Duration = .seconds(240)
	private var transcriptionWorkTask: Task<[TranscriptionResult], Error>?

    override init() {
        super.init()
		removeObsoleteModelCaches()
		for key in legacyPreferenceKeys {
			UserDefaults.standard.removeObject(forKey: key)
		}
		if let data = UserDefaults.standard.data(forKey: "mobile.dictationHistory"),
		   let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
			history = decoded
		}
		if let path = UserDefaults.standard.string(forKey: pendingRecordingPathKey),
		   FileManager.default.fileExists(atPath: path) {
			pendingRecordingURL = URL(fileURLWithPath: path)
			pendingRecordingRequestID = PendingRecordingDelivery.requestID(
				persistedRequestID: UserDefaults.standard.string(forKey: pendingRecordingRequestIDKey),
				sharedStatus: sharedStore.status
			)
			if let pendingRecordingRequestID {
				UserDefaults.standard.set(pendingRecordingRequestID, forKey: pendingRecordingRequestIDKey)
			}
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
		observeMemoryWarnings()
    }

	/// Scribe holds the largest allocation on the device by a wide margin. It
	/// never listened for memory pressure, so iOS's warning — the one chance to
	/// survive by giving something back — passed unheard and the process was
	/// killed outright. Dropping the model is recoverable; being killed is not.
	private func observeMemoryWarnings() {
		guard memoryWarningObserver == nil else { return }
		memoryWarningObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.didReceiveMemoryWarningNotification,
			object: nil,
			queue: .main
		) { _ in
			Task { @MainActor [weak self] in
				await self?.releaseModelUnderMemoryPressure()
			}
		}
	}

	private func releaseModelUnderMemoryPressure() async {
		// Never pull the model out from under work in flight: the recording or
		// transcript would be lost, which is worse than the risk of the kill.
		guard whisperKit != nil,
		      !isPreparingModel,
		      !isTranscribing,
		      recordingURL == nil else { return }
		logger.warning("Releasing the transcription model after a memory warning")
		// A live session promises the keyboard that the app can accept a request
		// without being brought to the foreground. Once the model is released
		// that promise is false: trying to rebuild a large Core ML model in the
		// background is precisely the path most likely to be suspended or killed.
		// Withdraw the shared heartbeat first so every host app takes the safe
		// foreground handoff on its next Dictate tap.
		if isSessionActive { endFlowSession() }
		await unloadCurrentModel()
		activeModelName = "Model released to save memory"
		if state == .ready { state = .preparing }
	}

	deinit {
		meterTask?.cancel()
		sessionTask?.cancel()
		preparationHeartbeatTask?.cancel()
		backgroundFallbackPreparationTask?.cancel()
		if let keepAliveEngine {
			keepAliveEngine.inputNode.removeTap(onBus: 0)
			keepAliveEngine.stop()
		}
		if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
		if let memoryWarningObserver {
			NotificationCenter.default.removeObserver(memoryWarningObserver)
		}
    }

    func prepareModel() async {
		guard recordingURL == nil, !isStartingRecording, !isTranscribing else { return }
        state = .preparing
        do {
            try await prepareModelIfNeeded(profile: .highAccuracy)
			// The fallback must already be on disk before the user leaves Scribe.
			// Downloading it for the first time after a background Core ML failure
			// is too late: iOS may suspend the app before recovery can finish.
			try await ensureModelDownloaded(profile: .backgroundFallback)
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
			guard captureSink.isCapturing, recordingURL != nil else {
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
	// A flow session keeps the microphone route alive with an in-memory engine
	// that immediately discards interim buffers, so the app stays responsive in
	// the background and the keyboard
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
            // Scribe never plays audio, so `.record` avoids seizing the output
            // route. Critically, Bluetooth HFP is *not* requested: opting into it
            // routes capture through the headset's 8 kHz narrowband mic, which
            // sits below the 16 kHz band Whisper's mel front-end expects and was
            // quietly halving accuracy whenever AirPods were connected. Without
            // the option, iOS captures from the wideband built-in mic while
            // Bluetooth playback continues undisturbed.
            try session.setCategory(.record, mode: .measurement)
            // iOS silences every haptic on the device while a recording
            // session is active unless the session opts out. Scribe's flow
            // session keeps this recording route alive for up to 15 minutes
            // after a dictation, which is why keyboard haptics died the moment
            // a dictation ran and stayed dead until the session lapsed.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        } catch {
            presentRecordingFailure(error)
            return false
        }

		// The flow engine starts immediately after this returns. Publish the
		// shared live session only once that engine is verifiably active.
        return true
    }

	func endFlowSession() {
		recordingStartGeneration = nil
		stopKeepAliveEngine()
        sessionTask?.cancel()
        sessionTask = nil
        isSessionActive = false
        sessionExpiresAt = nil
        sharedStore.endSession(processID: processID)
		if recordingURL == nil, !isTranscribing {
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
				guard self.keepAliveEngine?.isRunning == true else {
					self.handleFlowSessionEngineStopped()
					return
				}

				if Date().timeIntervalSince(self.lastHeartbeat) >= 2 {
					self.lastHeartbeat = Date()
					self.sharedStore.refreshSessionHeartbeat(processID: self.processID)
				}
                if let expiry = self.sessionExpiresAt, Date() > expiry,
				   self.recordingURL == nil, !self.isTranscribing {
                    self.endFlowSession()
                    return
                }

				Task { @MainActor [weak self] in
					_ = await self?.handlePendingKeyboardRequest()
				}
            }
        }
    }

	private func startKeepAliveEngineIfIdle() throws {
		guard keepAliveEngine == nil else { return }
		let engine = AVAudioEngine()
		let input = engine.inputNode
		let format = input.outputFormat(forBus: 0)
		guard format.sampleRate > 0, format.channelCount > 0 else {
			throw DictationError.recordingDidNotStart
		}
		// iOS only keeps the containing app responsive to keyboard commands
		// while an audio route is active in the background. Consume and discard
		// these interim buffers in memory until an explicit dictation arms the sink.
		input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [captureSink] buffer, _ in
			captureSink.consume(buffer)
		}
		engine.prepare()
		do {
			try engine.start()
		} catch {
			input.removeTap(onBus: 0)
			throw error
		}
		guard engine.isRunning else {
			input.removeTap(onBus: 0)
			throw DictationError.recordingDidNotStart
		}
		keepAliveEngine = engine
	}

	@discardableResult
	private func restoreKeepAliveOrEndSession() -> Bool {
		guard isSessionActive else { return false }
		if keepAliveEngine?.isRunning == true {
			return true
		}

		// Losing the one engine during an armed capture loses the microphone.
		guard recordingURL == nil else {
			endFlowSession()
			return false
		}

			stopKeepAliveEngine()
			do {
			try startKeepAliveEngineIfIdle()
			guard keepAliveEngine?.isRunning == true else {
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

	private func stopKeepAliveEngine() {
		guard let engine = keepAliveEngine else { return }
		keepAliveEngine = nil
		engine.inputNode.removeTap(onBus: 0)
		engine.stop()
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
		if recordingURL != nil {
			_ = captureSink.stop()
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
		if recordingURL != nil, !captureSink.isCapturing {
			handleUnexpectedCaptureFailure()
			return
		}
		guard !isStartingRecording, !isTranscribing, recordingURL == nil else {
			if recordingURL != nil {
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
			if wasInvalidated, state == .preparing, recordingURL == nil, !isTranscribing {
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
			if UIApplication.shared.applicationState == .active {
				try await ensureModelDownloaded(profile: .backgroundFallback)
			}
        } catch {
			guard isCurrentRecordingStart(startGeneration, requestID: requestID) else { return }
            presentModelPreparationFailure(error)
            return
        }
		guard isCurrentRecordingStart(startGeneration, requestID: requestID) else { return }

		let audioSessionReady = await prepareAudioSessionForRecording()
		guard isCurrentRecordingStart(startGeneration, requestID: requestID) else {
			if audioSessionReady, !isSessionActive, recordingURL == nil {
				try? AVAudioSession.sharedInstance().setActive(
					false,
					options: .notifyOthersOnDeactivation
				)
			}
			return
		}
		guard audioSessionReady else { return }

        do {
            let url = try makePendingRecordingURL()
			try startKeepAliveEngineIfIdle()
			guard let engine = keepAliveEngine, engine.isRunning else {
				throw DictationError.recordingDidNotStart
			}
			let format = engine.inputNode.outputFormat(forBus: 0)
			try captureSink.start(url: url, format: format)
			guard captureSink.isCapturing else { throw DictationError.recordingDidNotStart }

            recordingURL = url
			pendingRecordingURL = url
			UserDefaults.standard.set(url.path, forKey: pendingRecordingPathKey)
			rememberPendingRecordingRequest(currentRequestID)
			if !isSessionActive {
				isSessionActive = true
				observeInterruptions()
				startSessionLoop()
			}
			extendSession()
			state = .recording
			publishStatus(.recording, "Listening…")
			lastRecordingStatusRefresh = Date()

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
		guard !isTranscribing, captureSink.isCapturing, let url = recordingURL else { return }

		let captureError = captureSink.stop()
		recordingURL = nil
		meterTask?.cancel()
        meterTask = nil
        audioLevel = 0
        sharedStore.audioLevel = 0
		state = .transcribing
		publishStatus(.transcribing, "Polishing your words…")
		if let captureError {
			logger.error("Audio capture failed before transcription: \(captureError.localizedDescription, privacy: .public)")
			handleUnexpectedCaptureFailure()
			return
		}
		if isSessionActive, !restoreKeepAliveOrEndSession() {
			// The keep-alive engine exists only to receive the *next* keyboard
			// command. Losing it must not abort transcription of audio that is
			// already complete and protected by a background task.
			logger.warning("Background session ended after recording; continuing the current transcription")
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
		if currentRequestID == nil {
			currentRequestID = pendingRecordingRequestID
		}

		state = .transcribing
		publishStatus(.transcribing, "Retrying saved recording…")
		if isSessionActive, !restoreKeepAliveOrEndSession() {
			logger.warning("Background session ended during Retry; continuing the saved transcription")
		}
		await processPendingRecording(at: url)
	}

	private func processPendingRecording(at url: URL) async {
		guard !isTranscribing else { return }
		isTranscribing = true
		let generation = UUID()
		let resultRequestID = currentRequestID ?? pendingRecordingRequestID
		rememberPendingRecordingRequest(resultRequestID)
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
			let results = try await runTranscriptionWithWatchdog(audioURL: url)
			guard transcriptionGeneration == generation else { return }
            let rawText = results.compactMap(\.text).joined(separator: " ")
            let ruleBasedText = TranscriptPolisher.polish(rawText)
            guard !ruleBasedText.isEmpty else { throw DictationError.noSpeechDetected }

            // Optional on-device language-model pass for punctuation and
            // sentence breaks. It returns nil whenever it is unavailable, slow,
            // or produced anything that is not a faithful cleanup, so the
            // deterministic result is always the floor rather than the risk.
            var polishedText = ruleBasedText
            if usesOnDeviceRefinement {
                publishStatus(.transcribing, "Polishing your words…")
                if let refined = await refiner.refine(ruleBasedText) {
                    polishedText = refined
                }
                guard transcriptionGeneration == generation else { return }
            }

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
			logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
			state = .failed(Self.savedRecordingMessage)
			canRetryFailedTranscription = true
			publishFailure(Self.savedRecordingMessage, for: resultRequestID, retryAvailable: true)
			currentRequestID = nil
        }
    }

	/// Transcription may never wedge this coordinator.
	///
	/// `isTranscribing` is cleared by `processPendingRecording`'s defer — which
	/// only runs if the awaited transcription *returns*. A hang inside model
	/// loading or CoreML (most commonly when the app is transcribing in the
	/// background) left the flag set forever, so every later request from any
	/// app was rejected as busy: dictation visibly recorded, then nothing ever
	/// pasted again until the process died. The watchdog turns a hang into an
	/// ordinary failure: the recording stays saved, Retry works, and the next
	/// attempt starts on a fresh engine.
	private func runTranscriptionWithWatchdog(audioURL: URL) async throws -> [TranscriptionResult] {
		let work = Task { [weak self] () throws -> [TranscriptionResult] in
			guard let self else { throw DictationError.modelUnavailable }
			return try await self.transcribeWithBackgroundRecovery(audioURL: audioURL)
		}
		transcriptionWorkTask = work
		defer { transcriptionWorkTask = nil }

		return try await withThrowingTaskGroup(of: [TranscriptionResult]?.self) { group in
			group.addTask { try await work.value }
			group.addTask {
				try? await Task.sleep(for: Self.transcriptionWatchdogTimeout)
				return nil
			}
			defer { group.cancelAll() }
			guard let first = try await group.next(), let results = first else {
				work.cancel()
				// The hung task may be stuck inside CoreML and unable to observe
				// cancellation. Abandon the engine reference so the next attempt
				// loads a clean one instead of sharing a wedged instance; the old
				// task still holds its own reference and simply gets discarded by
				// its generation check if it ever completes.
				logger.error("Transcription watchdog fired; abandoning the current engine")
				whisperKit = nil
				modelProfile = nil
				throw DictationError.transcriptionTimedOut
			}
			return results
		}
	}

    func cancelRecording() {
		recordingStartGeneration = nil
		_ = captureSink.stop()
		recordingURL = nil
		transcriptionGeneration = nil
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
		if let error = captureSink.takeWriteError() {
			logger.error("Audio capture failed: \(error.localizedDescription, privacy: .public)")
			handleUnexpectedCaptureFailure()
			return
		}
		guard captureSink.isCapturing else { return }
		let normalized = captureSink.audioLevel
        audioLevel = normalized
        sharedStore.audioLevel = normalized
		if Date().timeIntervalSince(lastRecordingStatusRefresh) > 2 {
			lastRecordingStatusRefresh = Date()
			sharedStore.refreshInFlightStatus(
				for: currentRequestID,
				processID: processID,
				phase: .recording
			)
		}
		if Date().timeIntervalSince(lastHeartbeat) > 2 {
			lastHeartbeat = Date()
			sharedStore.refreshSessionHeartbeat(processID: processID)
		}
    }

	private var modelDownloadBase: URL {
		// Documents survives app updates and TestFlight installs, which is what
		// keeps the ~945 MB model from re-downloading on every build. The other
		// half of that contract is the folder and marker names pinned in
		// ScribeModelPolicy.
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("huggingface", isDirectory: true)
	}

	private func prepareModelIfNeeded(profile: ScribeModelProfile) async throws {
		// Waiting on another caller's preparation must be bounded. This loop
		// used to spin forever, so one wedged load turned every subsequent
		// dictation into a silent wait.
		var waitAttempts = 0
		while true {
			if whisperKit != nil, modelProfile == profile { return }

			if isPreparingModel {
				waitAttempts += 1
				guard waitAttempts < 1_200 else { throw DictationError.modelUnavailable }
				try await Task.sleep(for: .milliseconds(100))
				continue
			}

			isPreparingModel = true
			defer { isPreparingModel = false }
			await unloadCurrentModel()
			let preparedKit = try await makeWhisperKit(profile: profile)
			whisperKit = preparedKit
			modelProfile = profile
			activeModelName = profile.displayName
			modelInstallationProgress = nil
			modelInstallationMessage = profile == .highAccuracy
				? "Transcription model ready"
				: "Reliable background model ready"
			return
		}
	}

	private func prepareModelWithRecovery() async throws {
		let ownsHeartbeat = startPreparationHeartbeatIfNeeded()
		// A live flow session lets the keyboard start a dictation while Scribe
		// is in the background, so this load frequently runs with the app not
		// on screen. Without an assertion iOS is free to suspend the process
		// part-way through, which surfaces to the user as the app dying while
		// the model loads. Transcription already held one; preparation did not.
		let ownsAssertion = beginModelPreparationTask()
		defer {
			if ownsHeartbeat { stopPreparationHeartbeat() }
			if ownsAssertion { endModelPreparationTask() }
		}
		// Once Large-v3 has failed during a live background session, keep using
		// the already-loaded CPU fallback for that session. Foreground
		// `prepareModel()` explicitly restores Large-v3.
		try await prepareModelIfNeeded(profile: modelProfile ?? .highAccuracy)
	}

	private func makeWhisperKit(profile: ScribeModelProfile) async throws -> WhisperKit {
		try prepareModelCacheDirectory()
		let existingFolder = cachedModelFolder(for: profile) ?? downloadedModelFolder(for: profile)
		let folder: URL
		if let existingFolder {
			folder = existingFolder
		} else {
			folder = try await downloadModel(profile: profile)
		}

		do {
			let kit = try await loadWhisperKit(profile: profile, folder: folder)
			do {
				try markModelReady(profile: profile, folder: folder)
			} catch {
				await kit.unloadModels()
				throw error
			}
			return kit
		} catch {
			guard existingFolder != nil,
			      shouldRepairModelCache(for: error) else { throw error }
			logger.warning("Cached \(profile.folderName, privacy: .public) model is incomplete; repairing it")
			invalidateModelMarkers(in: folder)
			let repairedFolder = try await downloadModel(profile: profile)
			let kit = try await loadWhisperKit(profile: profile, folder: repairedFolder)
			do {
				try markModelReady(profile: profile, folder: repairedFolder)
			} catch {
				await kit.unloadModels()
				throw error
			}
			return kit
		}
	}

	private func loadWhisperKit(profile: ScribeModelProfile, folder: URL) async throws -> WhisperKit {
		try Task.checkCancellation()
		let computeOptions: ModelComputeOptions? = profile.usesCPUOnly
			? ModelComputeOptions(
				melCompute: .cpuOnly,
				audioEncoderCompute: .cpuOnly,
				textDecoderCompute: .cpuOnly
			)
			: nil
		let config = WhisperKitConfig(
			downloadBase: modelDownloadBase,
			modelFolder: folder.path,
			tokenizerFolder: modelDownloadBase,
			computeOptions: computeOptions,
			verbose: false,
			prewarm: false,
			load: false,
			download: false
		)
		let kit = try await WhisperKit(config)
		if Task.isCancelled {
			await kit.unloadModels()
			throw CancellationError()
		}
		// `prewarmModels()` is `loadModels(prewarmMode: true)`, and prewarm mode
		// discards each component the instant it finishes loading it
		// (`model = prewarmMode ? nil : loadedModel`). Calling it before
		// `loadModels()` therefore read every weight file from disk twice and
		// paid the CoreML load cost twice, for no residual benefit — the
		// on-disk compilation cache that prewarming warms is populated by the
		// real load anyway. On a multi-hundred-megabyte model that doubled the
		// window in which the app could be killed mid-load.
		updateModelPreparationStatus("Loading private on-device transcription…")
		try await kit.loadModels()
		if Task.isCancelled {
			await kit.unloadModels()
			throw CancellationError()
		}
		return kit
	}

	private func ensureModelDownloaded(profile: ScribeModelProfile) async throws {
		guard downloadedModelFolder(for: profile) == nil else { return }
		if profile != .backgroundFallback {
			_ = try await downloadModel(profile: profile)
			return
		}
		if let backgroundFallbackPreparationTask {
			try await backgroundFallbackPreparationTask.value
			return
		}
		let task = Task { @MainActor [weak self] in
			guard let self else { throw DictationError.modelUnavailable }
			_ = try await self.downloadModel(profile: profile)
		}
		backgroundFallbackPreparationTask = task
		defer { backgroundFallbackPreparationTask = nil }
		try await task.value
	}

	private func downloadModel(profile: ScribeModelProfile) async throws -> URL {
		try Task.checkCancellation()
		if profile == .highAccuracy { try verifyModelStorage() }
		let previousIdleTimerState = UIApplication.shared.isIdleTimerDisabled
		if profile == .highAccuracy { UIApplication.shared.isIdleTimerDisabled = true }
		defer {
			if profile == .highAccuracy {
				UIApplication.shared.isIdleTimerDisabled = previousIdleTimerState
			}
		}

		var finalError: Error = DictationError.modelUnavailable
		let maximumAttempts = ScribeModelDownloadPolicy.maximumAttempts

		for attempt in 1...maximumAttempts {
			try Task.checkCancellation()
			try repairInvalidModelComponents(for: profile)
			let attemptLabel = attempt == 1
				? ""
				: " — resuming \(attempt)/\(maximumAttempts)"
			updateModelPreparationStatus(
				profile == .highAccuracy
					? "Installing the transcription model\(attemptLabel)…"
					: "Preparing reliable background recovery…",
				progress: 0
			)

			do {
				let returnedFolder = try await WhisperKit.download(
					variant: profile.downloadVariant,
					downloadBase: modelDownloadBase,
					from: ScribeModelPolicy.repository
				) { [weak self] progress in
					let fraction = progress.fractionCompleted
					Task { @MainActor [weak self] in
						let percent = Int((fraction * 100).rounded())
						self?.updateModelPreparationStatus(
							profile == .highAccuracy
								? "Installing the transcription model… \(percent)%"
								: "Preparing reliable background recovery… \(percent)%",
							progress: fraction
						)
					}
				}
				try Task.checkCancellation()
				let folder = modelFolder(for: profile)
				if returnedFolder.standardizedFileURL != folder.standardizedFileURL {
					logger.warning("WhisperKit returned an unexpected model cache path; validating the canonical cache instead")
				}
				let invalidComponents = invalidModelComponents(in: folder, profile: profile)
				guard invalidComponents.isEmpty else {
					throw DictationError.incompleteModelDownload(invalidComponents)
				}
				try markModelDownloaded(profile: profile, folder: folder)
				return folder
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				finalError = error
				guard attempt < maximumAttempts,
				      ScribeModelDownloadPolicy.isRetryable(error as NSError) else {
					throw error
				}
				logger.warning("Model download attempt \(attempt) was interrupted; resuming the partial cache: \(error.localizedDescription, privacy: .public)")
				updateModelPreparationStatus(
					"The download was interrupted — resuming…",
					progress: nil
				)
				try await Task.sleep(
					for: .seconds(ScribeModelDownloadPolicy.retryDelay(afterFailedAttempt: attempt))
				)
			}
		}
		throw finalError
	}

	private func verifyModelStorage() throws {
		guard let values = try? modelDownloadBase.resourceValues(forKeys: [
			.volumeAvailableCapacityForImportantUsageKey,
			.volumeAvailableCapacityKey,
		]) else { return }
		let capacity = values.volumeAvailableCapacityForImportantUsage
			?? values.volumeAvailableCapacity.map(Int64.init)
		if let capacity,
		   capacity < ScribeModelDownloadPolicy.minimumCapacity {
			throw DictationError.insufficientModelStorage
		}
	}

	private func cachedModelFolder(for profile: ScribeModelProfile) -> URL? {
		let folder = modelFolder(for: profile)
		return hasCompleteModelComponents(in: folder, profile: profile)
			&& FileManager.default.fileExists(atPath: readyMarker(in: folder).path)
			? folder
			: nil
	}

	private func downloadedModelFolder(for profile: ScribeModelProfile) -> URL? {
		let folder = modelFolder(for: profile)
		return hasCompleteModelComponents(in: folder, profile: profile)
			&& FileManager.default.fileExists(atPath: downloadedMarker(in: folder).path)
			? folder
			: nil
	}

	private func modelFolder(for profile: ScribeModelProfile) -> URL {
		let repositoryRoot = HubApiWrapper(downloadBase: modelDownloadBase).localRepoLocation(
			HubApiWrapper.Repo(id: ScribeModelPolicy.repository)
		)
		return repositoryRoot.appendingPathComponent(
			profile.folderName,
			isDirectory: true
		)
	}

	/// Frees caches for models that are no longer live. Best-effort and
	/// asynchronous; failure just leaves dead weight.
	private func removeObsoleteModelCaches() {
		let repositoryRoot = HubApiWrapper(downloadBase: modelDownloadBase).localRepoLocation(
			HubApiWrapper.Repo(id: ScribeModelPolicy.repository)
		)
		let obsoleteFolderNames = ScribeModelPolicy.obsoleteModelFolderNames
		Task.detached(priority: .utility) { [logger] in
			for name in obsoleteFolderNames {
				let folder = repositoryRoot.appendingPathComponent(name, isDirectory: true)
				guard FileManager.default.fileExists(atPath: folder.path) else { continue }
				logger.notice("Removing obsolete model cache \(name, privacy: .public)")
				try? FileManager.default.removeItem(at: folder)
			}
		}
	}

	private func downloadedMarker(in folder: URL) -> URL {
		folder.appendingPathComponent(ScribeModelPolicy.downloadedMarkerName)
	}

	private func readyMarker(in folder: URL) -> URL {
		folder.appendingPathComponent(ScribeModelPolicy.readyMarkerName)
	}

	private func markModelDownloaded(profile: ScribeModelProfile, folder: URL) throws {
		guard folder.standardizedFileURL == modelFolder(for: profile).standardizedFileURL,
		      hasCompleteModelComponents(in: folder, profile: profile) else {
			throw DictationError.incompleteModelDownload(
				invalidModelComponents(in: folder, profile: profile)
			)
		}
		try Data("downloaded\n".utf8).write(to: downloadedMarker(in: folder), options: .atomic)
	}

	private func markModelReady(profile: ScribeModelProfile, folder: URL) throws {
		try markModelDownloaded(profile: profile, folder: folder)
		try Data("ready\n".utf8).write(to: readyMarker(in: folder), options: .atomic)
	}

	private func invalidateModelMarkers(in folder: URL) {
		try? FileManager.default.removeItem(at: downloadedMarker(in: folder))
		try? FileManager.default.removeItem(at: readyMarker(in: folder))
	}

	private func hasCompleteModelComponents(
		in folder: URL,
		profile: ScribeModelProfile
	) -> Bool {
		invalidModelComponents(in: folder, profile: profile).isEmpty
	}

	private func invalidModelComponents(
		in folder: URL,
		profile: ScribeModelProfile
	) -> [String] {
		profile.componentRequirements.compactMap { requirement in
			let component = folder.appendingPathComponent(
				"\(requirement.name).mlmodelc",
				isDirectory: true
			)
			let requiredFiles = [
				component.appendingPathComponent("coremldata.bin"),
				component.appendingPathComponent("model.mil"),
				component.appendingPathComponent("weights/weight.bin"),
			]
			guard requiredFiles.allSatisfy({ fileSize(at: $0) > 0 }) else {
				return requirement.name
			}
			if let minimumWeightBytes = requirement.minimumWeightBytes,
			   fileSize(at: requiredFiles[2]) < minimumWeightBytes {
				return requirement.name
			}
			return nil
		}
	}

	private func fileSize(at url: URL) -> Int64 {
		let values = try? url.resourceValues(forKeys: [.fileSizeKey])
		return Int64(values?.fileSize ?? 0)
	}

	private func repairInvalidModelComponents(for profile: ScribeModelProfile) throws {
		let folder = modelFolder(for: profile)
		let invalidComponents = invalidModelComponents(in: folder, profile: profile)
		guard !invalidComponents.isEmpty else { return }

		invalidateModelMarkers(in: folder)
		for componentName in invalidComponents {
			let component = folder.appendingPathComponent(
				"\(componentName).mlmodelc",
				isDirectory: true
			)
			guard FileManager.default.fileExists(atPath: component.path) else { continue }
			logger.warning("Removing incomplete \(componentName, privacy: .public) cache component before resume")
			try FileManager.default.removeItem(at: component)
		}
	}

	private func prepareModelCacheDirectory() throws {
		try FileManager.default.createDirectory(
			at: modelDownloadBase,
			withIntermediateDirectories: true
		)
		var cacheURL = modelDownloadBase
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		try? cacheURL.setResourceValues(values)
	}

	private func transcribeWithBackgroundRecovery(audioURL: URL) async throws -> [TranscriptionResult] {
		// These match the Mac build's decoding behaviour. Timestamp tokens stay
		// enabled: they anchor segmentation and feed the compression-ratio and
		// no-speech fallbacks, and suppressing them on the Large-v3 family is a
		// well-known source of repetition loops and dropped clause boundaries.
		let options = DecodingOptions(
			language: ScribeDictationLanguagePolicy.language(
				forPreferred: Locale.preferredLanguages
			),
			skipSpecialTokens: true,
			withoutTimestamps: false,
			suppressBlank: true
		)
		let attemptBeganInBackground = UIApplication.shared.applicationState != .active
		try await prepareModelWithRecovery()
		guard let whisperKit, let attemptedProfile = modelProfile else {
			throw DictationError.modelUnavailable
		}
		do {
			return try await whisperKit.transcribe(
				audioPath: audioURL.path,
				decodeOptions: options
			)
		} catch {
			guard BackgroundTranscriptionRecoveryPolicy.shouldRetryWithFallback(
				attemptBeganInBackground: attemptBeganInBackground,
				attemptedProfile: attemptedProfile
			) else { throw error }
			logger.warning("Large-v3 background transcription failed; retrying saved audio with CPU fallback: \(error.localizedDescription, privacy: .public)")
			publishStatus(.transcribing, "Recovering background transcription…")
			try await prepareModelIfNeeded(profile: .backgroundFallback)
			guard let fallbackKit = self.whisperKit else {
				throw DictationError.modelUnavailable
			}
			return try await fallbackKit.transcribe(
				audioPath: audioURL.path,
				decodeOptions: options
			)
		}
	}

	private func unloadCurrentModel() async {
		if let whisperKit {
			await whisperKit.unloadModels()
		}
		whisperKit = nil
		modelProfile = nil
	}

	private func startPreparationHeartbeatIfNeeded() -> Bool {
		guard currentRequestID != nil, preparationHeartbeatTask == nil else { return false }
		preparationHeartbeatTask = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(2))
				guard let self, !Task.isCancelled, self.currentRequestID != nil else { return }
				self.publishStatus(
					self.isTranscribing ? .transcribing : .preparing,
					self.modelInstallationMessage.isEmpty
						? "Preparing private on-device transcription…"
						: self.modelInstallationMessage
				)
			}
		}
		return true
	}

	private func stopPreparationHeartbeat() {
		preparationHeartbeatTask?.cancel()
		preparationHeartbeatTask = nil
	}

	private func updateModelPreparationStatus(
		_ message: String,
		progress: Double? = nil,
		publishToCurrentRequest: Bool = true
	) {
		modelInstallationMessage = message
		if let progress {
			modelInstallationProgress = max(0, min(1, progress))
		}
		if publishToCurrentRequest, currentRequestID != nil {
			publishStatus(isTranscribing ? .transcribing : .preparing, message)
		}
	}

	private func shouldRepairModelCache(for error: Error) -> Bool {
		let description = (error as NSError).localizedDescription.lowercased()
		return description.contains("model file not found")
			|| description.contains("model folder is not set")
			|| description.contains("models unavailable")
			|| description.contains("incomplete")
	}

	private func makePendingRecordingURL() throws -> URL {
		let folder = try FileManager.default.url(
			for: .applicationSupportDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		).appendingPathComponent("PendingDictations", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		// AVAudioFile picks its container from the extension. The flow engine's
		// uncompressed PCM therefore lands in a WAV rather than the old M4A.
		return folder
			.appendingPathComponent("scribe-\(UUID().uuidString)")
			.appendingPathExtension("wav")
	}

	private func discardPendingRecording() {
		if let pendingRecordingURL {
			try? FileManager.default.removeItem(at: pendingRecordingURL)
		}
		pendingRecordingURL = nil
		pendingRecordingRequestID = nil
		UserDefaults.standard.removeObject(forKey: pendingRecordingPathKey)
		UserDefaults.standard.removeObject(forKey: pendingRecordingRequestIDKey)
	}

	private func rememberPendingRecordingRequest(_ requestID: String?) {
		guard let requestID, !requestID.isEmpty else { return }
		pendingRecordingRequestID = requestID
		UserDefaults.standard.set(requestID, forKey: pendingRecordingRequestIDKey)
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

	/// Kept separate from the transcription assertion: model preparation nests
	/// inside transcription, and sharing one identifier would let the inner
	/// scope end the outer one early.
	private func beginModelPreparationTask() -> Bool {
		guard modelPreparationTaskID == .invalid else { return false }
		modelPreparationTaskID = UIApplication.shared.beginBackgroundTask(
			withName: "Prepare Scribe transcription model"
		) {
			Task { @MainActor [weak self] in
				self?.endModelPreparationTask()
			}
		}
		return modelPreparationTaskID != .invalid
	}

	private func endModelPreparationTask() {
		guard modelPreparationTaskID != .invalid else { return }
		UIApplication.shared.endBackgroundTask(modelPreparationTaskID)
		modelPreparationTaskID = .invalid
	}

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
		backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Finish Scribe transcription") {
			Task { @MainActor [weak self] in
				self?.handleBackgroundTaskExpiration()
			}
		}
    }

	private func handleBackgroundTaskExpiration() {
		guard isTranscribing else {
			endBackgroundTask()
			return
		}
		transcriptionGeneration = nil
		// Cancel the in-flight work as well: without this, the abandoned task
		// kept running and kept `isTranscribing` set, busy-failing every later
		// request from every app.
		transcriptionWorkTask?.cancel()
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

	private func handleFlowSessionEngineStopped() {
		guard isSessionActive else { return }
		if recordingURL != nil {
			handleUnexpectedCaptureFailure()
			return
		}

		let interruptedRequestID = currentRequestID
		let interruptedTranscription = isTranscribing
		endFlowSession()
		if interruptedTranscription {
			// Core ML transcription does not depend on the microphone keep-alive
			// engine. The background task owns this in-flight work, so let it
			// finish and publish instead of converting a harmless session loss
			// into a permanent saved-recording banner.
			logger.warning("Background keep-alive stopped during transcription; allowing transcription to finish")
			return
		}

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

	private func handleUnexpectedCaptureFailure() {
		_ = captureSink.stop()
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
    case insufficientModelStorage
	case incompleteModelDownload([String])
    case noSpeechDetected
	case transcriptionTimedOut

    var errorDescription: String? {
        switch self {
        case .recordingDidNotStart:
            "Scribe couldn’t start recording."
        case .modelUnavailable:
            "The on-device transcription model isn’t ready."
        case .insufficientModelStorage:
            "Scribe needs about 1.9 GB of free storage for its transcription model."
		case .incompleteModelDownload(let components):
			"The model download is incomplete: \(components.joined(separator: ", "))."
        case .noSpeechDetected:
            "Scribe didn’t hear any speech. Please try again."
		case .transcriptionTimedOut:
			"Transcription took too long. Your recording is saved — tap Retry."
        }
    }

	var modelInstallationMessage: String {
		switch self {
		case .insufficientModelStorage:
			"Scribe needs about 1.9 GB free for its transcription model. Free some storage, then try again."
		case .incompleteModelDownload:
			"The model cache is incomplete. Try again — Scribe will repair and resume it."
		case .modelUnavailable, .recordingDidNotStart, .noSpeechDetected, .transcriptionTimedOut:
			errorDescription ?? "The model install couldn’t finish. Please try again."
		}
	}
}
