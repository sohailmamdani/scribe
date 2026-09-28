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
        lookup: (String, String?) async -> [KeyboardCorrection],
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
        if edit == nil, let word = KeyboardEditingRules.autocorrectionWord(
            contextBefore: before.0, fieldKind: fieldKind,
            autocorrectionEnabled: autocorrectionEnabled
        ), !isRejected(word.lowercased()) {
            let suggestions = await lookup(word, before.0)
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
        if let edit {
            for _ in edit.original { deleteBackward() }
            insertText(edit.replacement)
        }
        return .ready(edit)
    }
}
