import Combine
import SwiftUI
import UIKit

enum KeyID: Hashable {
    case character(Character)
    case shift
    case delete
    case layoutToggle
}

struct KeyboardRootView: View {
    let hasFullAccess: Bool
    let needsInputModeSwitchKey: Bool
    let insertText: (String) -> Void
    let deleteBackward: () -> Void
    let advanceInputMode: () -> Void
    let context: () -> (String?, String?)
    let openContainingApp: (URL, @escaping (Bool) -> Void) -> Void

    @Environment(\.openURL) private var openURL
    @StateObject private var state = KeyboardDictationState()
    @StateObject private var deleteRepeater = KeyRepeatEngine()
    @State private var isShifted = true
    @State private var layout: KeyboardLayout = .letters
    @State private var lastInsertedText: String?

    // Unified touch handling over the key area: frames are collected per key
    // so one drag gesture can drive taps, hold-to-repeat delete, and swipes.
    @State private var keyFrames: [KeyID: CGRect] = [:]
    @State private var pressedKey: KeyID?
    @State private var touchStart: CGPoint?
    @State private var startKey: KeyID?
    @State private var isSwiping = false
    @State private var swipePoints: [CGPoint] = []
    @State private var swipeKeys: [Character] = []

    private static let keySpace = "keyArea"

    private enum KeyboardLayout {
        case letters
        case numbers
        case symbols
    }

