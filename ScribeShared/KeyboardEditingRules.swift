import Foundation

enum KeyboardFieldKind: Equatable, Sendable {
    case text
    case URL
    case email
    case webSearch
    case phone
    case number
    case other

    var supportsDoubleSpacePeriod: Bool {
        self == .text
    }

    var supportsAutocorrection: Bool {
        self == .text || self == .webSearch
    }
}

enum KeyboardCapitalizationMode: Equatable, Sendable {
    case none
    case words
    case sentences
    case allCharacters
}

enum KeyboardShiftState: Equatable, Sendable {
    case off
    case once
    case locked

    var usesUppercase: Bool { self != .off }
}

enum KeyboardEditingRules {
    static let doubleSpaceInterval: TimeInterval = 0.55

    static func shouldConvertDoubleSpace(
        contextBefore: String?,
        elapsedSincePreviousSpace: TimeInterval?,
        fieldKind: KeyboardFieldKind
    ) -> Bool {
        guard fieldKind.supportsDoubleSpacePeriod,
              let elapsedSincePreviousSpace,
              elapsedSincePreviousSpace >= 0,
              elapsedSincePreviousSpace <= doubleSpaceInterval,
              let contextBefore,
              contextBefore.last == " ",
              let preceding = contextBefore.dropLast().last else {
            return false
        }

        return preceding.isLetter
            || preceding.isNumber
            || ")]}'\"”’".contains(preceding)
    }

    static func automaticShiftState(
        contextBefore: String?,
        capitalization: KeyboardCapitalizationMode
    ) -> KeyboardShiftState {
        switch capitalization {
        case .none:
            return .off
        case .allCharacters:
            return .locked
        case .words:
            guard let contextBefore, let last = contextBefore.last else { return .once }
            return last.isWhitespace ? .once : .off
        case .sentences:
            guard let contextBefore, !contextBefore.isEmpty else { return .once }
            if contextBefore.last == "\n" { return .once }
            let trimmed = contextBefore.drop(whileTrailing: { $0.isWhitespace })
            guard let last = trimmed.last else { return .once }
            return ".!?".contains(last) ? .once : .off
        }
    }

    static func autocorrectionWord(
        contextBefore: String?,
        fieldKind: KeyboardFieldKind,
        autocorrectionEnabled: Bool
    ) -> String? {
        guard autocorrectionEnabled,
              fieldKind.supportsAutocorrection,
              let contextBefore,
              !contextBefore.isEmpty else {
            return nil
        }

        let word = String(
            contextBefore.reversed().prefix { character in
                character.isLetter || character == "'" || character == "’"
            }.reversed()
        )
        guard word.count >= 2,
              word.contains(where: \Character.isLetter),
              !hasUnexpectedCapitalization(word) else {
            return nil
        }
        return word
    }

    static func replacement(_ suggestion: String, matchingCapitalizationOf original: String) -> String? {
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \Character.isWhitespace),
              trimmed.caseInsensitiveCompare(original) != .orderedSame else {
            return nil
        }

        if original == original.lowercased() {
            return trimmed.lowercased()
        }
        if original.first?.isUppercase == true,
           original.dropFirst() == original.dropFirst().lowercased() {
            return trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased()
        }
        return trimmed
    }

    private static func hasUnexpectedCapitalization(_ word: String) -> Bool {
        let letters = word.filter(\Character.isLetter)
        guard letters.count > 1 else { return false }
        if letters == letters.uppercased() { return true }
        return letters.dropFirst().contains(where: \Character.isUppercase)
    }
}

private extension String {
    func drop(whileTrailing predicate: (Character) -> Bool) -> Substring {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            guard predicate(self[previous]) else { break }
            end = previous
        }
        return self[..<end]
    }
}
