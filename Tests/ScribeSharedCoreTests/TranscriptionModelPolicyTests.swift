import XCTest
@testable import ScribeSharedCore

final class TranscriptionModelPolicyTests: XCTestCase {
    /// `large-v3-v20240930` is the *turbo* release: 4 decoder layers instead
    /// of 32. Decoding is where transcription accuracy lives, so Scribe runs
    /// the full decoder. There is exactly one model — the Base "compatibility"
    /// fallback was removed after it kept silently replacing the real model
    /// whenever a background load hiccuped.
    func testTheOnlyModelIsFullDecoderLargeV3() {
        XCTAssertEqual(ScribeModelPolicy.downloadVariant, "large-v3_947MB")
        XCTAssertFalse(ScribeModelPolicy.folderName.contains("v20240930"))
        XCTAssertFalse(ScribeModelPolicy.folderName.contains("turbo"))
        XCTAssertTrue(ScribeModelPolicy.folderName.contains("large-v3"))
    }

    // MARK: - Cache survival contract
    //
    // The installed model lives in Documents, which iOS preserves across app
    // updates. Whether an update *reuses* it comes down to these exact
    // strings: change any of them and every device re-downloads ~945 MB.
    // These tests exist to make that an explicit decision, not an accident.

    func testCacheFolderNameIsStable() {
        XCTAssertEqual(ScribeModelPolicy.folderName, "openai_whisper-large-v3_947MB")
    }

    func testCacheMarkerNamesAreStable() {
        XCTAssertEqual(ScribeModelPolicy.downloadedMarkerName, ".scribe-download-complete-v2")
        XCTAssertEqual(ScribeModelPolicy.readyMarkerName, ".scribe-ready-v2")
    }

    func testRepositoryIsStable() {
        XCTAssertEqual(ScribeModelPolicy.repository, "argmaxinc/whisperkit-coreml")
    }

    /// The retired tiers may be deleted; the live folder must never appear in
    /// the deletion list.
    func testObsoleteFolderListNeverContainsTheLiveModel() {
        XCTAssertFalse(
            ScribeModelPolicy.obsoleteModelFolderNames.contains(ScribeModelPolicy.folderName)
        )
        XCTAssertTrue(
            ScribeModelPolicy.obsoleteModelFolderNames.contains("openai_whisper-base"),
            "the compatibility tier's cache should be reclaimed"
        )
    }

    // MARK: - Component validation

    /// Weights are floor-checked, not equality-checked. An upstream re-publish
    /// that shifts a file by a few bytes must not brand a good cache invalid
    /// and force a re-download.
    func testComponentWeightsAreValidatedAgainstLowerBounds() {
        let requirements = ScribeModelPolicy.componentRequirements
        XCTAssertEqual(requirements.map(\.name), [
            "MelSpectrogram", "AudioEncoder", "TextDecoder",
        ])
        XCTAssertTrue(requirements.allSatisfy { ($0.minimumWeightBytes ?? 0) > 0 })

        // Floors sit below the real published sizes but far above a truncated
        // download. Real: AudioEncoder 353,908,416 / TextDecoder 590,719,924.
        let encoder = requirements.first { $0.name == "AudioEncoder" }
        XCTAssertNotNil(encoder?.minimumWeightBytes)
        XCTAssertLessThan(encoder!.minimumWeightBytes!, 353_908_416)
        XCTAssertGreaterThan(encoder!.minimumWeightBytes!, 250_000_000)

        let decoder = requirements.first { $0.name == "TextDecoder" }
        XCTAssertNotNil(decoder?.minimumWeightBytes)
        XCTAssertLessThan(decoder!.minimumWeightBytes!, 590_719_924)
        XCTAssertGreaterThan(decoder!.minimumWeightBytes!, 400_000_000)
    }

    // MARK: - Downloads

    func testDownloadsRetryButCancellationDoesNot() {
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

    func testStorageRequirementCoversTheDownloadWithHeadroom() {
        XCTAssertGreaterThan(ScribeModelDownloadPolicy.minimumCapacity, 945_001_716)
    }

    func testDownloadFailureMessagesExplainRecovery() {
        let networkMessage = ScribeModelDownloadPolicy.installationFailureMessage(
            for: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        )
        XCTAssertTrue(networkMessage.contains("resume"))

        let storageMessage = ScribeModelDownloadPolicy.installationFailureMessage(
            for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        )
        XCTAssertTrue(storageMessage.contains("1.9 GB"))
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