    var body: some View {
        Group {
            if state.phase == .recording || state.phase == .transcribing {
                listeningPanel
            } else {
                VStack(spacing: 5) {
                    dictationBar
                    keyArea
                    HStack(spacing: 6) {
                        if needsInputModeSwitchKey {
                            bottomKey(systemName: "globe", width: 44) { advanceInputMode() }
                        }
                        bottomKey(title: layout == .letters ? "123" : "ABC", width: 48) {
                            layout = layout == .letters ? .numbers : .letters
                            isShifted = layout == .letters
                        }
                        bottomKey(title: "space", width: nil) { manualInsert(" ") }
                        bottomKey(systemName: "return", width: 52) { manualInsert("\n") }
                    }
                }
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
        .onChange(of: state.handoffFallbackNeeded) { _, needed in
            guard needed else { return }
            state.handoffFallbackNeeded = false
            state.beginRecordingHandoff()
            openScribe(path: "dictate")
        }
    }

    // MARK: - Listening panel

    private var listeningPanel: some View {
        VStack(spacing: 0) {
            HStack {
                if state.phase == .recording {
                    Button {
                        state.cancelDictation()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(.background, in: Circle())
                    }
                }
                Spacer()
                if state.phase == .recording {
                    Button {
                        state.stopRecording()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.indigo.gradient, in: Circle())
                    }
                }
            }
            Spacer()
            if state.phase == .recording {
                ListeningWaveform(level: state.audioLevel)
                Text("Listening")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 14)
                Text("On-device · private")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else {
                ProgressView()
                    .controlSize(.large)
                Text(state.message.isEmpty ? "Polishing your words…" : state.message)
                    .font(.title3.weight(.semibold))
                    .padding(.top, 14)
            }
            Spacer()
            HStack {
                if needsInputModeSwitchKey {
                    Button {
                        advanceInputMode()
                    } label: {
                        Image(systemName: "globe")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                    }
                }
                Spacer()
            }
        }
        .padding(6)
    }

    // MARK: - Key area

    private var keyArea: some View {
        VStack(spacing: 5) {
            characterRow(activeRows[0])
            characterRow(activeRows[1])
                .padding(.horizontal, 14)
            HStack(spacing: 6) {
                if layout == .letters {
                    keyCap(id: .shift, width: 44, emphasized: isShifted) {
                        Image(systemName: "shift.fill")
                            .font(.system(size: 17, weight: .medium))
                    }
                } else {
                    keyCap(id: .layoutToggle, width: 44) {
                        Text(layout == .numbers ? "#+=" : "123")
                            .font(.system(size: 15))
                    }
                }
                characterRow(activeRows[2])
                keyCap(id: .delete, width: 44) {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 17, weight: .medium))
                }
            }
        }
        .coordinateSpace(name: Self.keySpace)
        .onPreferenceChange(KeyFramesKey.self) { keyFrames = $0 }
        .contentShape(Rectangle())
        .gesture(keyDragGesture)
        .overlay {
            SwipeTrailShape(points: swipePoints)
                .stroke(
                    Color.indigo.opacity(0.55),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
                )
                .opacity(isSwiping ? 1 : 0)
                .allowsHitTesting(false)
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
                let display = layout == .letters && isShifted
                    ? String(character).uppercased()
                    : String(character)
                keyCap(id: .character(character), width: nil, isCharacterKey: true) {
                    Text(display)
                        .font(.system(size: 21))
                }
            }
        }
    }

    private func keyCap<Label: View>(
        id: KeyID,
        width: CGFloat?,
        emphasized: Bool = false,
        isCharacterKey: Bool = false,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let isPressed = pressedKey == id
        let baseColor: Color = isCharacterKey || emphasized
            ? Color(.systemBackground)
            : Color(.systemGray3)
        return label()
            .foregroundStyle(.primary)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width, height: 41)
            .background(
                isPressed ? Color(.systemGray2) : baseColor,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .shadow(color: .black.opacity(isCharacterKey ? 0.18 : 0.16), radius: 0, y: 1)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: KeyFramesKey.self,
                        value: [id: proxy.frame(in: .named(Self.keySpace))]
                    )
                }
            )
    }

    private func bottomKey(
        title: String? = nil,
        systemName: String? = nil,
        width: CGFloat?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 17, weight: .medium))
                } else {
                    Text(title ?? "")
                        .font(.system(size: 15))
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width, height: 41)
            .background(Color(.systemGray3), in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.16), radius: 0, y: 1)
        }
        .buttonStyle(HapticKeyStyle())
    }

    // MARK: - Touch handling

    private var keyDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.keySpace))
            .onChanged { value in
                if touchStart == nil {
                    touchBegan(at: value.location)
                } else {
                    touchMoved(to: value.location)
                }
            }
            .onEnded { value in
                touchEnded(at: value.location)
            }
    }

    private func touchBegan(at point: CGPoint) {
        touchStart = point
        let key = key(at: point)
        startKey = key
        pressedKey = key
        guard let key else { return }
        KeyboardHaptics.keyDown()
        if key == .delete {
            manualDelete()
            deleteRepeater.begin(
                deleteCharacter: {
                    manualDelete()
                    KeyboardHaptics.deleteTick()
                },
                deleteWord: {
                    deleteWordBackward()
                    KeyboardHaptics.deleteTick()
                }
            )
        }
    }

    private func touchMoved(to point: CGPoint) {
        guard let start = touchStart else { return }

        if isSwiping {
            appendSwipePoint(point)
            if let letter = letterKey(at: point) {
                pressedKey = .character(letter)
            }
            return
        }

        if case .character(let character)? = startKey,
           layout == .letters,
           character.isLetter,
           hypot(point.x - start.x, point.y - start.y) > 24 {
            isSwiping = true
            swipePoints = [start, point]
            swipeKeys = []
            if let first = letterKey(at: start) { swipeKeys.append(first) }
            if let current = letterKey(at: point), current != swipeKeys.last {
                swipeKeys.append(current)
            }
            return
        }

        if startKey == .delete {
            if key(at: point) != .delete {
                deleteRepeater.stop()
                pressedKey = nil
            }
        } else {
            pressedKey = key(at: point)
        }
    }

    private func touchEnded(at point: CGPoint) {
        deleteRepeater.stop()
        defer {
            touchStart = nil
            startKey = nil
            pressedKey = nil
            isSwiping = false
            swipePoints = []
            swipeKeys = []
        }

        if isSwiping {
            commitSwipe()
            return
        }

        guard let key = key(at: point) else { return }
        switch key {
        case .character(let character):
            let value = layout == .letters && isShifted
                ? String(character).uppercased()
                : String(character)
            manualInsert(value)
            if layout == .letters { isShifted = false }
        case .shift:
            isShifted.toggle()
        case .layoutToggle:
            layout = layout == .numbers ? .symbols : .numbers
        case .delete:
            break
        }
    }

    private func appendSwipePoint(_ point: CGPoint) {
        if let last = swipePoints.last, hypot(point.x - last.x, point.y - last.y) < 3 {
            return
        }
        swipePoints.append(point)
        if let letter = letterKey(at: point), letter != swipeKeys.last {
            swipeKeys.append(letter)
        }
    }

    private func commitSwipe() {
        guard let word = SwipeWordDecoder.shared.decode(keys: swipeKeys) else {
            KeyboardHaptics.swipeFailed()
            return
        }
        var text = isShifted ? word.prefix(1).uppercased() + word.dropFirst() : word
        if let before = context().0, let lastCharacter = before.last,
           needsLeadingSpace(after: lastCharacter) {
            text = " " + text
        }
        manualInsert(text)
        isShifted = false
        KeyboardHaptics.swipeCommit()
    }

    private func needsLeadingSpace(after character: Character) -> Bool {
        if character.isWhitespace { return false }
        return !"([{\"'“‘@#$/_-–—".contains(character)
    }

    private func key(at point: CGPoint) -> KeyID? {
        if let hit = keyFrames.first(where: { $0.value.contains(point) }) {
            return hit.key
        }
        let nearest = keyFrames.min { lhs, rhs in
            distance(from: lhs.value, to: point) < distance(from: rhs.value, to: point)
        }
        guard let nearest, distance(from: nearest.value, to: point) < 30 else { return nil }
        return nearest.key
    }

    private func letterKey(at point: CGPoint) -> Character? {
        guard layout == .letters else { return nil }
        var best: (letter: Character, distance: CGFloat)?
        for (id, frame) in keyFrames {
            guard case .character(let character) = id, character.isLetter else { continue }
            let d = distance(from: frame, to: point)
            if best == nil || d < best!.distance {
                best = (character, d)
            }
        }
        guard let best, best.distance < 40 else { return nil }
        return best.letter
    }

    private func distance(from frame: CGRect, to point: CGPoint) -> CGFloat {
        hypot(frame.midX - point.x, frame.midY - point.y)
    }

    // MARK: - Text mutation

    private func manualInsert(_ text: String) {
        lastInsertedText = nil
        insertText(text)
    }

    private func manualDelete() {
        lastInsertedText = nil
        deleteBackward()
    }

    private func deleteWordBackward() {
        lastInsertedText = nil
        let before = context().0 ?? ""
        var count = 0
        var index = before.endIndex
        while index > before.startIndex {
            let previous = before.index(before: index)
            guard before[previous].isWhitespace else { break }
            count += 1
            index = previous
        }
        while index > before.startIndex {
            let previous = before.index(before: index)
            guard !before[previous].isWhitespace else { break }
            count += 1
            index = previous
        }
        for _ in 0..<max(count, 1) {
            deleteBackward()
        }
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

    // MARK: - Dictation bar

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
                Image(systemName: state.sessionAlive ? "mic.badge.plus" : "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(hasFullAccess
                     ? (state.sessionAlive ? "Session live — instant dictation" : "On-device dictation")
                     : "Full Access required")
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
        if state.sessionAlive {
            state.beginRemoteStart()
        } else {
            state.beginRecordingHandoff()
            openScribe(path: "dictate")
        }
    }

    private func retryOrBeginDictation() {
        guard hasFullAccess else {
            state.showFullAccessError()
            return
        }

        if state.retryAvailable {
            if state.sessionAlive {
                state.beginRetryRemote()
            } else {
                state.beginRetryHandoff()
                openScribe(path: "retry")
            }
        } else {
            beginDictation()
        }
    }

    private func openScribe(path: String) {
        guard let url = URL(string: "scribe://\(path)") else {
            state.handoffDidFail()
            return
        }

        // SwiftUI's OpenURLAction is the only URL-opening mechanism that
        // still works from keyboard extensions on iOS 18+. The legacy
        // responder-chain / extensionContext paths remain as fallbacks for
        // older systems.
        openURL(url) { accepted in
            guard !accepted else { return }
            openContainingApp(url) { success in
                Task { @MainActor in
                    if !success { state.handoffDidFail() }
                }
            }
        }
    }
}

