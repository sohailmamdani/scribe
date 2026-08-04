import Foundation

enum ScribeModelProfile: String, Equatable, Sendable {
    case highAccuracy
    case compatibility

    var downloadVariant: String {
        switch self {
        case .highAccuracy: "large-v3-v20240930_626MB"
        case .compatibility: "base"
        }
    }

    var folderName: String {
        switch self {
        case .highAccuracy: "openai_whisper-large-v3-v20240930_626MB"
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
}

enum ScribeModelPolicy {
    static let version = 2
    static let repository = "argmaxinc/whisperkit-coreml"
    static let primary: ScribeModelProfile = .highAccuracy
    static let fallback: ScribeModelProfile = .compatibility

    static func compatibilitySignature(osMajorVersion: Int) -> String {
        "v\(version)|\(primary.folderName)|ios\(osMajorVersion)"
    }

    static func preferredProfile(
        storedCompatibilitySignature: String?,
        osMajorVersion: Int
    ) -> ScribeModelProfile {
        storedCompatibilitySignature == compatibilitySignature(osMajorVersion: osMajorVersion)
            ? .compatibility
            : .highAccuracy
    }
}

enum ScribeModelDownloadPolicy {
    static let maximumAttempts = 3
    static let minimumHighAccuracyCapacity: Int64 = 1_500_000_000

    static func retryDelay(afterFailedAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1: 1
        default: 3
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
            return "High Accuracy needs about 1.5 GB free. Free some storage, then try again."
        }
        if errors.contains(where: { $0.domain == NSURLErrorDomain }) {
            return "High Accuracy was interrupted. Keep Scribe open on a stable connection, then tap Try High Accuracy again — the download will resume."
        }
        return "High Accuracy couldn’t finish (\(error.domain) \(error.code)). Tap Try High Accuracy again — the download will resume."
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
