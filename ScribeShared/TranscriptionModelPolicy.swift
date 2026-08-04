import Foundation

enum ScribeModelProfile: String, Equatable, Sendable {
    case highAccuracy
    case compatibility

    var downloadVariant: String {
        switch self {
        case .highAccuracy: "large-v3_947MB"
        case .compatibility: "base"
        }
    }

    var folderName: String {
        switch self {
        case .highAccuracy: "openai_whisper-large-v3_947MB"
        case .compatibility: "openai_whisper-base"
        }
    }

    var displayName: String {
        switch self {
        case .highAccuracy: "Whisper Large-v3"
        case .compatibility: "Whisper Base compatibility"
        }
    }

    var usesCPUOnly: Bool { self == .compatibility }

    /// Component weights are validated against a *lower bound* rather than an
    /// exact size. Truncated downloads — the failure this guards against — fall
    /// far below these floors, while an upstream re-publish that shifts a file
    /// by a few bytes no longer brands a perfectly good cache permanently
    /// invalid and traps the device on Base.
    var componentRequirements: [ScribeModelComponentRequirement] {
        switch self {
        case .compatibility:
            [
                .init(name: "MelSpectrogram"),
                .init(name: "AudioEncoder"),
                .init(name: "TextDecoder"),
            ]
        case .highAccuracy:
            // Actual sizes are 373 KB / 354 MB / 591 MB. Note the encoder is
            // *smaller* than the quantized turbo build it replaces; the growth
            // is entirely in the 32-layer decoder.
            [
                .init(name: "MelSpectrogram", minimumWeightBytes: 300_000),
                .init(name: "AudioEncoder", minimumWeightBytes: 330_000_000),
                .init(name: "TextDecoder", minimumWeightBytes: 550_000_000),
            ]
        }
    }
}

struct ScribeModelComponentRequirement: Equatable, Sendable {
    let name: String
    let minimumWeightBytes: Int64?

    init(name: String, minimumWeightBytes: Int64? = nil) {
        self.name = name
        self.minimumWeightBytes = minimumWeightBytes
    }
}

enum ScribeModelPolicy {
    static let version = 3
    static let repository = "argmaxinc/whisperkit-coreml"
    static let primary: ScribeModelProfile = .highAccuracy
    static let fallback: ScribeModelProfile = .compatibility

    static func compatibilitySignature(osMajorVersion: Int) -> String {
        "v\(version)|\(primary.folderName)|ios\(osMajorVersion)"
    }
}

/// Records how often High Accuracy has failed in a row so a *single* transient
/// fault can never permanently downgrade the device.
struct ScribeModelFallbackState: Equatable, Sendable {
    var signature: String?
    var consecutiveFailures: Int
    var lastFailureAt: Date?

    static let empty = ScribeModelFallbackState(
        signature: nil,
        consecutiveFailures: 0,
        lastFailureAt: nil
    )

    init(signature: String?, consecutiveFailures: Int, lastFailureAt: Date?) {
        self.signature = signature
        self.consecutiveFailures = consecutiveFailures
        self.lastFailureAt = lastFailureAt
    }
}

/// Decides when a device stops trying the High Accuracy model.
///
/// Build 11 persisted a downgrade the first time any error string looked
/// CoreML-shaped, which permanently trapped devices on Base after one
/// interrupted download or one memory spike. Persistence now requires repeated
/// consecutive failures, and even then it lapses so the device re-tests the
/// quality model instead of degrading forever.
enum ScribeModelFallbackPolicy {
    /// Consecutive High Accuracy failures required before Base becomes the
    /// stored preference. Below this, the fallback lasts only for the session.
    static let failuresBeforePersisting = 3

    /// A persisted downgrade is re-tested after this long. Devices recover from
    /// low storage, OS bugs, and memory pressure; the preference should too.
    static let retryInterval: TimeInterval = 7 * 24 * 60 * 60

