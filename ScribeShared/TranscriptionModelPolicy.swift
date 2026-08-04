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
