import XCTest
@testable import ScribeSharedCore

final class TranscriptionModelPolicyTests: XCTestCase {
    func testHighAccuracyIsTheDefault() {
        XCTAssertEqual(ScribeModelPolicy.primary, .highAccuracy)
        XCTAssertEqual(ScribeModelPolicy.primary.downloadVariant, "large-v3-v20240930")
        XCTAssertEqual(
            ScribeModelPolicy.primary.folderName,
            "openai_whisper-large-v3-v20240930"
        )
        XCTAssertFalse(ScribeModelPolicy.primary.usesCPUOnly)
    }

    /// The quantized `_626MB` build measurably trailed the Mac app. The device
    /// must pull the full-precision weights, not a compressed variant.
    func testHighAccuracyUsesFullPrecisionWeights() {
        XCTAssertFalse(ScribeModelPolicy.primary.downloadVariant.contains("MB"))
        XCTAssertFalse(ScribeModelPolicy.primary.folderName.contains("MB"))
    }

    func testCompatibilityUsesBaseAndCPUOnly() {
        XCTAssertEqual(ScribeModelPolicy.fallback, .compatibility)
        XCTAssertEqual(ScribeModelPolicy.fallback.downloadVariant, "base")
        XCTAssertEqual(ScribeModelPolicy.fallback.folderName, "openai_whisper-base")
        XCTAssertTrue(ScribeModelPolicy.fallback.usesCPUOnly)
    }

    // MARK: - Fallback stickiness

    private func state(
        failures: Int,
        osMajorVersion: Int = 26,
        lastFailureAt: Date? = Date()
    ) -> ScribeModelFallbackState {
        ScribeModelFallbackState(
            signature: ScribeModelPolicy.compatibilitySignature(
                osMajorVersion: osMajorVersion
            ),
            consecutiveFailures: failures,
            lastFailureAt: lastFailureAt
        )
    }

    /// The core regression: one bad download or one memory spike used to
    /// downgrade the device permanently.
    func testSingleFailureDoesNotPersistADowngrade() {
        for failures in 0..<ScribeModelFallbackPolicy.failuresBeforePersisting {
            XCTAssertEqual(
                ScribeModelFallbackPolicy.preferredProfile(
                    fallbackState: state(failures: failures),
                    osMajorVersion: 26
                ),
                .highAccuracy,
                "\(failures) failures should not be enough to persist a downgrade"
            )
        }
    }

    func testRepeatedFailuresPersistTheDowngrade() {
        XCTAssertEqual(
            ScribeModelFallbackPolicy.preferredProfile(
                fallbackState: state(
                    failures: ScribeModelFallbackPolicy.failuresBeforePersisting
                ),
                osMajorVersion: 26
            ),
            .compatibility
        )
    }

    /// Even a persisted downgrade has to lapse: devices recover from low
    /// storage and OS bugs, so the quality model gets re-tested.
    func testPersistedDowngradeLapsesAfterTheRetryInterval() {
        let stale = Date().addingTimeInterval(
            -ScribeModelFallbackPolicy.retryInterval - 60
        )
        XCTAssertEqual(
            ScribeModelFallbackPolicy.preferredProfile(
                fallbackState: state(failures: 9, lastFailureAt: stale),
                osMajorVersion: 26
            ),
            .highAccuracy
        )
    }

    func testDowngradeIsDiscardedOnPolicyOrOSChange() {
        let saturated = state(failures: 9)
        XCTAssertEqual(
            ScribeModelFallbackPolicy.preferredProfile(
                fallbackState: saturated,
                osMajorVersion: 27
            ),
            .highAccuracy
        )
        XCTAssertEqual(
            ScribeModelFallbackPolicy.preferredProfile(
                fallbackState: ScribeModelFallbackState(
                    signature: "legacy-boolean-or-old-policy",
                    consecutiveFailures: 9,
                    lastFailureAt: Date()
                ),
                osMajorVersion: 26
            ),
            .highAccuracy
        )
    }

