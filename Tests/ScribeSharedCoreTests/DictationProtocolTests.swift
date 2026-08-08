import Foundation
import XCTest
@testable import ScribeSharedCore

final class DictationProtocolTests: XCTestCase {
    private let suiteName = "DictationProtocolTests"
    private var defaults: UserDefaults!
    private var store: SharedDictationStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = SharedDictationStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testEveryRequestHasAUniqueIdentity() throws {
        let first = try XCTUnwrap(store.issue(.start))
        let second = try XCTUnwrap(store.issue(.start))

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(store.latestRequest, second)
    }

    func testRequestGateMakesDuplicateDeliveryIdempotent() {
        let request = DictationRequest(command: .start, id: "request-1")
        var gate = DictationRequestGate()

        XCTAssertTrue(gate.claim(request))
        XCTAssertFalse(gate.claim(request))
        XCTAssertTrue(gate.claim(DictationRequest(command: .stop, id: "request-2")))
    }

    func testRequestGateOnlyRestoresAnAtomicallyAcknowledgedRequest() {
        let request = DictationRequest(command: .start)

        var unacknowledged = DictationRequestGate(
            latestRequest: request,
            status: .idle
        )
        XCTAssertTrue(unacknowledged.claim(request))

        var status = DictationStatus.idle
        status.requestID = request.id
        var acknowledged = DictationRequestGate(
            latestRequest: request,
            status: status
        )
        XCTAssertFalse(acknowledged.claim(request))
    }

    func testStatusAcknowledgesTheRequestAsOneSnapshot() {
        store.publishStatus(
            for: "request-1",
            processID: "process-1",
            phase: .preparing,
            message: "Preparing"
        )

        XCTAssertEqual(
            store.status,
            DictationStatus(
                requestID: "request-1",
                processID: "process-1",
                revision: 1,
                phase: .preparing,
                message: "Preparing",
                retryAvailable: false,
                updatedAt: store.status.updatedAt,
                resultID: nil,
                transcript: nil
            )
        )
    }

    func testPendingRecordingKeepsItsPersistedDeliveryRequest() {
        var status = DictationStatus.idle
        status.requestID = "newer-shared-status"
        status.phase = .failed
        status.retryAvailable = true

        XCTAssertEqual(
            PendingRecordingDelivery.requestID(
                persistedRequestID: "recording-request",
                sharedStatus: status
            ),
            "recording-request"
        )
    }

    func testBuild30PendingRecordingRecoversRequestFromRetryableFailure() {
        var status = DictationStatus.idle
        status.requestID = "build-30-stop-request"
        status.phase = .failed
        status.retryAvailable = true

        XCTAssertEqual(
            PendingRecordingDelivery.requestID(
                persistedRequestID: nil,
                sharedStatus: status
            ),
            "build-30-stop-request"
        )
    }

    func testPendingRecordingDoesNotAdoptUnrelatedSharedStatus() {
        for phase in [DictationPhase.idle, .preparing, .recording, .transcribing, .completed] {
            var status = DictationStatus.idle
            status.requestID = "unrelated-request"
            status.phase = phase
            status.retryAvailable = true

            XCTAssertNil(
                PendingRecordingDelivery.requestID(
                    persistedRequestID: nil,
                    sharedStatus: status
                )
            )
        }

        var nonRetryableFailure = DictationStatus.idle
        nonRetryableFailure.requestID = "unrelated-failure"
        nonRetryableFailure.phase = .failed
        nonRetryableFailure.retryAvailable = false
        XCTAssertNil(
            PendingRecordingDelivery.requestID(
                persistedRequestID: nil,
                sharedStatus: nonRetryableFailure
            )
        )
    }

    func testTranscriptCanOnlyBeClaimedOnce() {
        store.publish(transcript: "Hello", for: "request-1", processID: "process-1")

        XCTAssertEqual(store.claimTranscript(for: "request-1")?.text, "Hello")
        XCTAssertNil(store.claimTranscript(for: "request-1"))
    }

    func testTranscriptMustMatchTheActiveRequest() {
        store.publish(transcript: "Old text", for: "request-1", processID: "process-1")

        XCTAssertNil(store.claimTranscript(for: "request-2"))
        XCTAssertEqual(store.claimTranscript(for: "request-1")?.text, "Old text")
    }

    func testAppOnlyAndExpiredTranscriptsAreNotClaimed() {
        let now = Date(timeIntervalSince1970: 2_000)
        store.publish(
            transcript: "App-only text",
            for: nil,
            processID: "process-1",
            at: now
        )
        XCTAssertNil(store.claimTranscript(for: nil, at: now))

        store.publish(
            transcript: "Expired text",
            for: "request-1",
            processID: "process-1",
            at: now
        )
        XCTAssertNil(
            store.claimTranscript(
                for: "request-1",
                at: now.addingTimeInterval(16 * 60)
            )
        )
    }

