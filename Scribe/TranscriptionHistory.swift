import Foundation
import Combine

class TranscriptionHistory: ObservableObject {
    static let shared = TranscriptionHistory()

    @Published var transcriptions: [TranscriptionItem] = []

    private init() {
        loadTranscriptions()
    }

    func add(_ text: String) {
        let item = TranscriptionItem(
            id: UUID(),
            text: text,
            timestamp: Date()
        )

        transcriptions.insert(item, at: 0)
        saveTranscriptions()
    }

    func clear() {
        transcriptions.removeAll()
        saveTranscriptions()
    }

    func delete(_ item: TranscriptionItem) {
        transcriptions.removeAll { $0.id == item.id }
        saveTranscriptions()
    }

    private func saveTranscriptions() {
        if let encoded = try? JSONEncoder().encode(transcriptions) {
            UserDefaults.standard.set(encoded, forKey: "transcriptions")
        }
    }

    private func loadTranscriptions() {
        if let data = UserDefaults.standard.data(forKey: "transcriptions"),
           let decoded = try? JSONDecoder().decode([TranscriptionItem].self, from: data) {
            transcriptions = decoded
        }
    }
}

struct TranscriptionItem: Identifiable, Codable {
    let id: UUID
    let text: String
    let timestamp: Date
}
