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
        let first = try XCTUnwrap(store.issue(.start, clientDocumentID: "messages"))
        let second = try XCTUnwrap(store.issue(.start, clientDocumentID: "notes"))

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.clientDocumentID, "messages")
        XCTAssertEqual(second.clientDocumentID, "notes")
        XCTAssertEqual(store.latestRequest, second)
    }

    func testBackgroundHostCannotClaimItsCurrentTranscript() {
        let request = DictationRequest(
            command: .start,
            id: "request-1",
            clientDocumentID: "messages"
        )

        XCTAssertNil(
            KeyboardTranscriptDeliveryRules.recoverableRequestID(
                currentRequestID: request.id,
                currentRequestClientDocumentID: request.clientDocumentID,
                latestRequest: request,
                activeClientDocumentID: "messages",
                hostIsForegroundActive: false
            )
        )
    }

    func testForegroundHostCanClaimItsCurrentTranscript() {
        let request = DictationRequest(
            command: .start,
            id: "request-1",
            clientDocumentID: "messages"
        )

        XCTAssertEqual(
            KeyboardTranscriptDeliveryRules.recoverableRequestID(
                currentRequestID: request.id,
                currentRequestClientDocumentID: request.clientDocumentID,
                latestRequest: request,
                activeClientDocumentID: "messages",
                hostIsForegroundActive: true
            ),
            request.id
        )
    }

    func testRecreatedKeyboardOnlyRecoversItsOwnHostRequest() {
        let request = DictationRequest(
            command: .start,
            id: "request-1",
            clientDocumentID: "messages"
        )

        XCTAssertEqual(
            KeyboardTranscriptDeliveryRules.recoverableRequestID(
                currentRequestID: nil,
                currentRequestClientDocumentID: nil,
                latestRequest: request,
                activeClientDocumentID: "messages",
                hostIsForegroundActive: true
            ),
            request.id
        )
        XCTAssertNil(
            KeyboardTranscriptDeliveryRules.recoverableRequestID(
                currentRequestID: nil,
                currentRequestClientDocumentID: nil,
                latestRequest: request,
                activeClientDocumentID: "notes",
                hostIsForegroundActive: true
            )
        )
        XCTAssertTrue(
            KeyboardTranscriptDeliveryRules.ownsLatestRequest(
                request,
                activeClientDocumentID: "messages"
            )
        )
        XCTAssertFalse(
            KeyboardTranscriptDeliveryRules.ownsLatestRequest(
                request,
                activeClientDocumentID: "notes"
            )
        )
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
}