private struct KeyFramesKey: PreferenceKey {
    static let defaultValue: [KeyID: CGRect] = [:]

    static func reduce(value: inout [KeyID: CGRect], nextValue: () -> [KeyID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct SwipeTrailShape: Shape {
    var points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }
}

private struct HapticKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.08 : 0)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { KeyboardHaptics.keyDown() }
            }
    }
}

private struct ListeningWaveform: View {
    let level: Double

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<11, id: \.self) { index in
                let centerDistance = abs(Double(index) - 5) / 5
                let height = 8 + level * (34 * (1 - centerDistance) + 6)
                Capsule()
                    .fill(.primary)
                    .frame(width: 5, height: height)
            }
        }
        .frame(height: 48)
        .animation(.easeOut(duration: 0.1), value: level)
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
    @Published private(set) var sessionAlive = false
    @Published var handoffFallbackNeeded = false

    private let store = SharedDictationStore()
    private var timer: Timer?
    private var lastResultID = ""
    private var onTranscript: ((String) -> Void)?
    private var remoteStartIssuedAt: Date?

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

    /// Starts dictation through the live flow session — the backgrounded app
    /// picks the command up from the shared store, so no app switch happens.
    func beginRemoteStart() {
        store.issue(.start)
        store.phase = .preparing
        store.message = "Starting the mic…"
        remoteStartIssuedAt = Date()
        refresh()
    }

    func beginRetryHandoff() {
        store.issue(.retry)
        store.phase = .preparing
        store.message = "Retrying saved recording…"
        refresh()
    }

    func beginRetryRemote() {
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

    /// Cancels an in-flight dictation: tells the app to drop the recording
    /// and returns the keyboard to typing.
    func cancelDictation() {
        store.issue(.cancel)
        store.phase = .idle
        store.message = ""
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
        let alive = store.isSessionAlive
        if alive != sessionAlive { sessionAlive = alive }

        // If a session-based start went unanswered, the session died without
        // the keyboard noticing — fall back to opening the app.
        if let issuedAt = remoteStartIssuedAt {
            if phase == .recording {
                remoteStartIssuedAt = nil
            } else if Date().timeIntervalSince(issuedAt) > 4 {
                remoteStartIssuedAt = nil
                handoffFallbackNeeded = true
            }
        }

        let age = Date().timeIntervalSince(store.updatedAt)
        let heartbeatAge = Date().timeIntervalSince(store.sessionHeartbeat)
        let isStale = switch phase {
        case .recording: age > 10
        // If the app were launching it would update the store within a
        // couple of seconds, so a stale .launching means the open failed.
        case .launching: age > 12
        // With a session, a dead heartbeat means the app was killed mid-work.
        case .preparing, .transcribing: age > 300 || (store.sessionActive && heartbeatAge > 10)
        case .idle, .completed, .failed: false
        }
        if isStale {
            let failureMessage = phase == .launching
                ? "Scribe couldn’t open. Tap Retry."
                : "Scribe stopped responding. Tap Retry to reconnect."
            store.fail(failureMessage, retryAvailable: retryAvailable)
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
