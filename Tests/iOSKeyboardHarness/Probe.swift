import UIKit

/// Runs the production UIKit spell checker and touch surface inside an iOS
/// simulator, with the shipped corpus. No mocks of spelling or ranking.
@main
struct KeyboardIntegrationProbe {
    @MainActor
    static func main() async throws {
        let corpus = URL(fileURLWithPath: CommandLine.arguments[1])
        let words = try String(contentsOf: corpus.appendingPathComponent("AutocorrectWords.txt"), encoding: .utf8)
            .split(separator: "\n").map { line in
                let fields = line.split(separator: " ")
                return (word: String(fields[0]), frequency: Int64(fields[1])!)
            }
        let bigrams = try String(contentsOf: corpus.appendingPathComponent("AutocorrectBigrams.txt"), encoding: .utf8)
            .split(separator: "\n").map { line in
                let fields = line.split(separator: " ")
                return (first: String(fields[0]), second: String(fields[1]), frequency: Int64(fields[2])!)
            }
        let suite = "ScribeKeyboardIntegration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = KeyboardAutocorrectionEngine(words: words, bigrams: bigrams, defaults: defaults)
        await engine.prepare()

        for (context, expected) in [
            ("teh", "the"), ("bread ans", "and"), ("this is smple", "simple"),
            ("recieve", "receive"), ("definately", "definitely"),
            ("in te", "the"), ("dont", "don't"), ("thw", "the"), ("thst", "that"),
            ("For example jf", "if"), ("jf", "if"), ("if i", "I"),
            ("think i'd", "I'd"), ("think i’d", "I’d"), ("think i'm", "I'm"),
            ("think i’m", "I’m"), ("think i'll", "I'll"), ("think i’ve", "I’ve")
        ] {
            let word = String(context.split(separator: " ").last!)
            let start = ProcessInfo.processInfo.systemUptime
            let result = await engine.corrections(
                for: word, contextBefore: context, language: "en-US", evidence: [], includeCompletions: false
            )
            let automatic = result.first(where: \.automaticallyReplaces)?.text
            precondition(automatic == expected, "\(context): expected \(expected), got \(result)")
            print("PASS \(context) -> \(expected) (\(Int((ProcessInfo.processInfo.systemUptime - start) * 1000)) ms)")
        }

        for context in ["hello", "a fir", "looking fir", "form", "well", "its", "as if", "an id", "if in is"] {
            let word = String(context.split(separator: " ").last!)
            let result = await engine.corrections(
                for: word, contextBefore: context, language: "en-US", evidence: [], includeCompletions: false
            )
            precondition(!result.contains(where: \.automaticallyReplaces), "Unwanted correction: \(context)")
        }
        let contextual = await engine.corrections(
            for: "fir", contextBefore: "looking fir", language: "en-US", evidence: [], includeCompletions: false
        )
        precondition(contextual.contains(where: { $0.text == "for" && !$0.automaticallyReplaces }),
                     "Contextual alternative hidden: \(contextual)")
        for context in ["a fir", "looking. fir", "looking\nfir"] {
            let result = await engine.corrections(
                for: "fir", contextBefore: context, language: "en-US", evidence: [], includeCompletions: false
            )
            precondition(!result.contains(where: { $0.text == "for" }), "Unrelated context: \(context)")
        }
        let partialPronoun = await engine.corrections(
            for: "i", contextBefore: "if i", language: "en-US", evidence: [], includeCompletions: true
        )
        precondition(!partialPronoun.contains(where: \.automaticallyReplaces), "Premature I capitalization")
        for word in ["in", "if", "is", "iPhone"] {
            let result = await engine.corrections(for: word, contextBefore: word, language: "en-US", evidence: [])
            precondition(!result.contains(where: { $0.text == "I" }), "Pronoun rule changed \(word)")
        }
        let evidence = [
            KeyboardTapEvidence(character: "f", normalizedDistances: ["f": 0]),
            KeyboardTapEvidence(character: "i", normalizedDistances: ["i": 0.6, "o": 0.65]),
            KeyboardTapEvidence(character: "r", normalizedDistances: ["r": 0])
        ]
        let realWord = await engine.corrections(
            for: "fir", contextBefore: "looking fir", language: "en-US", evidence: evidence, includeCompletions: false
        )
        precondition(realWord.first(where: \.automaticallyReplaces)?.text == "for", "Real-word slip not repaired: \(realWord)")
        let legitimate = await engine.corrections(
            for: "fir", contextBefore: "a fir", language: "en-US", evidence: evidence, includeCompletions: false
        )
        precondition(!legitimate.contains(where: \.automaticallyReplaces), "Legitimate fir changed")
        await engine.recordRejected(original: "ans", replacement: "and")
        let rejected = await engine.corrections(for: "ans", contextBefore: "bread ans", language: "en-US", evidence: [])
        precondition(!rejected.contains(where: \.automaticallyReplaces), "Undo was ignored")
        await engine.updateSupplementaryLexicon(entries: [.init(userInput: "cant", documentText: "Cant")])
        let name = await engine.corrections(for: "cant", contextBefore: "cant", language: "en-US", evidence: [])
        precondition(!name.contains(where: \.automaticallyReplaces), "Contact rewritten as contraction")
        let otherLanguage = await engine.corrections(for: "teh", contextBefore: "teh", language: "de-DE", evidence: [])
        precondition(otherLanguage.isEmpty, "English repair applied to another language")
        let otherPronoun = await engine.corrections(for: "i", contextBefore: "i", language: "de-DE", evidence: [])
        precondition(otherPronoun.isEmpty, "English pronoun rule applied to another language")
        print("PASS real words, names, rejection, and language protection")

        // Real UIKit TouchViews, including out-of-order lifts and overlapping
        // touches across distinct views. No event injection into another app.
        let sequence = KeyboardTouchSequence()
        let letterView = KeyboardTouchSurface.TouchView()
        let spaceView = KeyboardTouchSurface.TouchView()
        letterView.sequence = sequence
        spaceView.sequence = sequence
        var text = "ca"
        letterView.onEnded = { _ in text += "t" }
        spaceView.onEnded = { _ in text += " " }
        let letter = ProbeTouch(time: 1), space = ProbeTouch(time: 2)
        letterView.touchesBegan([letter], with: nil)
        spaceView.touchesBegan([space], with: nil)
        spaceView.touchesEnded([space], with: nil)
        letterView.touchesEnded([letter], with: nil)
        precondition(text == "cat ", "Touch order: \(text)")
        letterView.touchesBegan([letter], with: nil)
        letterView.touchesCancelled([letter], with: nil)
        spaceView.touchesBegan([space], with: nil)
        spaceView.touchesEnded([space], with: nil)
        precondition(text == "cat  ", "Cancelled touch committed")
        var endpoint = CGPoint.zero
        letterView.onEnded = { endpoint = $0 }
        let fastDrag = ProbeTouch(time: 3)
        letterView.touchesBegan([fastDrag], with: nil)
        fastDrag.point = CGPoint(x: 180, y: 60)
        letterView.touchesEnded([fastDrag], with: nil)
        precondition(endpoint == fastDrag.point, "Lift endpoint was discarded")
        print("PASS UIKit overlapping touches, cancellation, and lift endpoint")

        let queue = KeyboardInputQueue()
        text = "teh"
        queue.enqueue {
            let result = await engine.corrections(
                for: "teh", contextBefore: text, language: "en-US", evidence: [], includeCompletions: false
            )
            text = (result.first(where: \.automaticallyReplaces)?.text ?? text) + " "
        }
        queue.enqueue { text += "c" }
        queue.enqueue { text += "a" }
        queue.enqueue { text += "t" }
        await queue.waitUntilIdle()
        precondition(text == "the cat", "Final-word correction and input order: \(text)")
        print("PASS immediate delimiter with next-word input")

        // Use the same boundary editor as KeyboardRootView with a real UIKit
        // text document, including host traits and pre-existing user state.
        await engine.updateSupplementaryLexicon(entries: [
            .init(userInput: "i", documentText: "I"),
            .init(userInput: "i'd", documentText: "I'd")
        ])
        defaults.set(["i", "i'd"], forKey: KeyboardEditingRules.rejectedAutocorrectionWordsKey)
        let persistedEngine = KeyboardAutocorrectionEngine(words: words, bigrams: bigrams, defaults: defaults)
        for word in ["i", "i'd", "i’d", "i'm", "i’ll", "i've"] {
            await engine.recordRejected(original: word, replacement: KeyboardEditingRules.capitalizedEnglishPronoun(word)!)
            for candidateEngine in [engine, persistedEngine] {
                let result = await candidateEngine.corrections(
                    for: word, contextBefore: "think " + word, language: "en-US", evidence: [], includeCompletions: false
                )
                precondition(result.first(where: \.automaticallyReplaces)?.text == KeyboardEditingRules.capitalizedEnglishPronoun(word),
                             "Personal lexicon or old rejection disabled capitalization: \(word)")
            }
        }
        let document = UITextView()
        func replay(_ input: String, expected: String, spelling: Bool = true,
                    capitalization: KeyboardCapitalizationMode = .sentences,
                    field: KeyboardFieldKind = .text, language: String = "en-US") async {
            document.text = ""
            for character in input {
                queue.enqueue {
                    if KeyboardEditingRules.isWordBoundary(character) {
                        let result = await KeyboardWordBoundaryEditor.correctCompletedWord(
                            context: { (document.text, "") }, documentID: { "test-document" },
                            fieldKind: field, capitalization: capitalization,
                            autocorrectionEnabled: spelling, language: language,
                            isRejected: { KeyboardEditingRules.isRejectedAutocorrectionWord($0, defaults: defaults) },
                            lookup: { word, before in
                                await persistedEngine.corrections(for: word, contextBefore: before,
                                    language: language, evidence: [], includeCompletions: false)
                            },
                            deleteBackward: { document.deleteBackward() },
                            insertText: { document.insertText($0) }
                        )
                        precondition(result != .invalidated, "Unexpected invalidation")
                    }
                    document.insertText(String(character))
                }
            }
            await queue.waitUntilIdle()
            precondition(document.text == expected, "Production document regression: \(input) -> \(document.text ?? "nil"), expected \(expected)")
            print("PASS document input: \(input.debugDescription) -> \(expected.debugDescription)")
        }
        await replay("For example jf i type in this sentence ", expected: "For example if I type in this sentence ")
        await replay("so i think i'd like it ", expected: "so I think I'd like it ")
        await replay("i’m sure i’ll say i’ve tried ", expected: "I’m sure I’ll say I’ve tried ")
        await replay("i i'd i'm i'll i've ", expected: "I I'd I'm I'll I've ", spelling: false)
        await replay("(i), 'i' i! i? i; i: i. i\n", expected: "(I), 'I' I! I? I; I: I. I\n", spelling: false)
        await replay("in if is id ill iPhone item_i /i @i example.i ",
                     expected: "in if is id ill iPhone item_i /i @i example.i ", spelling: false)
        await replay("i i'd ", expected: "i i'd ", spelling: false, capitalization: .none)
        await replay("i i'd ", expected: "i i'd ", field: .email)
        await replay("i i'd ", expected: "i i'd ", language: "de-DE")
        await replay("i", expected: "i") // no premature correction before a delimiter
        await replay("i'd", expected: "i'd")

        // Async spelling must not edit a switched field; deterministic case
        // repair must not call the spelling service at all.
        document.text = "i"
        let capitalized = await KeyboardWordBoundaryEditor.correctCompletedWord(
            context: { (document.text, "") }, documentID: { "test" }, fieldKind: .text,
            capitalization: .sentences, autocorrectionEnabled: false, language: "en-US",
            isRejected: { _ in true }, lookup: { _, _ in fatalError("Capitalization waited for spelling") },
            deleteBackward: { document.deleteBackward() }, insertText: { document.insertText($0) }
        )
        precondition(capitalized == .ready(.init(original: "i", replacement: "I")))
        // The UI's undo restores only this occurrence, with its delimiter.
        document.deleteBackward()
        document.insertText("i ")
        precondition(document.text == "i ")
        document.text = "teh"
        let invalidated = await KeyboardWordBoundaryEditor.correctCompletedWord(
            context: { (document.text, "") }, documentID: { "test" }, fieldKind: .text,
            capitalization: .sentences, autocorrectionEnabled: true, language: "en-US",
            isRejected: { _ in false }, lookup: { _, _ in
                document.text = "another field"
                return [KeyboardCorrection(text: "the", automaticallyReplaces: true)]
            }, deleteBackward: { document.deleteBackward() }, insertText: { document.insertText($0) }
        )
        precondition(invalidated == .invalidated && document.text == "another field")
        await engine.recordRejected(original: "jf", replacement: "if")
        let rejectedShort = await engine.corrections(for: "jf", contextBefore: "jf", language: "en-US", evidence: [], includeCompletions: false)
        precondition(!rejectedShort.contains(where: \.automaticallyReplaces), "Spelling undo ignored")
        print("PASS capitalization with personal lexicon, persisted rejections, host traits, quotes, and async field changes")
        print("All iOS keyboard integration checks passed.")
    }
}

private final class ProbeTouch: UITouch {
    var point = CGPoint(x: 20, y: 20)
    private let time: TimeInterval
    init(time: TimeInterval) { self.time = time; super.init() }
    override var timestamp: TimeInterval { time }
    override func location(in view: UIView?) -> CGPoint { point }
}
