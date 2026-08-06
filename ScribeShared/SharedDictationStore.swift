import Foundation

enum DictationPhase: String, Codable, Sendable {
    case idle
    case launching
    case preparing
    case recording
    case transcribing
    case completed
    case failed
}

enum DictationCommand: String, Codable, Sendable {
    case start
    case stop
    case cancel
    case retry
}

struct DictationRequest: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let command: DictationCommand
    let issuedAt: Date
    /// The host document that opened Scribe. This keeps a keyboard instance in
    /// another app from observing or consuming a result it did not request.
    let clientDocumentID: String?

    init(
        command: DictationCommand,
        id: String = UUID().uuidString,
        issuedAt: Date = Date(),
        clientDocumentID: String? = nil
    ) {
        self.id = id
        self.command = command
        self.issuedAt = issuedAt
        self.clientDocumentID = clientDocumentID
    }

    func isFresh(at date: Date = Date(), maximumAge: TimeInterval = 5 * 60) -> Bool {
        let age = date.timeIntervalSince(issuedAt)
        return age >= -60 && age <= maximumAge
    }
}

/// Pure delivery rules shared with tests. Results are only eligible while the
/// originating host is accepting input; otherwise `insertText` can be ignored
/// while the globally shared result is still marked consumed.
enum KeyboardTranscriptDeliveryRules {
    static func recoverableRequestID(
        currentRequestID: String?,
        currentRequestClientDocumentID: String?,
        latestRequest: DictationRequest?,
        activeClientDocumentID: String?,
        hostIsForegroundActive: Bool
    ) -> String? {
        guard hostIsForegroundActive, let activeClientDocumentID else { return nil }

        if let currentRequestID,
           currentRequestClientDocumentID == activeClientDocumentID {
            return currentRequestID
        }

        guard latestRequest?.clientDocumentID == activeClientDocumentID else { return nil }
        return latestRequest?.id
    }

    static func ownsLatestRequest(
        _ latestRequest: DictationRequest?,
        activeClientDocumentID: String?
    ) -> Bool {
        guard let activeClientDocumentID else { return false }
        return latestRequest?.clientDocumentID == activeClientDocumentID
    }
}

struct DictationStatus: Codable, Equatable, Sendable {
    var requestID: String?
    var processID: String?
    var revision: Int
    var phase: DictationPhase
    var message: String
    var retryAvailable: Bool
    var updatedAt: Date
    var resultID: String?
    var transcript: String?

    static let idle = DictationStatus(
        requestID: nil,
        processID: nil,
        revision: 0,
        phase: .idle,
        message: "",
        retryAvailable: false,
        updatedAt: .distantPast,
        resultID: nil,
        transcript: nil
    )

    var isInFlight: Bool {
        switch phase {
        case .launching, .preparing, .recording, .transcribing:
            true
        case .idle, .completed, .failed:
            false
        }
    }
}

struct DictationSession: Codable, Equatable, Sendable {
    var processID: String?
    var isActive: Bool
    var heartbeat: Date
    var expiresAt: Date

    static let inactive = DictationSession(
        processID: nil,
        isActive: false,
        heartbeat: .distantPast,
        expiresAt: .distantPast
    )

    func isAlive(at date: Date = Date(), heartbeatTolerance: TimeInterval = 6) -> Bool {
        isActive
            && date < expiresAt
            && date.timeIntervalSince(heartbeat) < heartbeatTolerance
    }
}

struct ClaimedTranscript: Equatable, Sendable {
    let resultID: String
    let text: String
}

struct DictationRequestGate: Equatable, Sendable {
    private(set) var lastClaimedRequestID: String?

    init(lastClaimedRequestID: String? = nil) {
        self.lastClaimedRequestID = lastClaimedRequestID
    }

    init(latestRequest: DictationRequest?, status: DictationStatus) {
        lastClaimedRequestID = status.requestID == latestRequest?.id
            ? latestRequest?.id
            : nil
    }

    mutating func claim(_ request: DictationRequest) -> Bool {
        guard request.id != lastClaimedRequestID else { return false }
        lastClaimedRequestID = request.id
        return true
    }
}

/// The intentionally small IPC surface shared by the containing app and keyboard.
///
/// Requests, app-owned status, and session state are each encoded as one value so
/// readers never observe half of a transition. Every request has a unique ID and
/// every status acknowledges the request it belongs to, making duplicate URL,
/// scene, and polling delivery harmless.
struct SharedDictationStore: @unchecked Sendable {
    static let appGroupIdentifier = "group.sohail.Scribe"

