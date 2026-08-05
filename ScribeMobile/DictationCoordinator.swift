import AVFoundation
import ArgmaxOSS
import CoreML
import Foundation
import OSLog
import UIKit

@MainActor
final class DictationCoordinator: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate {
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
	@Published private(set) var activeModelName = "Preparing High Accuracy model"
	@Published private(set) var modelInstallationProgress: Double?
	@Published private(set) var modelInstallationMessage = ""
	var isUsingCompatibilityModel: Bool { modelProfile == .compatibility }
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
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
	private var pendingRecordingURL: URL?
    private var meterTask: Task<Void, Never>?
	private var sessionTask: Task<Void, Never>?
	private var qualityInstallTask: Task<Void, Never>?
	private var qualityInstallGeneration: UUID?
	private var qualityRetryGeneration: UUID?
	private var preparationHeartbeatTask: Task<Void, Never>?
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
	private let processID = UUID().uuidString
	private var currentRequestID: String?
	private var requestGate = DictationRequestGate()
	private let pendingRecordingPathKey = "mobile.pendingRecordingPath"
	private let fallbackSignatureKey = "mobile.modelFallback.signature.v3"
	private let fallbackFailureCountKey = "mobile.modelFallback.consecutiveFailures.v3"
	private let fallbackLastFailureKey = "mobile.modelFallback.lastFailureAt.v3"
	private let legacyPreferenceKeys = [
		"mobile.preferCompatibilityModel",
		"mobile.compatibilityProfileSignature.v2",
	]
	/// Set when High Accuracy fails during this launch. It keeps the current
	/// session on Base without writing anything durable, so relaunching always
	/// gives the quality model another chance.
	private var sessionOnlyCompatibilityFallback = false
	private static let savedRecordingMessage = "Transcription failed, but your recording is saved. Tap Retry."
	private static let sessionDuration: TimeInterval = 15 * 60

