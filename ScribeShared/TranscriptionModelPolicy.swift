import Foundation

/// The one transcription model Scribe uses on iOS.
///
/// There is deliberately no fallback tier. Earlier builds shipped a Whisper
/// Base "compatibility" model and switched to it whenever the main model
/// failed to prepare — which in practice meant background load hiccups
/// silently downgraded dictation quality, and users could not tell why
/// results were suddenly poor. A failed preparation is now an honest, visible
/// failure with a retry, never a quiet downgrade.
enum ScribeModelPolicy {
    static let repository = "argmaxinc/whisperkit-coreml"
    static let downloadVariant = "large-v3_947MB"
    static let displayName = "Whisper Large-v3"

    /// The on-disk cache contract. These three values decide whether an
    /// installed model survives an app update:
    ///
    /// - `folderName` is where the weights live under the download base
    ///   (Documents/huggingface, which iOS preserves across updates).
    /// - The marker files record "fully downloaded" and "loaded successfully
    ///   at least once".
    ///
    /// Changing any of them orphans every installed cache and forces users
    /// through the ~945 MB download again. Do not rename them for cosmetic
    /// reasons; there are tests pinning each one.
    static let folderName = "openai_whisper-large-v3_947MB"
    static let downloadedMarkerName = ".scribe-download-complete-v2"
    static let readyMarkerName = ".scribe-ready-v2"

    /// Component weights are validated against a *lower bound* rather than an
    /// exact size. Truncated downloads — the failure this guards against —
    /// fall far below these floors, while an upstream re-publish that shifts
    /// a file by a few bytes must not brand a good cache invalid.
    ///
    /// Actual sizes: 373 KB / 354 MB / 591 MB.
    static let componentRequirements: [ScribeModelComponentRequirement] = [
        .init(name: "MelSpectrogram", minimumWeightBytes: 300_000),
        .init(name: "AudioEncoder", minimumWeightBytes: 330_000_000),
        .init(name: "TextDecoder", minimumWeightBytes: 550_000_000),
    ]

    /// Leftover caches from the retired compatibility tier and the earlier
    /// quantized-turbo build. Safe to delete on sight; reclaims ~800 MB on
    /// devices that carried them.
    static let obsoleteModelFolderNames = [
        "openai_whisper-base",
        "openai_whisper-large-v3-v20240930_626MB",
    ]
}

struct ScribeModelComponentRequirement: Equatable, Sendable {
    let name: String
    let minimumWeightBytes: Int64?

    init(name: String, minimumWeightBytes: Int64? = nil) {
        self.name = name
        self.minimumWeightBytes = minimumWeightBytes
    }
}

enum ScribeModelDownloadPolicy {
    static let maximumAttempts = 4

    /// The Large-v3 weights total roughly 945 MB. Require headroom for the
    /// download, the tokenizer, and CoreML's compiled cache.
    static let minimumCapacity: Int64 = 1_900_000_000

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
            return "Scribe needs about 1.9 GB free for its transcription model. Free some storage, then try again."
        }
        if errors.contains(where: { $0.domain == NSURLErrorDomain }) {
            return "The model download was interrupted. Keep Scribe open on a stable connection and try again — it will resume where it stopped."
        }
        return "The model install couldn’t finish. Try again — Scribe will repair and resume it."
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