    private enum Key {
        static let request = "dictation.v2.request"
        static let status = "dictation.v2.status"
        static let session = "dictation.v2.session"
        static let audioLevel = "dictation.v2.audioLevel"
        static let consumedResultID = "dictation.v2.consumedResultID"
        static let handledRequestID = "dictation.v2.handledRequestID"
    }

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: SharedDictationStore.appGroupIdentifier)) {
        self.defaults = defaults
    }

    var isAvailable: Bool { defaults != nil }

    var latestRequest: DictationRequest? {
        read(DictationRequest.self, forKey: Key.request)
    }

    var status: DictationStatus {
        read(DictationStatus.self, forKey: Key.status) ?? .idle
    }

    var session: DictationSession {
        read(DictationSession.self, forKey: Key.session) ?? .inactive
    }

    var audioLevel: Double {
        get { defaults?.double(forKey: Key.audioLevel) ?? 0 }
        nonmutating set { defaults?.set(max(0, min(newValue, 1)), forKey: Key.audioLevel) }
    }

    var lastHandledRequestID: String? {
        defaults?.string(forKey: Key.handledRequestID)
    }

    @discardableResult
    func issue(
        _ command: DictationCommand,
        clientDocumentID: String? = nil,
        at date: Date = Date()
    ) -> DictationRequest? {
        guard defaults != nil else { return nil }
        let request = DictationRequest(
            command: command,
            issuedAt: date,
            clientDocumentID: clientDocumentID
        )
        write(request, forKey: Key.request)
        return request
    }

    func markRequestHandled(_ requestID: String) {
        defaults?.set(requestID, forKey: Key.handledRequestID)
    }

    func publishStatus(
        for requestID: String?,
        processID: String,
        phase: DictationPhase,
        message: String,
        retryAvailable: Bool = false,
        at date: Date = Date()
    ) {
        guard defaults != nil else { return }
        let previous = status
        let keepResult = previous.requestID == requestID && phase == .completed
        let next = DictationStatus(
            requestID: requestID,
            processID: processID,
            revision: previous.revision + 1,
            phase: phase,
            message: message,
            retryAvailable: retryAvailable,
            updatedAt: date,
            resultID: keepResult ? previous.resultID : nil,
            transcript: keepResult ? previous.transcript : nil
        )
        write(next, forKey: Key.status)
    }

    func publish(
        transcript: String,
        for requestID: String?,
        processID: String,
        at date: Date = Date()
    ) {
        guard defaults != nil else { return }
        let next = DictationStatus(
            requestID: requestID,
            processID: processID,
            revision: status.revision + 1,
            phase: .completed,
            message: "Ready to insert",
            retryAvailable: false,
            updatedAt: date,
            resultID: UUID().uuidString,
            transcript: transcript
        )
        write(next, forKey: Key.status)
    }

    func fail(
        _ errorMessage: String,
        for requestID: String?,
        processID: String,
        retryAvailable: Bool = false,
        at date: Date = Date()
    ) {
        publishStatus(
            for: requestID,
            processID: processID,
            phase: .failed,
            message: errorMessage,
            retryAvailable: retryAvailable,
            at: date
        )
    }

    func reset(for requestID: String?, processID: String, at date: Date = Date()) {
        publishStatus(
            for: requestID,
            processID: processID,
            phase: .idle,
            message: "",
            at: date
        )
        defaults?.set(0, forKey: Key.audioLevel)
    }

    /// Claims a result before insertion so extension recreation cannot paste it twice.
    /// The request/status remains available for diagnostics; only the result ID is acked.
    func claimTranscript(
        for requestID: String?,
        at date: Date = Date(),
        maximumAge: TimeInterval = 15 * 60
    ) -> ClaimedTranscript? {
        let current = status
        let age = date.timeIntervalSince(current.updatedAt)
        guard let requestID,
              current.requestID == requestID,
              current.phase == .completed,
              age >= -60,
              age <= maximumAge,
              let resultID = current.resultID,
              let transcript = current.transcript,
              !transcript.isEmpty,
              defaults?.string(forKey: Key.consumedResultID) != resultID else {
            return nil
        }
        defaults?.set(resultID, forKey: Key.consumedResultID)
        return ClaimedTranscript(resultID: resultID, text: transcript)
    }

    func isResultConsumed(_ resultID: String?) -> Bool {
        guard let resultID else { return false }
        return defaults?.string(forKey: Key.consumedResultID) == resultID
    }

    func beginSession(processID: String, expiresAt: Date, at date: Date = Date()) {
        write(
            DictationSession(
                processID: processID,
                isActive: true,
                heartbeat: date,
                expiresAt: expiresAt
            ),
            forKey: Key.session
        )
    }

    func refreshSessionHeartbeat(processID: String, at date: Date = Date()) {
        var current = session
        guard current.isActive, current.processID == processID else { return }
        current.heartbeat = date
        write(current, forKey: Key.session)
    }

    func extendSession(processID: String, expiresAt: Date, at date: Date = Date()) {
        var current = session
        guard current.processID == processID else {
            beginSession(processID: processID, expiresAt: expiresAt, at: date)
            return
        }
        current.isActive = true
        current.heartbeat = date
        current.expiresAt = expiresAt
        write(current, forKey: Key.session)
    }

    func endSession(processID: String? = nil) {
        var current = session
        if let processID, current.processID != processID { return }
        current.isActive = false
        current.heartbeat = .distantPast
        current.expiresAt = .distantPast
        write(current, forKey: Key.session)
    }

    private func read<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults?.set(data, forKey: key)
    }
}
