import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ContentViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scribe")
                        .font(.system(size: 28, weight: .bold))

                    Text("Real-time Speech-to-Text Transcription")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Keep on Top toggle
                Toggle("Keep on Top", isOn: $appState.keepOnTop)
                    .toggleStyle(.switch)
                    .onChange(of: appState.keepOnTop) { _, newValue in
                        viewModel.setWindowFloating(newValue)
                    }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Status bar
            HStack {
                Image(systemName: appState.isRecording ? "mic.fill" : "mic.slash.fill")
                    .foregroundColor(appState.isRecording ? .red : .secondary)
                    .imageScale(.medium)

                Text(appState.statusMessage)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(appState.isLoading ? .blue : .primary)

                Spacer()

                if appState.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Transcriptions area
            ScrollView {
                if appState.transcriptions.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "waveform")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                            .padding(.top, 60)

                        Text("No transcriptions yet")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        Text("Press ⌘R or the record button to start")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(appState.transcriptions.enumerated()), id: \.offset) { index, text in
                            TranscriptionItemView(text: text, index: index)
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Controls
            VStack(spacing: 12) {
                // Record button
                Button(action: {
                    viewModel.toggleRecording()
                }) {
                    HStack {
                        Image(systemName: appState.isRecording ? "stop.fill" : "mic.fill")
                        Text(appState.isRecording ? "Stop Recording" : "Start Recording")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.isRecording ? .red : .blue)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.isLoading)

                // Options
                HStack {
                    Toggle("Auto-paste to Active Window", isOn: $appState.autoPasteEnabled)
                        .toggleStyle(.checkbox)

                    Spacer()

                    Button("Clear All") {
                        appState.transcriptions.removeAll()
                    }
                    .disabled(appState.transcriptions.isEmpty)
                }
                .font(.subheadline)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .onAppear {
            viewModel.setup(appState: appState)
        }
    }
}

struct TranscriptionItemView: View {
    let text: String
    let index: Int
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("#\(index + 1)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)

            Text(text)
                .textSelection(.enabled)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isHovering {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
        }
        .padding(12)
        .background(isHovering ? Color(NSColor.controlBackgroundColor) : Color.clear)
        .cornerRadius(8)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
