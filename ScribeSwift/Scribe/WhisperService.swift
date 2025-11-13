import Foundation
import WhisperKit

class WhisperService {
    private var whisperKit: WhisperKit?
    private var isLoading = false
    private var isLoaded = false

    init() {
        // WhisperKit will be loaded asynchronously
    }

    func loadModel(onProgress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        guard !isLoaded && !isLoading else {
            completion(isLoaded)
            return
        }

        isLoading = true
        onProgress("Loading Whisper model...")

        Task {
            do {
                onProgress("Initializing WhisperKit (downloading model if needed, ~3GB first time)...")

                // Initialize WhisperKit - it will download and load the model automatically
                whisperKit = try await WhisperKit()

                isLoaded = true
                isLoading = false

                await MainActor.run {
                    onProgress("✓ Model loaded successfully")
                    completion(true)
                }

            } catch {
                isLoading = false
                print("Failed to load WhisperKit: \(error)")

                await MainActor.run {
                    onProgress("✗ Failed to load model: \(error.localizedDescription)")
                    completion(false)
                }
            }
        }
    }

    func transcribe(audioData: Data, completion: @escaping (Result<String, Error>) -> Void) {
        guard isLoaded, let whisperKit = whisperKit else {
            completion(.failure(NSError(
                domain: "WhisperService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Model not loaded"]
            )))
            return
        }

        Task {
            do {
                // Save audio data to temporary file
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("wav")

                try audioData.write(to: tempURL)

                defer {
                    try? FileManager.default.removeItem(at: tempURL)
                }

                print("Transcribing audio file: \(tempURL.path)")

                // Transcribe with WhisperKit - returns array of TranscriptionResult
                let results = try await whisperKit.transcribe(audioPath: tempURL.path)

                // Extract transcribed text from results array
                guard !results.isEmpty else {
                    await MainActor.run {
                        completion(.success(""))
                    }
                    return
                }

                // Combine text from all results
                let text = results.compactMap { $0.text }.joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

                // Filter out common hallucinations
                let filteredText = filterHallucinations(text)

                guard !filteredText.isEmpty else {
                    await MainActor.run {
                        completion(.success(""))
                    }
                    return
                }

                print("Transcription complete: \(filteredText)")

                await MainActor.run {
                    completion(.success(filteredText))
                }

            } catch {
                print("Transcription error: \(error)")
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    private func filterHallucinations(_ text: String) -> String {
        var filtered = text

        // Common Whisper hallucinations
        let hallucinations = [
            "Thank you.", "Thank you", "Thanks for watching",
            "Thanks for watching.", "Bye.", "Goodbye.",
            "Thank you for watching.", "you", "you.", "You"
        ]

        for hallucination in hallucinations {
            if filtered == hallucination {
                return ""
            }
            if filtered.hasSuffix(hallucination) {
                filtered = String(filtered.dropLast(hallucination.count))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }
        }

        return filtered
    }

    func cleanup() {
        whisperKit = nil
        isLoaded = false
    }
}
