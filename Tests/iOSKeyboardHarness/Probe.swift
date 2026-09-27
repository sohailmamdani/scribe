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
            ("For example jf", "if"), ("jf", "if"), ("if i", "I")
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

        // Exercise extraction, final-word decisions, case preservation, and
        // serialized fast typing together using the user's reported sentence.
        text = ""
        for character in "For example jf i type in this sentence " {
            let value = String(character)
            queue.enqueue {
                if value == " ", let word = KeyboardEditingRules.autocorrectionWord(
                    contextBefore: text, fieldKind: .text, autocorrectionEnabled: true
                ) {
                    let result = await engine.corrections(
                        for: word, contextBefore: text, language: "en-US", evidence: [], includeCompletions: false
                    )
                    if let suggestion = result.first(where: \.automaticallyReplaces),
                       let replacement = KeyboardEditingRules.replacement(suggestion.text, matchingCapitalizationOf: word) {
                        text.removeLast(word.count)
                        text += replacement
                    }
                }
                text += value
            }
        }
        await queue.waitUntilIdle()
        precondition(text == "For example if I type in this sentence ", "Sentence regression: \(text)")
        print("PASS reported sentence: \(text)")
        for (word, replacement) in [("i", "I"), ("jf", "if")] {
            await engine.recordRejected(original: word, replacement: replacement)
            let result = await engine.corrections(
                for: word, contextBefore: "if \(word)", language: "en-US", evidence: [], includeCompletions: false
            )
            precondition(!result.contains(where: \.automaticallyReplaces), "Short-word undo ignored: \(word)")
        }
        print("PASS short-word rejection and pronoun timing")
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
