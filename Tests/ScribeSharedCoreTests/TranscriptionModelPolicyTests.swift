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

    func testHighAccuracyDownloadsRetryButCancellationDoesNot() {
        XCTAssertEqual(ScribeModelDownloadPolicy.maximumAttempts, 4)
        XCTAssertTrue(
            ScribeModelDownloadPolicy.isRetryable(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            )
        )
        XCTAssertFalse(
            ScribeModelDownloadPolicy.isRetryable(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            )
        )
    }

    func testHighAccuracyManifestPinsLargeComponentWeights() {
        XCTAssertEqual(
            ScribeModelPolicy.primary.componentRequirements,
            [
                .init(name: "MelSpectrogram", expectedWeightBytes: 373_376),
                .init(name: "AudioEncoder", expectedWeightBytes: 421_968_768),
                .init(name: "TextDecoder", expectedWeightBytes: 203_199_860),
            ]
        )
        XCTAssertTrue(
            ScribeModelPolicy.fallback.componentRequirements.allSatisfy {
                $0.expectedWeightBytes == nil
            }
        )
    }

    func testDownloadFailureMessagesExplainRecovery() {
        let networkMessage = ScribeModelDownloadPolicy.installationFailureMessage(
            for: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        )
        XCTAssertTrue(networkMessage.contains("download will resume"))

        let storageMessage = ScribeModelDownloadPolicy.installationFailureMessage(
            for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        )
        XCTAssertTrue(storageMessage.contains("1.5 GB"))
    }
}