    func testFailuresAccumulateAndSuccessClearsThem() {
        var current = ScribeModelFallbackState.empty
        for expected in 1...ScribeModelFallbackPolicy.failuresBeforePersisting {
            current = ScribeModelFallbackPolicy.stateAfterFailure(
                current,
                osMajorVersion: 26
            )
            XCTAssertEqual(current.consecutiveFailures, expected)
        }
        XCTAssertEqual(
            ScribeModelFallbackPolicy.preferredProfile(
                fallbackState: current,
                osMajorVersion: 26
            ),
            .compatibility
        )

        XCTAssertEqual(ScribeModelFallbackPolicy.stateAfterSuccess(), .empty)
        XCTAssertEqual(
            ScribeModelFallbackPolicy.preferredProfile(
                fallbackState: .empty,
                osMajorVersion: 26
            ),
            .highAccuracy
        )
    }

    /// A failure counted under a previous OS must not carry over.
    func testFailureCountResetsWhenTheSignatureChanges() {
        let old = ScribeModelFallbackState(
            signature: ScribeModelPolicy.compatibilitySignature(osMajorVersion: 25),
            consecutiveFailures: 7,
            lastFailureAt: Date()
        )
        let updated = ScribeModelFallbackPolicy.stateAfterFailure(
            old,
            osMajorVersion: 26
        )
        XCTAssertEqual(updated.consecutiveFailures, 1)
    }

    // MARK: - Downloads

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

    /// Weights are floor-checked, not equality-checked. An upstream re-publish
    /// that shifts a file by a few bytes must not brand a good cache invalid
    /// and strand the device on Base forever.
    func testHighAccuracyValidatesWeightsAgainstALowerBound() {
        let requirements = ScribeModelPolicy.primary.componentRequirements
        XCTAssertEqual(requirements.map(\.name), [
            "MelSpectrogram", "AudioEncoder", "TextDecoder",
        ])
        XCTAssertTrue(requirements.allSatisfy { ($0.minimumWeightBytes ?? 0) > 0 })

        // Floors must sit below the real full-precision sizes but far above a
        // truncated download.
        let encoder = requirements.first { $0.name == "AudioEncoder" }
        XCTAssertNotNil(encoder?.minimumWeightBytes)
        XCTAssertLessThan(encoder!.minimumWeightBytes!, 1_273_974_400)
        XCTAssertGreaterThan(encoder!.minimumWeightBytes!, 1_000_000_000)

        XCTAssertTrue(
            ScribeModelPolicy.fallback.componentRequirements.allSatisfy {
                $0.minimumWeightBytes == nil
            }
        )
    }

    func testStorageRequirementCoversTheFullPrecisionDownload() {
        XCTAssertGreaterThan(
            ScribeModelDownloadPolicy.minimumHighAccuracyCapacity,
            1_618_281_524
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
        XCTAssertTrue(storageMessage.contains("2.6 GB"))
    }

    // MARK: - Language pinning

    func testLanguagePinningPrefersTheDeviceLanguage() {
        XCTAssertEqual(
            ScribeDictationLanguagePolicy.language(forPreferred: ["en-US"]),
            "en"
        )
        XCTAssertEqual(
            ScribeDictationLanguagePolicy.language(forPreferred: ["pt_BR", "en-US"]),
            "pt"
        )
    }

    /// An unrecognized locale must fall through to Whisper's own detection
    /// rather than forcing a wrong language onto the decoder.
    func testUnsupportedLanguageFallsBackToAutomaticDetection() {
        XCTAssertNil(ScribeDictationLanguagePolicy.language(forPreferred: ["zz-ZZ"]))
        XCTAssertNil(ScribeDictationLanguagePolicy.language(forPreferred: []))
        XCTAssertEqual(
            ScribeDictationLanguagePolicy.language(forPreferred: ["zz-ZZ", "fr-CA"]),
            "fr"
        )
    }
}
