import Foundation

enum DictationPhase: String {
    case idle
    case launching
    case preparing
    case recording
    case transcribing
    case completed
    case failed
}

enum DictationCommand: String {
    case none
    case start
    case stop
    case cancel
    case retry
}

/// The intentionally small IPC surface shared by the containing app and keyboard.
/// Keyboard extensions cannot record audio, so the app performs the work and the
/// extension only sends commands and consumes the final text.
struct SharedDictationStore {
    static let appGroupIdentifier = "group.sohail.Scribe"

    private enum Key {
        static let phase = "dictation.phase"
        static let command = "dictation.command"
        static let transcript = "dictation.transcript"
        static let resultID = "dictation.resultID"
        static let message = "dictation.message"
        static let audioLevel = "dictation.audioLevel"
        static let retryAvailable = "dictation.retryAvailable"
        static let updatedAt = "dictation.updatedAt"
        static let sessionActive = "dictation.sessionActive"
        static let sessionHeartbeat = "dictation.sessionHeartbeat"
        static let sessionExpiresAt = "dictation.sessionExpiresAt"
    }

    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: Self.appGroupIdentifier) ?? .standard
    }

    var phase: DictationPhase {
        get { DictationPhase(rawValue: defaults.string(forKey: Key.phase) ?? "") ?? .idle }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Key.phase)
            touch()
        }
    }

    var message: String {
        get { defaults.string(forKey: Key.message) ?? "" }
        nonmutating set {
            defaults.set(newValue, forKey: Key.message)
            touch()
        }
    }

    var audioLevel: Double {
        get { defaults.double(forKey: Key.audioLevel) }
        nonmutating set { defaults.set(max(0, min(newValue, 1)), forKey: Key.audioLevel) }
    }

    var resultID: String {
        defaults.string(forKey: Key.resultID) ?? ""
    }

    var retryAvailable: Bool {
        get { defaults.bool(forKey: Key.retryAvailable) }
        nonmutating set {
            defaults.set(newValue, forKey: Key.retryAvailable)
            touch()
        }
    }

    var updatedAt: Date {
        defaults.object(forKey: Key.updatedAt) as? Date ?? .distantPast
    }

    // MARK: - Flow session

    /// While a flow session is active the app keeps the microphone alive in
    /// the background, so the keyboard can start dictation with a command
    /// instead of opening the app. Written only by the app.

    var sessionActive: Bool {
        get { defaults.bool(forKey: Key.sessionActive) }
        nonmutating set { defaults.set(newValue, forKey: Key.sessionActive) }
    }

    var sessionHeartbeat: Date {
        get { defaults.object(forKey: Key.sessionHeartbeat) as? Date ?? .distantPast }
        nonmutating set { defaults.set(newValue, forKey: Key.sessionHeartbeat) }
    }

    var sessionExpiresAt: Date {
        get { defaults.object(forKey: Key.sessionExpiresAt) as? Date ?? .distantPast }
        nonmutating set { defaults.set(newValue, forKey: Key.sessionExpiresAt) }
    }

    /// True when the app's session heartbeat is fresh enough for the keyboard
    /// to trust that a start command will be picked up promptly.
    var isSessionAlive: Bool {
        sessionActive
            && Date() < sessionExpiresAt
            && Date().timeIntervalSince(sessionHeartbeat) < 5
    }

    func endSession() {
        defaults.set(false, forKey: Key.sessionActive)
    }

    func issue(_ command: DictationCommand) {
        defaults.set(command.rawValue, forKey: Key.command)
        touch()
    }

    func consumeCommand() -> DictationCommand {
        let command = DictationCommand(rawValue: defaults.string(forKey: Key.command) ?? "") ?? .none
        defaults.set(DictationCommand.none.rawValue, forKey: Key.command)
        return command
    }

    func publish(transcript: String) {
        defaults.set(transcript, forKey: Key.transcript)
        defaults.set(UUID().uuidString, forKey: Key.resultID)
        defaults.set(DictationPhase.completed.rawValue, forKey: Key.phase)
        defaults.set("Ready to insert", forKey: Key.message)
        defaults.set(false, forKey: Key.retryAvailable)
        touch()
    }

    func consumeTranscript() -> String? {
        guard let text = defaults.string(forKey: Key.transcript), !text.isEmpty else { return nil }
        defaults.removeObject(forKey: Key.transcript)
        defaults.set(DictationPhase.idle.rawValue, forKey: Key.phase)
        defaults.set("", forKey: Key.message)
        touch()
        return text
    }

    func fail(_ errorMessage: String, retryAvailable: Bool = false) {
        defaults.set(errorMessage, forKey: Key.message)
        defaults.set(DictationPhase.failed.rawValue, forKey: Key.phase)
        defaults.set(retryAvailable, forKey: Key.retryAvailable)
        touch()
    }

    func reset() {
        defaults.set(DictationPhase.idle.rawValue, forKey: Key.phase)
        defaults.set(DictationCommand.none.rawValue, forKey: Key.command)
        defaults.set("", forKey: Key.message)
        defaults.set(0, forKey: Key.audioLevel)
        defaults.set(false, forKey: Key.retryAvailable)
        touch()
    }

    private func touch() {
        defaults.set(Date(), forKey: Key.updatedAt)
    }
}
