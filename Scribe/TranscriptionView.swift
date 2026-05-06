import SwiftUI

struct TranscriptionView: View {
    @ObservedObject var history = TranscriptionHistory.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Transcriptions")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                if !history.transcriptions.isEmpty {
                    Button(action: {
                        history.clear()
                    }) {
                        Label("Clear All", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Transcriptions list
            if history.transcriptions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "mic.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("No transcriptions yet")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text("Press ⌘⌥⌃V to start recording")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(history.transcriptions) { item in
                            TranscriptionRow(item: item)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 300)
    }
}

struct TranscriptionRow: View {
    let item: TranscriptionItem
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .textSelection(.enabled)
                    .font(.body)

                Text(formatDate(item.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isHovering {
                HStack(spacing: 8) {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")

                    Button(action: {
                        TranscriptionHistory.shared.delete(item)
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
        }
        .padding()
        .background(isHovering ? Color(NSColor.controlBackgroundColor) : Color.clear)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
