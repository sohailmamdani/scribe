import Foundation
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional second pass over a finished transcript using Apple's on-device
/// language model.
///
/// This runs once per utterance, not per keystroke, which is the only place in
/// Scribe where a model of this size fits the latency budget — autocorrect
/// needs an answer in tens of milliseconds, this has seconds.
///
/// Every result is checked against `TranscriptPolisher.isFaithfulRefinement`
/// before it is used, and anything slow, unavailable, or unfaithful silently
/// keeps the deterministic rule-based transcript. A dictation app that
/// occasionally invents words the user did not say would be worse than one
/// that punctuates imperfectly.
actor TranscriptRefiner {
    enum Readiness: Equatable {
        case ready
        case unsupportedDevice
        case notEnabled
        case notReady
        case unavailableOnThisOS
    }

    private let logger = Logger(subsystem: "sohail.Scribe.mobile", category: "Refiner")

    /// Long enough for a normal utterance, short enough that a stall never
    /// holds up the transcript the user is waiting on.
    private static let timeout: Duration = .seconds(6)

    /// Refinement is skipped for very short transcripts, where the rule-based
    /// pass already produces the right answer and a model round trip is pure
    /// latency.
    private static let minimumWordCount = 4

    private static let instructions = """
        You clean up speech-to-text transcripts. Return the transcript with \
        correct punctuation, capitalization, and sentence breaks.

        Rules you must follow exactly:
        - Never add words that are not in the transcript.
        - Never substitute a word for a different word.
        - Never reorder words.
        - Never answer, summarize, explain, or comment on the transcript.
        - You may delete filler words such as um, uh, and repeated stutters.
        - Return only the cleaned transcript and nothing else.
        """

    var readiness: Readiness {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return .unavailableOnThisOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(.deviceNotEligible):
            return .unsupportedDevice
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notEnabled
        case .unavailable(.modelNotReady):
            return .notReady
        case .unavailable:
            return .notReady
        }
        #else
        return .unavailableOnThisOS
        #endif
    }

    /// Returns a refined transcript, or nil to keep the rule-based one.
    func refine(_ transcript: String) async -> String? {
        guard TranscriptPolisher.comparableWords(transcript).count >= Self.minimumWordCount else {
            return nil
        }

        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), readiness == .ready else { return nil }

        do {
            let candidate = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask { [weak self] in
                    try await self?.generate(transcript)
                }
                group.addTask {
                    try await Task.sleep(for: Self.timeout)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }

            guard let candidate else {
                logger.warning("On-device refinement timed out; keeping the rule-based transcript")
                return nil
            }

            let cleaned = TranscriptPolisher.polish(candidate)
            guard TranscriptPolisher.isFaithfulRefinement(cleaned, of: transcript) else {
                logger.warning("Discarded an unfaithful on-device refinement")
                return nil
            }
            return cleaned
        } catch {
            logger.warning("On-device refinement failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func generate(_ transcript: String) async throws -> String {
        // Sessions carry conversation history, so a fresh one per utterance
        // keeps one transcript from leaking into the next.
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(
            to: transcript,
            options: GenerationOptions(
                // Deterministic: this is a formatting task, not a creative one.
                temperature: 0,
                maximumResponseTokens: 1_200
            )
        )
        return response.content
    }
    #endif
}
