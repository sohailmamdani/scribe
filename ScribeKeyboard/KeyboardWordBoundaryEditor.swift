import Foundation

/// The production document-edit path, shared by the keyboard and simulator
/// probes. Capitalization finishes synchronously before spelling can suspend.
@MainActor
enum KeyboardWordBoundaryEditor {
    enum Result: Equatable {
        case invalidated
        case ready(KeyboardEditingRules.WordReplacement?)
    }

    static func correctCompletedWord(
        context: () -> (String?, String?),
        documentID: () -> String?,
        fieldKind: KeyboardFieldKind,
        capitalization: KeyboardCapitalizationMode,
        autocorrectionEnabled: Bool,
        language: String,
        isRejected: (String) -> Bool,
        lookup: (String, String?, String?) async -> [KeyboardCorrection],
        deleteBackward: () -> Void,
        insertText: (String) -> Void
    ) async -> Result {
        guard !Task.isCancelled else { return .invalidated }
        let before = context()
        let id = documentID()
        var edit = KeyboardEditingRules.pronounCapitalization(
            contextBefore: before.0, fieldKind: fieldKind,
            capitalization: capitalization, autocorrectionEnabled: autocorrectionEnabled,
            language: language
        )
        let word = KeyboardEditingRules.autocorrectionWord(
            contextBefore: before.0, fieldKind: fieldKind,
            autocorrectionEnabled: autocorrectionEnabled
        )
        if edit == nil, let word, !isRejected(word.lowercased()) {
            let suggestions = await lookup(word, before.0, nil)
            guard !Task.isCancelled else { return .invalidated }
            let after = context()
            guard before.0 == after.0, before.1 == after.1, id == documentID() else {
                return .invalidated
            }
            if let suggestion = suggestions.first(where: \.automaticallyReplaces),
               let replacement = KeyboardEditingRules.replacement(
                suggestion.text, matchingCapitalizationOf: word
               ) {
                edit = .init(original: word, replacement: replacement)
            }
        }
        // Revisit the preceding ambiguous token only once the next word is
        // complete. The queue keeps following keystrokes behind this lookup.
        if let word, let text = before.0 {
            let prefix = String(text.dropLast(word.count))
            if prefix.last == " " {
                let previousContext = String(prefix.dropLast())
                if let previous = KeyboardEditingRules.autocorrectionWord(
                    contextBefore: previousContext, fieldKind: fieldKind,
                    autocorrectionEnabled: autocorrectionEnabled
                ), ["id", "ill"].contains(previous.lowercased()),
                   !isRejected(previous.lowercased()) {
                    let following = edit?.replacement ?? word
                    let suggestions = await lookup(previous, previousContext, following)
                    guard !Task.isCancelled else { return .invalidated }
                    let after = context()
                    guard before.0 == after.0, before.1 == after.1, id == documentID() else {
                        return .invalidated
                    }
                    if let suggestion = suggestions.first(where: \.automaticallyReplaces),
                       let replacement = KeyboardEditingRules.replacement(
                        suggestion.text, matchingCapitalizationOf: previous
                       ) {
                        edit = .init(
                            original: previous + " " + word,
                            replacement: replacement + " " + following,
                            rejectionOriginal: previous,
                            rejectionReplacement: replacement
                        )
                    }
                }
            }
        }
        if let edit {
            for _ in edit.original { deleteBackward() }
            insertText(edit.replacement)
        }
        return .ready(edit)
    }
}