    func testHandledRequestIdentitySurvivesStatusReset() throws {
        let request = try XCTUnwrap(store.issue(.cancel))
        store.markRequestHandled(request.id)
        store.reset(for: request.id, processID: "process-1")

        XCTAssertEqual(store.lastHandledRequestID, request.id)
        XCTAssertEqual(store.status.requestID, request.id)

        var relaunchedGate = DictationRequestGate(lastClaimedRequestID: store.lastHandledRequestID)
        XCTAssertFalse(relaunchedGate.claim(request))
    }

    func testRequestsExpireAndAllowSmallClockSkew() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            DictationRequest(command: .start, issuedAt: now.addingTimeInterval(-299)).isFresh(at: now)
        )
        XCTAssertFalse(
            DictationRequest(command: .start, issuedAt: now.addingTimeInterval(-301)).isFresh(at: now)
        )
        XCTAssertTrue(
            DictationRequest(command: .start, issuedAt: now.addingTimeInterval(30)).isFresh(at: now)
        )
    }

    func testSessionRequiresFreshHeartbeatAndUnexpiredWindow() {
        let now = Date(timeIntervalSince1970: 100)
        store.beginSession(
            processID: "process-1",
            expiresAt: now.addingTimeInterval(60),
            at: now
        )

        XCTAssertTrue(store.session.isAlive(at: now.addingTimeInterval(5)))
        XCTAssertFalse(store.session.isAlive(at: now.addingTimeInterval(7)))

        store.refreshSessionHeartbeat(processID: "process-1", at: now.addingTimeInterval(15))
        XCTAssertTrue(store.session.isAlive(at: now.addingTimeInterval(20)))
        XCTAssertFalse(store.session.isAlive(at: now.addingTimeInterval(61)))
    }

    // MARK: - Transcript delivery rules
    //
    // Claiming marks a result consumed for every process in the App Group, and
    // an insert into a backgrounded or foreign proxy is silently dropped — so
    // a wrong claim destroys the transcript. These rules decide who may claim.

    private func request(
        _ command: DictationCommand = .stop,
        id: String = "req-1",
        document: String?
    ) -> DictationRequest {
        DictationRequest(command: command, id: id, clientDocumentID: document)
    }

    func testOwnRequestIsClaimableWhileHostIsActive() {
        XCTAssertEqual(
            KeyboardTranscriptDelivery.autoClaimRequestID(
                currentRequestID: "req-1",
                latestRequest: request(document: "doc-A"),
                activeDocumentID: "doc-A",
                hostIsActive: true
            ),
            "req-1"
        )
    }

    /// The core loss scenario: a keyboard instance whose host is backgrounded
    /// polls, claims, inserts into a dead proxy, and the text is gone. No
    /// background instance may claim anything — not even its own request.
    func testBackgroundHostMayClaimNothing() {
        XCTAssertNil(
            KeyboardTranscriptDelivery.autoClaimRequestID(
                currentRequestID: "req-1",
                latestRequest: request(id: "req-1", document: "doc-A"),
                activeDocumentID: "doc-A",
                hostIsActive: false
            )
        )
    }

    /// Recreation recovery: iOS killed the keyboard mid-dictation, a fresh
    /// instance appears over the same document, and may pick up the result.
    func testRecreatedKeyboardOverTheSameDocumentRecovers() {
        XCTAssertEqual(
            KeyboardTranscriptDelivery.autoClaimRequestID(
                currentRequestID: nil,
                latestRequest: request(id: "req-9", document: "doc-A"),
                activeDocumentID: "doc-A",
                hostIsActive: true
            ),
            "req-9"
        )
    }

    /// The Messages bug: a keyboard in a different app (different document)
    /// must not consume a result it cannot deliver.
    func testKeyboardOverADifferentDocumentMayNotClaim() {
        XCTAssertNil(
            KeyboardTranscriptDelivery.autoClaimRequestID(
                currentRequestID: nil,
                latestRequest: request(document: "doc-A"),
                activeDocumentID: "doc-B",
                hostIsActive: true
            )
        )
    }

    /// Requests from older builds carry no document. They get no automatic
    /// fallback claim — the manual affordance handles them instead.
    func testUntaggedRequestsAreNotClaimableByFallback() {
        XCTAssertNil(
            KeyboardTranscriptDelivery.autoClaimRequestID(
                currentRequestID: nil,
                latestRequest: request(document: nil),
                activeDocumentID: "doc-A",
                hostIsActive: true
            )
        )
        XCTAssertNil(
            KeyboardTranscriptDelivery.autoClaimRequestID(
                currentRequestID: nil,
                latestRequest: request(document: "doc-A"),
                activeDocumentID: nil,
                hostIsActive: true
            )
        )
    }

    private func completedStatus(
        requestID: String = "req-9",
        transcript: String? = "hello there",
        updatedAt: Date = Date()
    ) -> DictationStatus {
        DictationStatus(
            requestID: requestID,
            processID: "app",
            revision: 3,
            phase: .completed,
            message: "",
            retryAvailable: false,
            updatedAt: updatedAt,
            resultID: "result-1",
            transcript: transcript
        )
    }

    /// When the document changed across an app switch, the transcript is
    /// offered for an explicit tap instead of being silently lost.
    func testUnclaimableFinishedResultIsOfferedForManualInsertion() {
        XCTAssertTrue(
            KeyboardTranscriptDelivery.hasRecoverableResult(
                status: completedStatus(),
                isConsumed: false,
                currentRequestID: nil,
                autoClaimRequestID: nil,
                hostIsActive: true
            )
        )
    }

    func testManualInsertionIsNotOfferedWhenAutoClaimHandlesIt() {
        XCTAssertFalse(
            KeyboardTranscriptDelivery.hasRecoverableResult(
                status: completedStatus(requestID: "req-9"),
                isConsumed: false,
                currentRequestID: nil,
                autoClaimRequestID: "req-9",
                hostIsActive: true
            )
        )
    }

    func testManualInsertionIsNotOfferedForConsumedStaleOrBusyStates() {
        XCTAssertFalse(
            KeyboardTranscriptDelivery.hasRecoverableResult(
                status: completedStatus(),
                isConsumed: true,
                currentRequestID: nil,
                autoClaimRequestID: nil,
                hostIsActive: true
            ),
            "consumed results are done"
        )
        XCTAssertFalse(
            KeyboardTranscriptDelivery.hasRecoverableResult(
                status: completedStatus(),
                isConsumed: false,
                currentRequestID: "req-new",
                autoClaimRequestID: "req-new",
                hostIsActive: true
            ),
            "a keyboard mid-request should not advertise an older result"
        )
        XCTAssertFalse(
            KeyboardTranscriptDelivery.hasRecoverableResult(
                status: completedStatus(updatedAt: Date().addingTimeInterval(-16 * 60)),
                isConsumed: false,
                currentRequestID: nil,
                autoClaimRequestID: nil,
                hostIsActive: true
            ),
            "a 16-minute-old transcript should not chase the user around"
        )
        XCTAssertFalse(
            KeyboardTranscriptDelivery.hasRecoverableResult(
                status: completedStatus(),
                isConsumed: false,
                currentRequestID: nil,
                autoClaimRequestID: nil,
                hostIsActive: false
            ),
            "background keyboards cannot insert, so they must not offer to"
        )
    }

    // MARK: - Stall timeouts

    /// The old rule skipped timeouts whenever the session heartbeat was alive,
    /// so a wedged-but-alive app pinned every keyboard at "Polishing your
    /// words…" forever. A live session may lengthen patience, never remove it.
    func testEveryPhaseTimesOutEvenWithALiveSession() {
        for phase in [DictationPhase.preparing, .transcribing, .recording, .launching] {
            let timeout = KeyboardTranscriptDelivery.inFlightStallTimeout(
                phase: phase,
                sessionAlive: true
            )
            XCTAssertGreaterThan(timeout, 0)
            XCTAssertLessThanOrEqual(
                timeout,
                5 * 60,
                "\(phase) must not wait longer than the app-side watchdog's whole budget"
            )
        }
    }

    func testLiveSessionsGetMorePatienceNotLess() {
        for phase in [DictationPhase.preparing, .transcribing, .recording] {
            XCTAssertGreaterThanOrEqual(
                KeyboardTranscriptDelivery.inFlightStallTimeout(phase: phase, sessionAlive: true),
                KeyboardTranscriptDelivery.inFlightStallTimeout(phase: phase, sessionAlive: false)
            )
        }
    }

    /// Transcribing tolerates the longest stall: the app publishes no interim
    /// status while CoreML runs, and long recordings genuinely take minutes.
    func testTranscribingStallToleranceCoversLongRecordings() {
        XCTAssertGreaterThanOrEqual(
            KeyboardTranscriptDelivery.inFlightStallTimeout(
                phase: .transcribing,
                sessionAlive: true
            ),
            4 * 60
        )
    }

    // MARK: - Request document affinity

    func testRequestsWithoutDocumentIDStillDecode() throws {
        // Simulates a request written by a build that predates the field.
        let legacyJSON = """
        {"id":"old-1","command":"start","issuedAt":700000000}
        """
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(
            DictationRequest.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(decoded.id, "old-1")
        XCTAssertNil(decoded.clientDocumentID)
    }

    func testIssueRecordsTheClientDocument() {
        store.issue(.start, clientDocumentID: "doc-A")
        XCTAssertEqual(store.latestRequest?.clientDocumentID, "doc-A")
    }
}