    override init() {
        super.init()
		// Earlier builds stored a sticky downgrade that permanently trapped
		// devices on Base after a single transient fault. Version 3 replaces it
		// with a lapsing, failure-counted policy and discards the old keys.
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
		      audioRecorder == nil else { return }
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
		qualityInstallTask?.cancel()
		preparationHeartbeatTask?.cancel()
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
		stopKeepAliveEngine()
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
				        || self.keepAliveEngine?.isRunning == true else {
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

	private func startKeepAliveEngineIfIdle() throws {
		guard audioRecorder == nil, keepAliveEngine == nil else { return }
		let engine = AVAudioEngine()
		let input = engine.inputNode
		let format = input.outputFormat(forBus: 0)
		guard format.sampleRate > 0, format.channelCount > 0 else {
			throw DictationError.recordingDidNotStart
		}
		// iOS only keeps the containing app responsive to keyboard commands
		// while an audio route is active in the background. Consume and discard
		// these interim buffers in memory; only explicit dictations use a recorder.
		input.installTap(onBus: 0, bufferSize: 4_096, format: format) { _, _ in }
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
		if audioRecorder?.isRecording == true || keepAliveEngine?.isRunning == true {
			return true
		}

		// A stopped primary recorder means the active recording was lost; do not
		// disguise that as a healthy background session.
		guard audioRecorder == nil else {
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
		stopKeepAliveEngine()

        do {
            let url = try makePendingRecordingURL()
            // Uncompressed 16 kHz mono PCM, matching the Mac recorder. The old
            // AAC encode threw away spectral detail before Whisper ever saw the
            // audio; at these durations the file-size saving is irrelevant and
            // the codec artefacts are not.
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
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

	private var osMajorVersion: Int {
		ProcessInfo.processInfo.operatingSystemVersion.majorVersion
	}

	private var storedFallbackState: ScribeModelFallbackState {
		let defaults = UserDefaults.standard
		let lastFailure = defaults.object(forKey: fallbackLastFailureKey) as? Date
		return ScribeModelFallbackState(
			signature: defaults.string(forKey: fallbackSignatureKey),
			consecutiveFailures: defaults.integer(forKey: fallbackFailureCountKey),
			lastFailureAt: lastFailure
		)
	}

	/// What the stored policy says this device should use across launches,
	/// ignoring any in-session fallback. Background installation follows this so
	/// a failed *load* never stops a perfectly healthy *download*.
	private var durableModelProfile: ScribeModelProfile {
		ScribeModelFallbackPolicy.preferredProfile(
			fallbackState: storedFallbackState,
			osMajorVersion: osMajorVersion
		)
	}

	private var preferredModelProfile: ScribeModelProfile {
		sessionOnlyCompatibilityFallback ? .compatibility : durableModelProfile
	}

	private var modelDownloadBase: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("huggingface", isDirectory: true)
	}

	private func prepareModelIfNeeded(profile: ScribeModelProfile) async throws {
		while true {
			if whisperKit != nil, modelProfile == profile { return }

			if isPreparingModel {
				try await Task.sleep(for: .milliseconds(100))
				continue
			}

			isPreparingModel = true
			defer { isPreparingModel = false }
			let previousProfile = modelProfile
			await unloadCurrentModel()
			do {
				let preparedKit = try await makeWhisperKit(profile: profile)
				whisperKit = preparedKit
				modelProfile = profile
				activeModelName = profile.displayName
				modelInstallationProgress = nil
				if profile == .highAccuracy {
					// A working load clears the failure history outright, so an
					// old transient fault cannot accumulate toward a downgrade.
					recordHighAccuracySuccess()
					modelInstallationMessage = "High Accuracy model ready"
				} else {
					modelInstallationMessage = "Compatibility model ready"
				}
				return
			} catch {
				// Switching models must never destroy a known-good engine. This is
				// especially important when a downloaded Large-v3 model fails during
				// first-device prewarm: restore Base before exposing the failure.
				if let previousProfile {
					do {
						let restoredKit = try await makeWhisperKit(
							profile: previousProfile,
							honorsCancellation: false
						)
						whisperKit = restoredKit
						modelProfile = previousProfile
						activeModelName = previousProfile.displayName
					} catch {
						logger.error("Could not restore the previous transcription model: \(error.localizedDescription, privacy: .public)")
					}
				}
				throw error
			}
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

		let preferredProfile = preferredModelProfile
		if preferredProfile == .highAccuracy,
		   downloadedModelFolder(for: .highAccuracy) == nil,
		   localCompatibilityModelFolder() != nil {
			// Existing users already have Base. Keep dictation immediately
			// available while the 1.6 GB quality model installs in parallel.
			try await prepareModelIfNeeded(profile: .compatibility)
			stageHighAccuracyModelIfNeeded()
			return
		}

		do {
			try await prepareModelIfNeeded(profile: preferredProfile)
		} catch {
			guard preferredProfile == .highAccuracy else { throw error }
			logger.warning("High Accuracy model preparation failed; switching to Base: \(error.localizedDescription, privacy: .public)")
			recordHighAccuracyFailure()
			updateModelPreparationStatus("Switching to the reliable on-device fallback…")
			try await prepareModelIfNeeded(profile: .compatibility)
			modelInstallationProgress = nil
			modelInstallationMessage = "Compatibility model ready"
			// Keep installing the quality model unless this device has now failed
			// often enough to earn a durable downgrade.
			stageHighAccuracyModelIfNeeded()
		}
	}

	private func makeWhisperKit(
		profile: ScribeModelProfile,
		honorsCancellation: Bool = true
	) async throws -> WhisperKit {
		try prepareModelCacheDirectory()
		let readyFolder = cachedModelFolder(for: profile)
		let downloadedFolder = downloadedModelFolder(for: profile)
		let legacyFolder = legacyCompatibilityModelFolder(for: profile)
		let existingFolder = readyFolder ?? downloadedFolder ?? legacyFolder
		let isLegacyUnverifiedFolder = readyFolder == nil
			&& downloadedFolder == nil
			&& legacyFolder != nil
		let folder: URL
		if let existingFolder {
			folder = existingFolder
		} else {
			folder = try await downloadModel(profile, honorsCancellation: honorsCancellation)
		}

		do {
			let kit = try await loadWhisperKit(
				profile: profile,
				folder: folder,
				honorsCancellation: honorsCancellation
			)
			do {
				try markModelReady(profile: profile, folder: folder)
			} catch {
				await kit.unloadModels()
				throw error
			}
			return kit
		} catch {
			guard existingFolder != nil,
			      isLegacyUnverifiedFolder || shouldRepairModelCache(for: error) else { throw error }
			logger.warning("Cached \(profile.folderName, privacy: .public) model is incomplete; repairing it")
			invalidateModelMarkers(in: folder)
			let repairedFolder = try await downloadModel(
				profile,
				honorsCancellation: honorsCancellation
			)
			let kit = try await loadWhisperKit(
				profile: profile,
				folder: repairedFolder,
				honorsCancellation: honorsCancellation
			)
			do {
				try markModelReady(profile: profile, folder: repairedFolder)
			} catch {
				await kit.unloadModels()
				throw error
			}
			return kit
		}
	}

	private func loadWhisperKit(
		profile: ScribeModelProfile,
		folder: URL,
		honorsCancellation: Bool
	) async throws -> WhisperKit {
		if honorsCancellation { try Task.checkCancellation() }
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
		if honorsCancellation, Task.isCancelled {
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
		if honorsCancellation, Task.isCancelled {
			await kit.unloadModels()
			throw CancellationError()
		}
		return kit
	}

	private func downloadModel(
		_ profile: ScribeModelProfile,
		publishToCurrentRequest: Bool = true,
		installationGeneration: UUID? = nil,
		honorsCancellation: Bool = true
	) async throws -> URL {
		if honorsCancellation { try Task.checkCancellation() }
		if profile == .highAccuracy { try verifyHighAccuracyStorage() }
		let previousIdleTimerState = UIApplication.shared.isIdleTimerDisabled
		if profile == .highAccuracy { UIApplication.shared.isIdleTimerDisabled = true }
		defer {
			if profile == .highAccuracy {
				UIApplication.shared.isIdleTimerDisabled = previousIdleTimerState
			}
		}

		let maximumAttempts = profile == .highAccuracy
			? ScribeModelDownloadPolicy.maximumAttempts
			: 1
		var finalError: Error = DictationError.modelUnavailable

		for attempt in 1...maximumAttempts {
			if honorsCancellation { try Task.checkCancellation() }
			try repairInvalidModelComponents(for: profile)
			let attemptLabel = attempt == 1 ? "" : " — resuming \(attempt)/\(maximumAttempts)"
			updateModelPreparationStatus(
				profile == .highAccuracy
					? "Installing High Accuracy model\(attemptLabel)…"
					: "Installing the on-device fallback…",
				progress: 0,
				publishToCurrentRequest: publishToCurrentRequest
			)

			do {
				let returnedFolder = try await WhisperKit.download(
					variant: profile.downloadVariant,
					downloadBase: modelDownloadBase,
					from: ScribeModelPolicy.repository
				) { [weak self] progress in
					let fraction = progress.fractionCompleted
					Task { @MainActor [weak self] in
						guard let self else { return }
						if let installationGeneration,
						   self.qualityInstallGeneration != installationGeneration {
							return
						}
						let percent = Int((fraction * 100).rounded())
						self.updateModelPreparationStatus(
							profile == .highAccuracy
								? "Installing High Accuracy model… \(percent)%"
								: "Installing the on-device fallback… \(percent)%",
							progress: fraction,
							publishToCurrentRequest: publishToCurrentRequest
						)
					}
				}
				if honorsCancellation { try Task.checkCancellation() }
				if let installationGeneration,
				   qualityInstallGeneration != installationGeneration {
					throw CancellationError()
				}
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
				logger.warning("High Accuracy download attempt \(attempt) was interrupted; resuming the partial cache: \(error.localizedDescription, privacy: .public)")
				updateModelPreparationStatus(
					"High Accuracy was interrupted — resuming partial download…",
					progress: nil,
					publishToCurrentRequest: publishToCurrentRequest
				)
				try await Task.sleep(
					for: .seconds(ScribeModelDownloadPolicy.retryDelay(afterFailedAttempt: attempt))
				)
			}
		}
		throw finalError
	}

	private func verifyHighAccuracyStorage() throws {
		guard let values = try? modelDownloadBase.resourceValues(forKeys: [
			.volumeAvailableCapacityForImportantUsageKey,
			.volumeAvailableCapacityKey,
		]) else { return }
		let capacity = values.volumeAvailableCapacityForImportantUsage
			?? values.volumeAvailableCapacity.map(Int64.init)
		if let capacity,
		   capacity < ScribeModelDownloadPolicy.minimumHighAccuracyCapacity {
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

	private func localCompatibilityModelFolder() -> URL? {
		cachedModelFolder(for: .compatibility)
			?? downloadedModelFolder(for: .compatibility)
			?? legacyCompatibilityModelFolder(for: .compatibility)
	}

	private func legacyCompatibilityModelFolder(for profile: ScribeModelProfile) -> URL? {
		guard profile == .compatibility else { return nil }
		let folder = modelFolder(for: profile)
		return hasCompleteModelComponents(in: folder, profile: profile) ? folder : nil
	}

	private func modelFolder(for profile: ScribeModelProfile) -> URL {
		let repositoryRoot = HubApiWrapper(downloadBase: modelDownloadBase).localRepoLocation(
			HubApiWrapper.Repo(id: ScribeModelPolicy.repository)
		)
		return repositoryRoot.appendingPathComponent(profile.folderName, isDirectory: true)
	}

	private func downloadedMarker(in folder: URL) -> URL {
		folder.appendingPathComponent(".scribe-download-complete-v2")
	}

	private func readyMarker(in folder: URL) -> URL {
		folder.appendingPathComponent(".scribe-ready-v2")
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

	private func stageHighAccuracyModelIfNeeded() {
		guard qualityInstallTask == nil,
		      durableModelProfile == .highAccuracy,
		      downloadedModelFolder(for: .highAccuracy) == nil else { return }

		let generation = UUID()
		qualityInstallGeneration = generation
		qualityInstallTask = Task { @MainActor [weak self] in
			guard let self else { return }
			defer {
				if self.qualityInstallGeneration == generation {
					self.qualityInstallTask = nil
					self.qualityInstallGeneration = nil
				}
			}
			do {
				try self.prepareModelCacheDirectory()
				_ = try await self.downloadModel(
					.highAccuracy,
					publishToCurrentRequest: false,
					installationGeneration: generation
				)
				try Task.checkCancellation()
				guard self.qualityInstallGeneration == generation else {
					throw CancellationError()
				}
				self.modelInstallationProgress = nil
				self.modelInstallationMessage = "High Accuracy model downloaded — activates on next dictation"
			} catch is CancellationError {
				return
			} catch {
				self.logger.warning("High Accuracy model installation paused: \(error.localizedDescription, privacy: .public)")
				self.modelInstallationProgress = nil
				if let dictationError = error as? DictationError {
					self.modelInstallationMessage = dictationError.modelInstallationMessage
				} else {
					self.modelInstallationMessage = ScribeModelDownloadPolicy.installationFailureMessage(
						for: error as NSError
					)
				}
			}
		}
	}

	private func transcribeWithRecovery(audioURL: URL) async throws -> [TranscriptionResult] {
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
		do {
			try await prepareModelWithRecovery()
			guard let whisperKit else { throw DictationError.modelUnavailable }
			return try await whisperKit.transcribe(
				audioPath: audioURL.path,
				decodeOptions: options
			)
		} catch {
			guard modelProfile != .compatibility,
			      shouldUseCompatibilityMode(for: error) else { throw error }
			logger.warning("High Accuracy transcription failed; retrying the saved audio with Base: \(error.localizedDescription, privacy: .public)")
			publishStatus(.transcribing, "Retrying with the reliable on-device fallback…")
			recordHighAccuracyFailure()
			await unloadCurrentModel()
			try await prepareModelIfNeeded(profile: .compatibility)
			guard let whisperKit else { throw DictationError.modelUnavailable }
			return try await whisperKit.transcribe(
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

	/// Records one High Accuracy failure. The fallback stays in memory until the
	/// device has failed repeatedly; only then does it survive a relaunch, and
	/// even then it lapses so the quality model gets re-tested.
	private func recordHighAccuracyFailure() {
		sessionOnlyCompatibilityFallback = true
		let updated = ScribeModelFallbackPolicy.stateAfterFailure(
			storedFallbackState,
			osMajorVersion: osMajorVersion
		)
		let defaults = UserDefaults.standard
		defaults.set(updated.signature, forKey: fallbackSignatureKey)
		defaults.set(updated.consecutiveFailures, forKey: fallbackFailureCountKey)
		defaults.set(updated.lastFailureAt, forKey: fallbackLastFailureKey)
		logger.warning("High Accuracy failure \(updated.consecutiveFailures, privacy: .public) of \(ScribeModelFallbackPolicy.failuresBeforePersisting, privacy: .public) before the preference persists")
	}

	private func recordHighAccuracySuccess() {
		sessionOnlyCompatibilityFallback = false
		guard storedFallbackState != .empty else { return }
		let defaults = UserDefaults.standard
		defaults.removeObject(forKey: fallbackSignatureKey)
		defaults.removeObject(forKey: fallbackFailureCountKey)
		defaults.removeObject(forKey: fallbackLastFailureKey)
	}

	func retryHighAccuracyModel() {
		recordHighAccuracySuccess()
		modelInstallationMessage = "Resuming the High Accuracy download…"
		let generation = UUID()
		qualityRetryGeneration = generation
		let installTask = qualityInstallTask
		installTask?.cancel()
		Task { @MainActor [weak self] in
			await installTask?.value
			guard let self,
			      self.qualityRetryGeneration == generation else { return }
			self.qualityRetryGeneration = nil
			await self.prepareModel()
		}
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

	private func shouldUseCompatibilityMode(for error: Error) -> Bool {
		let nsError = error as NSError
		let haystack = "\(nsError.domain) \(nsError.localizedDescription)".lowercased()
		return haystack.contains("coreml")
			|| haystack.contains("ml program")
			|| haystack.contains("prediction")
			|| haystack.contains("compute device")
			|| haystack.contains("espresso")
			|| haystack.contains("neural engine")
			|| haystack.contains("out of memory")
			|| haystack.contains("allocation failed")
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
		// AVAudioRecorder picks its container from the extension, so linear PCM
		// has to land in a .wav rather than the old .m4a.
		return folder
			.appendingPathComponent("scribe-\(UUID().uuidString)")
			.appendingPathExtension("wav")
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
		guard recorder === audioRecorder else { return }
		if let error {
			logger.error("Audio recorder failed: \(error.localizedDescription, privacy: .public)")
		}
		handleUnexpectedRecorderFailure()
	}

	private func handleUnexpectedRecorderFailure() {
		audioRecorder = nil
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

    var errorDescription: String? {
        switch self {
        case .recordingDidNotStart:
            "Scribe couldn’t start recording."
        case .modelUnavailable:
            "The on-device transcription model isn’t ready."
        case .insufficientModelStorage:
            "High Accuracy needs about 1.9 GB of free storage."
		case .incompleteModelDownload(let components):
			"The High Accuracy download is incomplete: \(components.joined(separator: ", "))."
        case .noSpeechDetected:
            "Scribe didn’t hear any speech. Please try again."
        }
    }

	var modelInstallationMessage: String {
		switch self {
		case .insufficientModelStorage:
			"High Accuracy needs about 1.9 GB free. Free some storage, then try again."
		case .incompleteModelDownload:
			"High Accuracy found an incomplete cache. Tap Try High Accuracy again — Scribe will repair and resume it."
		case .modelUnavailable, .recordingDidNotStart, .noSpeechDetected:
			errorDescription ?? "High Accuracy couldn’t finish. Tap Try High Accuracy again."
		}
	}
}
