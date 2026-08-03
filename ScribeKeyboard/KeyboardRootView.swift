import Combine
import SwiftUI

struct KeyboardRootView: View {
    let hasFullAccess: Bool
    let needsInputModeSwitchKey: Bool
    let insertText: (String) -> Void
    let deleteBackward: () -> Void
    let advanceInputMode: () -> Void
    let context: () -> (String?, String?)
    let openContainingApp: (URL, @escaping (Bool) -> Void) -> Void

    @StateObject private var state = KeyboardDictationState()
    @State private var isShifted = true
	@State private var layout: KeyboardLayout = .letters
	@State private var lastInsertedText: String?

    private enum KeyboardLayout {
        case letters
        case numbers
        case symbols
    }

    var body: some View {
        VStack(spacing: 5) {
            dictationBar
            characterRow(activeRows[0])
            characterRow(activeRows[1])
                .padding(.horizontal, 14)
            HStack(spacing: 6) {
                if layout == .letters {
                    key(systemName: "shift.fill", width: 44, emphasized: isShifted) {
                        isShifted.toggle()
                    }
                } else {
                    textKey(layout == .numbers ? "#+=" : "123", width: 44) {
                        layout = layout == .numbers ? .symbols : .numbers
                    }
                }
                characterRow(activeRows[2])
                key(systemName: "delete.left.fill", width: 44) { manualDelete() }
            }
            HStack(spacing: 6) {
                if needsInputModeSwitchKey {
                    key(systemName: "globe", width: 44) { advanceInputMode() }
                }
                textKey(layout == .letters ? "123" : "ABC", width: 48) {
                    layout = layout == .letters ? .numbers : .letters
                    isShifted = layout == .letters
                }
                textKey("space", width: nil) { manualInsert(" ") }
                key(systemName: "return", width: 52) { manualInsert("\n") }
            }
        }
        .padding(.horizontal, 5)
        .padding(.top, 5)
        .padding(.bottom, 3)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGray5))
        .onAppear {
            state.start { transcript in
                let surrounding = context()
				let insertion = TranscriptPolisher.textForInsertion(
                    transcript,
                    contextBefore: surrounding.0,
                    contextAfter: surrounding.1
				)
				insertText(insertion)
				lastInsertedText = insertion
            }
        }
        .onDisappear { state.stop() }
    }

    @ViewBuilder
    private var dictationBar: some View {
        HStack(spacing: 12) {
            switch state.phase {
            case .recording:
                WaveformView(level: state.audioLevel)
                Text("Listening…")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    state.stopRecording()
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.red, in: Circle())
                }
            case .launching:
                Image(systemName: "app.badge")
                    .foregroundStyle(.indigo)
                Text(state.message)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Button("Cancel") { state.cancelHandoff() }
                    .font(.caption.bold())
            case .preparing, .transcribing:
                ProgressView()
                Text(state.message.isEmpty ? "Starting Scribe…" : state.message)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if state.phase == .transcribing {
                    Image(systemName: "sparkles").foregroundStyle(.indigo)
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(state.message).font(.caption).lineLimit(2)
                Spacer()
                Button("Retry") { retryOrBeginDictation() }.font(.caption.bold())
            case .idle, .completed:
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(hasFullAccess ? "On-device dictation" : "Full Access required")
                    .font(.subheadline.weight(.medium))
                Spacer()
				if lastInsertedText != nil {
					Button { undoLastInsertion() } label: {
						Image(systemName: "arrow.uturn.backward")
							.frame(width: 34, height: 34)
					}
					.accessibilityLabel("Undo last dictation")
				}
                Button { beginDictation() } label: {
                    Label("Dictate", systemImage: "mic.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Color.indigo.gradient, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(.background, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func beginDictation() {
        guard hasFullAccess else {
            state.showFullAccessError()
            return
        }
		lastInsertedText = nil
        state.beginRecordingHandoff()
        openScribe(path: "dictate")
    }

    private func retryOrBeginDictation() {
        guard hasFullAccess else {
            state.showFullAccessError()
            return
        }

        if state.retryAvailable {
            state.beginRetryHandoff()
            openScribe(path: "retry")
        } else {
            beginDictation()
        }
    }

    private func openScribe(path: String) {
        guard let url = URL(string: "scribe://\(path)") else {
            state.handoffDidFail()
            return
        }

        openContainingApp(url) { success in
            Task { @MainActor in
                if !success { state.handoffDidFail() }
            }
        }
    }

    private var activeRows: [[Character]] {
        switch layout {
        case .letters:
            [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]
        case .numbers:
            [Array("1234567890"), Array("-/:;()$&@\""), Array(".,?!'")]
        case .symbols:
            [Array("[]{}#%^*+="), Array("_\\|~<>€£¥"), Array(".,?!'")]
        }
    }

    private func characterRow(_ characters: [Character]) -> some View {
        HStack(spacing: 5) {
            ForEach(characters, id: \.self) { character in
                Button {
                    let value = layout == .letters && isShifted
                        ? String(character).uppercased()
                        : String(character)
					manualInsert(value)
                    if layout == .letters { isShifted = false }
                } label: {
                    Text(layout == .letters && isShifted
                         ? String(character).uppercased()
                         : String(character))
                        .font(.system(size: 21))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 41)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
    }

	private func manualInsert(_ text: String) {
		lastInsertedText = nil
		insertText(text)
	}

	private func manualDelete() {
		lastInsertedText = nil
		deleteBackward()
	}

	private func undoLastInsertion() {
		guard let lastInsertedText,
		      let textBeforeCursor = context().0,
		      textBeforeCursor.hasSuffix(lastInsertedText) else {
			self.lastInsertedText = nil
			return
		}

		for _ in lastInsertedText {
			deleteBackward()
		}
		self.lastInsertedText = nil
	}

    private func key(systemName: String, width: CGFloat, emphasized: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: width, height: 41)
                .background(emphasized ? Color(.systemBackground) : Color(.systemGray3), in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.16), radius: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func textKey(_ title: String, width: CGFloat?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .frame(maxWidth: width == nil ? .infinity : nil)
                .frame(width: width, height: 41)
                .background(Color(.systemGray3), in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.16), radius: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
}

private struct WaveformView: View {
    let level: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(.red)
                    .frame(width: 3, height: 8 + CGFloat(level) * CGFloat(8 + index * 3))
            }
        }
        .frame(width: 28, height: 32)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

@MainActor
final class KeyboardDictationState: NSObject, ObservableObject {
    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var message = ""
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var retryAvailable = false

    private let store = SharedDictationStore()
    private var timer: Timer?
    private var lastResultID = ""
    private var onTranscript: ((String) -> Void)?

    func start(onTranscript: @escaping (String) -> Void) {
        self.onTranscript = onTranscript
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: 0.18,
            target: self,
            selector: #selector(refreshFromTimer),
            userInfo: nil,
            repeats: true
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func beginRecordingHandoff() {
        store.issue(.start)
        store.phase = .launching
        store.message = "Opening Scribe…"
        refresh()
    }

    func beginRetryHandoff() {
        store.issue(.retry)
        store.phase = .preparing
        store.message = "Retrying saved recording…"
        refresh()
    }

    func handoffDidFail() {
        store.fail("Scribe couldn’t open. Tap Retry.", retryAvailable: store.retryAvailable)
        refresh()
    }

    func cancelHandoff() {
        store.reset()
        refresh()
    }

    func stopRecording() {
        store.issue(.stop)
        store.phase = .transcribing
        store.message = "Polishing your words…"
        refresh()
    }

    func showFullAccessError() {
        phase = .failed
        message = "Enable Full Access in Settings to connect the keyboard to Scribe."
    }

    private func refresh() {
        phase = store.phase
        message = store.message
        audioLevel = store.audioLevel
        retryAvailable = store.retryAvailable

		let age = Date().timeIntervalSince(store.updatedAt)
		let isStale = switch phase {
		case .recording: age > 10
		case .launching, .preparing, .transcribing: age > 300
		case .idle, .completed, .failed: false
		}
		if isStale {
			store.fail("Scribe stopped responding. Tap Retry to reconnect.", retryAvailable: retryAvailable)
			phase = .failed
			message = store.message
			return
		}

        let resultID = store.resultID
        guard phase == .completed, !resultID.isEmpty, resultID != lastResultID else { return }
        lastResultID = resultID
        guard let transcript = store.consumeTranscript() else { return }
        onTranscript?(transcript)
        phase = .idle
        message = ""
    }

    @objc private func refreshFromTimer() {
        refresh()
    }
}