    static func preferredProfile(
        fallbackState: ScribeModelFallbackState,
        osMajorVersion: Int,
        now: Date = Date()
    ) -> ScribeModelProfile {
        let currentSignature = ScribeModelPolicy.compatibilitySignature(
            osMajorVersion: osMajorVersion
        )
        // A new policy version or an OS upgrade invalidates the old verdict.
        guard fallbackState.signature == currentSignature else { return .highAccuracy }
        guard fallbackState.consecutiveFailures >= failuresBeforePersisting else {
            return .highAccuracy
        }
        guard let lastFailureAt = fallbackState.lastFailureAt else { return .highAccuracy }
        return now.timeIntervalSince(lastFailureAt) >= retryInterval
            ? .highAccuracy
            : .compatibility
    }

    static func stateAfterFailure(
        _ state: ScribeModelFallbackState,
        osMajorVersion: Int,
        now: Date = Date()
    ) -> ScribeModelFallbackState {
        let currentSignature = ScribeModelPolicy.compatibilitySignature(
            osMajorVersion: osMajorVersion
        )
        let previousFailures = state.signature == currentSignature
            ? state.consecutiveFailures
            : 0
        return ScribeModelFallbackState(
            signature: currentSignature,
            consecutiveFailures: previousFailures + 1,
            lastFailureAt: now
        )
    }

    static func stateAfterSuccess() -> ScribeModelFallbackState { .empty }
}

enum ScribeModelDownloadPolicy {
    static let maximumAttempts = 4

    /// The Large-v3 weights total roughly 945 MB. Require headroom for the
    /// download, the tokenizer, and CoreML's compiled cache.
    static let minimumHighAccuracyCapacity: Int64 = 1_900_000_000

    static func retryDelay(afterFailedAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1: 1
        case 2: 3
        default: 7
        }
    }

    static func isRetryable(_ error: NSError) -> Bool {
        let errors = errorChain(startingAt: error)
        if errors.contains(where: { $0.domain == NSURLErrorDomain && $0.code == NSURLErrorCancelled }) {
            return false
        }
        if errors.contains(where: isOutOfSpace) { return false }
        if errors.contains(where: { $0.domain == NSURLErrorDomain }) { return true }
        // WhisperKit may surface an incomplete snapshot as its own error after
        // a transport interruption. Retrying is safe because its .incomplete
        // files are resumed rather than discarded.
        return true
    }

    static func installationFailureMessage(for error: NSError) -> String {
        let errors = errorChain(startingAt: error)
        if errors.contains(where: isOutOfSpace) {
            return "High Accuracy needs about 1.9 GB free. Free some storage, then try again."
        }
        if errors.contains(where: { $0.domain == NSURLErrorDomain }) {
            return "High Accuracy was interrupted. Keep Scribe open on a stable connection, then tap Try High Accuracy again — the download will resume."
        }
        return "High Accuracy couldn’t finish. Tap Try High Accuracy again — Scribe will repair and resume the download."
    }

    private static func errorChain(startingAt error: NSError) -> [NSError] {
        var result: [NSError] = []
        var current: NSError? = error
        var seen = Set<ObjectIdentifier>()
        while let value = current, seen.insert(ObjectIdentifier(value)).inserted {
            result.append(value)
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    nonisolated private static func isOutOfSpace(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError
    }
}

/// Whisper's short-utterance accuracy drops noticeably when it has to infer the
/// language from a two-second clip. Pinning the language when the device locale
/// names one Whisper supports removes that failure mode; anything unrecognized
/// falls back to automatic detection rather than forcing a wrong language.
enum ScribeDictationLanguagePolicy {
    static let supportedLanguageCodes: Set<String> = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca",
        "nl", "ar", "sv", "it", "id", "hi", "fi", "vi", "he", "uk", "el", "ms",
        "cs", "ro", "da", "hu", "ta", "no", "th", "ur", "hr", "bg", "lt", "la",
        "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr", "az", "sl", "kn",
        "et", "mk", "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw",
        "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc", "ka", "be",
        "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo", "ht", "ps", "tk", "nn",
        "mt", "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha",
        "ba", "jw", "su", "yue",
    ]

    static func language(forPreferred identifiers: [String]) -> String? {
        for identifier in identifiers {
            let code = identifier
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first
                .map(String.init)?
                .lowercased()
            guard let code, supportedLanguageCodes.contains(code) else { continue }
            return code
        }
        return nil
    }
}
