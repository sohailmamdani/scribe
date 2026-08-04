import XCTest
@testable import ScribeSharedCore

final class TranscriptionModelPolicyTests: XCTestCase {
    func testHighAccuracyIsTheDefault() {
        XCTAssertEqual(ScribeModelPolicy.primary, .highAccuracy)
        XCTAssertEqual(ScribeModelPolicy.primary.downloadVariant, "large-v3-v20240930_626MB")
        XCTAssertEqual(
            ScribeModelPolicy.primary.folderName,
            "openai_whisper-large-v3-v20240930_626MB"
        )
        XCTAssertFalse(ScribeModelPolicy.primary.usesCPUOnly)
    }

    func testCompatibilityUsesBaseAndCPUOnly() {
        XCTAssertEqual(ScribeModelPolicy.fallback, .compatibility)
        XCTAssertEqual(ScribeModelPolicy.fallback.downloadVariant, "base")
        XCTAssertEqual(ScribeModelPolicy.fallback.folderName, "openai_whisper-base")
        XCTAssertTrue(ScribeModelPolicy.fallback.usesCPUOnly)
    }

    func testOnlyCurrentVersionedCompatibilityPreferenceIsHonored() {
        let current = ScribeModelPolicy.compatibilitySignature(osMajorVersion: 26)
        XCTAssertEqual(
            ScribeModelPolicy.preferredProfile(
                storedCompatibilitySignature: current,
                osMajorVersion: 26
            ),
            .compatibility
        )
        XCTAssertEqual(
            ScribeModelPolicy.preferredProfile(
                storedCompatibilitySignature: "legacy-boolean-or-old-policy",
                osMajorVersion: 26
            ),
            .highAccuracy
        )
        XCTAssertEqual(
            ScribeModelPolicy.preferredProfile(
                storedCompatibilitySignature: current,
                osMajorVersion: 27
            ),
            .highAccuracy
        )
    }
}
