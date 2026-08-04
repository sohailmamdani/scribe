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
    @ObservedObject var documentState: KeyboardDocumentState
    let insertText: (String) -> Void
    let deleteBackward: () -> Void
    let advanceInputMode: () -> Void
    let context: () -> (String?, String?)
    let fieldKind: () -> KeyboardFieldKind
    let capitalizationMode: () -> KeyboardCapitalizationMode
    let openContainingApp: (URL, @escaping (Bool) -> Void) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var state = KeyboardDictationState()
    @StateObject private var deleteRepeater = KeyRepeatEngine()
    @State private var shiftState: KeyboardShiftState = .once
    @State private var layout: KeyboardLayout = .letters
    @State private var lastInsertedText: String?
    @State private var lastSpaceTapAt: Date?
    @State private var lastShiftTapAt: Date?
    @State private var observedFieldKind: KeyboardFieldKind?

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

    private var usesCompactMetrics: Bool { verticalSizeClass == .compact }
    private var keyGap: CGFloat { usesCompactMetrics ? 4 : 7 }
    private var letterKeyHeight: CGFloat { usesCompactMetrics ? 32 : 40 }
    private var numberKeyHeight: CGFloat { usesCompactMetrics ? 28 : 34 }
    private var bottomKeyHeight: CGFloat { usesCompactMetrics ? 32 : 40 }
    private var dictationBarHeight: CGFloat { usesCompactMetrics ? 38 : 46 }

    var body: some View {
        Group {
            if state.phase == .recording || state.phase == .transcribing {
                listeningPanel
            } else {
                VStack(spacing: keyGap) {
                    dictationBar
                    keyArea
                    HStack(spacing: keyGap) {
                        if documentState.needsInputModeSwitchKey {
                            bottomKey(systemName: "globe", width: 44) { advanceInputMode() }
                        }
                        bottomKey(title: layout == .letters ? "123" : "ABC", width: 48) {
                            layout = layout == .letters ? .numbers : .letters
                            if layout == .letters { refreshAutomaticShift() }
                        }
                        bottomKey(title: "space", width: nil) { spaceTapped() }
                        bottomKey(systemName: "return", width: 52) {
                            manualInsert("\n")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.top, usesCompactMetrics ? 3 : 5)
        .padding(.bottom, usesCompactMetrics ? 2 : 4)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGray5))
        .onAppear {
            synchronizeDocumentState()
            state.start { transcript in
                let surrounding = context()
                let insertion = TranscriptPolisher.textForInsertion(
                    transcript,
                    contextBefore: surrounding.0,
                    contextAfter: surrounding.1
                )
                insertText(insertion)
                lastInsertedText = insertion
                refreshAutomaticShift()
            }
        }
        .onChange(of: documentState.textRevision) { _, _ in
            synchronizeDocumentState()
        }
        .onChange(of: documentState.selectionRevision) { _, _ in
            lastSpaceTapAt = nil
            synchronizeDocumentState()
        }
        .onDisappear {
            state.stop()
            cancelActiveTouch()
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
                if documentState.needsInputModeSwitchKey {
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
        VStack(spacing: keyGap) {
            characterRow(Array("1234567890"), keyHeight: numberKeyHeight, fontSize: 17)
            characterRow(activeRows[0], keyHeight: letterKeyHeight)
            characterRow(activeRows[1], keyHeight: letterKeyHeight)
                .padding(.horizontal, 14)
            HStack(spacing: keyGap) {
                if layout == .letters {
                    keyCap(
                        id: .shift,
                        width: 44,
                        height: letterKeyHeight,
                        emphasized: shiftState.usesUppercase
                    ) {
                        Image(systemName: shiftState == .locked ? "capslock.fill" : "shift.fill")
                            .font(.system(size: 17, weight: .medium))
                    }
                } else {
                    keyCap(id: .layoutToggle, width: 44, height: letterKeyHeight) {
                        Text(layout == .numbers ? "#+=" : "123")
                            .font(.system(size: 15))
                    }
                }
                characterRow(activeRows[2], keyHeight: letterKeyHeight)
                keyCap(id: .delete, width: 44, height: letterKeyHeight) {
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
            [Array("-/:;()$&@\""), Array(".,?!'…"), Array("_\\|~<>€£¥")]
        case .symbols:
            [Array("[]{}#%^*+="), Array("_\\|~<>€£¥"), Array(".,?!'…")]
        }
    }

    private func characterRow(
        _ characters: [Character],
        keyHeight: CGFloat = 40,
        fontSize: CGFloat = 21
    ) -> some View {
        HStack(spacing: keyGap) {
            ForEach(characters, id: \.self) { character in
                let display = layout == .letters && shiftState.usesUppercase && character.isLetter
                    ? String(character).uppercased()
                    : String(character)
                keyCap(
                    id: .character(character),
                    width: nil,
                    height: keyHeight,
                    isCharacterKey: true
                ) {
                    Text(display)
                        .font(.system(size: fontSize))
                }
            }
        }
    }

    private func keyCap<Label: View>(
        id: KeyID,
        width: CGFloat?,
        height: CGFloat = 40,
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
            .frame(width: width, height: height)
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
            .accessibilityElement()
            .accessibilityLabel(Text(accessibilityLabel(for: id)))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activateFromAccessibility(id) }
    }

    private func accessibilityLabel(for id: KeyID) -> String {
        switch id {
        case .character(let character):
            return String(character)
        case .shift:
            return shiftState == .locked ? "Caps Lock" : "Shift"
        case .delete:
            return "Delete"
        case .layoutToggle:
            return layout == .numbers ? "More Symbols" : "Numbers"
        }
    }

    private func activateFromAccessibility(_ id: KeyID) {
        KeyboardHaptics.keyDown()
        if id == .delete {
            manualDelete()
        } else {
            commitKey(id)
        }
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
            .frame(width: width, height: bottomKeyHeight)
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
           hypot(point.x - start.x, point.y - start.y) > 24,
           let current = letterKey(at: point),
           current != character {
            isSwiping = true
            swipePoints = [start, point]
            swipeKeys = [character, current]
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
            if Set(swipeKeys).count >= 2 {
                commitSwipe()
            } else if let startKey {
                commitKey(startKey)
            }
            return
        }

        guard let startKey, let endingKey = key(at: point) else { return }
        if startKey == .delete { return }

        switch startKey {
        case .character:
            // Small drifts within the row are still the original key tap. A
            // real slide only begins after entering a second distinct letter.
            commitKey(startKey)
        case .shift, .layoutToggle:
            guard endingKey == startKey else { return }
            commitKey(startKey)
        case .delete:
            break
        }
    }

    private func cancelActiveTouch() {
        deleteRepeater.stop()
        touchStart = nil
        startKey = nil
        pressedKey = nil
        isSwiping = false
        swipePoints = []
        swipeKeys = []
    }

    private func commitKey(_ key: KeyID) {
        switch key {
        case .character(let character):
            let value = layout == .letters && shiftState.usesUppercase && character.isLetter
                ? String(character).uppercased()
                : String(character)
            manualInsert(value)
            if layout == .letters, character.isLetter, shiftState == .once {
                shiftState = .off
            }
        case .shift:
            let now = Date()
            if let lastShiftTapAt,
               now.timeIntervalSince(lastShiftTapAt) <= 0.35 {
                shiftState = .locked
                self.lastShiftTapAt = nil
            } else {
                shiftState = shiftState == .off ? .once : .off
                lastShiftTapAt = now
            }
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
        var text = shiftState.usesUppercase ? word.prefix(1).uppercased() + word.dropFirst() : word
        if let before = context().0, let lastCharacter = before.last,
           needsLeadingSpace(after: lastCharacter) {
            text = " " + text
        }
        manualInsert(text)
        if shiftState == .once { shiftState = .off }
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

    private func manualInsert(_ text: String, resetsSpaceTap: Bool = true) {
        lastInsertedText = nil
        if resetsSpaceTap { lastSpaceTapAt = nil }
        insertText(text)
        refreshAutomaticShift()
    }

    private func spaceTapped() {
        let now = Date()
        let elapsed = lastSpaceTapAt.map { now.timeIntervalSince($0) }
        let before = context().0

        if KeyboardEditingRules.shouldConvertDoubleSpace(
            contextBefore: before,
            elapsedSincePreviousSpace: elapsed,
            fieldKind: fieldKind()
        ) {
            deleteBackward()
            insertText(". ")
            lastInsertedText = nil
            lastSpaceTapAt = nil
            refreshAutomaticShift()
        } else {
            manualInsert(" ", resetsSpaceTap: false)
            lastSpaceTapAt = now
        }
    }

    private func manualDelete() {
        lastInsertedText = nil
        lastSpaceTapAt = nil
        deleteBackward()
        refreshAutomaticShift()
    }

    private func synchronizeDocumentState() {
        let currentFieldKind = fieldKind()
        if observedFieldKind != currentFieldKind {
            let previousFieldKind = observedFieldKind
            observedFieldKind = currentFieldKind
            if currentFieldKind == .number || currentFieldKind == .phone {
                layout = .numbers
            } else if previousFieldKind == .number || previousFieldKind == .phone {
                layout = .letters
            }
        }
        refreshAutomaticShift()
    }

    private func refreshAutomaticShift() {
        guard layout == .letters, shiftState != .locked else { return }
        shiftState = KeyboardEditingRules.automaticShiftState(
            contextBefore: context().0,
            capitalization: capitalizationMode()
        )
    }

    private func deleteWordBackward() {
        lastInsertedText = nil
        lastSpaceTapAt = nil
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
        refreshAutomaticShift()
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
        refreshAutomaticShift()
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
                Text(documentState.hasFullAccess
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
        .frame(height: dictationBarHeight)
        .background(.background, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func beginDictation() {
        guard documentState.hasFullAccess else {
            state.showFullAccessError()
            return
        }
        lastInsertedText = nil
        let sessionWasAlive = state.sessionAlive
        guard state.beginStart() else { return }
        if !sessionWasAlive { openScribe() }
    }

    private func retryOrBeginDictation() {
        guard documentState.hasFullAccess else {
            state.showFullAccessError()
            return
        }

        if state.retryAvailable {
            let sessionWasAlive = state.sessionAlive
            guard state.beginRetry() else { return }
            if !sessionWasAlive { openScribe() }
        } else {
            beginDictation()
        }
    }

    private func openScribe() {
        guard let url = URL(string: "scribe://wake") else {
            state.handoffDidFail()
            return
        }

        // iOS does not publish a guaranteed keyboard-to-containing-app launch
        // API. Keep this as one best-effort wake attempt; durable App Group
        // state lets the request survive if the app has to be opened manually.
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

    private let store = SharedDictationStore()
    private var timer: Timer?
    private var onTranscript: ((String) -> Void)?
    private var currentRequestID: String?
    private var currentRequestIssuedAt: Date?
    private var localError: String?

    private static let acknowledgementTimeout: TimeInterval = 10
    private static let coldStartTimeout: TimeInterval = 45
    private static let transcriptionTimeout: TimeInterval = 5 * 60

    private static func inFlightTimeout(for phase: DictationPhase) -> TimeInterval {
        switch phase {
        case .preparing:
            coldStartTimeout
        case .transcribing:
            transcriptionTimeout
        case .idle, .launching, .recording, .completed, .failed:
            acknowledgementTimeout
        }
    }

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

    @discardableResult
    func beginStart() -> Bool {
        beginRequest(
            .start,
            initialPhase: sessionAlive ? .preparing : .launching,
            message: sessionAlive ? "Starting the mic…" : "Opening Scribe…"
        )
    }

    @discardableResult
    func beginRetry() -> Bool {
        beginRequest(
            .retry,
            initialPhase: sessionAlive ? .preparing : .launching,
            message: sessionAlive ? "Retrying saved recording…" : "Opening Scribe…"
        )
    }

    func handoffDidFail() {
        localError = "Scribe couldn’t open. Open the app once, then tap Retry."
        phase = .failed
        message = localError ?? ""
    }

    func cancelHandoff() {
        _ = beginRequest(.cancel, initialPhase: .idle, message: "")
        currentRequestID = nil
        currentRequestIssuedAt = nil
        phase = .idle
        message = ""
    }

    func cancelDictation() {
        _ = beginRequest(.cancel, initialPhase: .idle, message: "")
        currentRequestID = nil
        currentRequestIssuedAt = nil
        phase = .idle
        message = ""
    }

    func stopRecording() {
        _ = beginRequest(.stop, initialPhase: .transcribing, message: "Polishing your words…")
    }

    func showFullAccessError() {
        localError = "Enable Full Access in Settings to connect the keyboard to Scribe."
        phase = .failed
        message = localError ?? ""
    }

    private func refresh() {
        guard store.isAvailable else {
            phase = .failed
            message = "Scribe’s shared container is unavailable. Reopen Scribe and try again."
            retryAvailable = false
            sessionAlive = false
            return
        }

        let status = store.status
        let session = store.session
        sessionAlive = session.isAlive()
        audioLevel = store.audioLevel

        let recoverableResultRequestID = currentRequestID ?? store.latestRequest?.id
        if let claimed = store.claimTranscript(for: recoverableResultRequestID) {
            onTranscript?(claimed.text)
            currentRequestID = nil
            currentRequestIssuedAt = nil
            localError = nil
            phase = .idle
            message = ""
            retryAvailable = false
            return
        }

        if let currentRequestID {
            if status.requestID == currentRequestID {
                let age = Date().timeIntervalSince(status.updatedAt)
                let timeout = Self.inFlightTimeout(for: status.phase)
                if status.isInFlight, !sessionAlive, age > timeout {
                    phase = .failed
                    message = "Scribe stopped before finishing. Tap Retry to reconnect."
                    retryAvailable = status.retryAvailable
                    return
                }
                localError = nil
                apply(status)
                return
            }

            if let currentRequestIssuedAt,
               Date().timeIntervalSince(currentRequestIssuedAt) > Self.acknowledgementTimeout {
                phase = .failed
                message = sessionAlive
                    ? "The session stopped responding. Tap Retry to reconnect."
                    : "Open Scribe once to start a session, then return and tap Retry."
                retryAvailable = false
            }
			if let localError {
				phase = .failed
				message = localError
			}
            return
        }

		if let localError {
			phase = .failed
			message = localError
			return
		}

        // When iOS recreates the extension, recover the app-owned in-flight
        // state instead of assuming the old keyboard process is still alive.
        if status.isInFlight {
            let age = Date().timeIntervalSince(status.updatedAt)
            let timeout = Self.inFlightTimeout(for: status.phase)
            if !sessionAlive, age > timeout {
                phase = .failed
                message = "Scribe stopped before finishing. Tap Retry to reconnect."
                retryAvailable = status.retryAvailable
            } else if age < 15 * 60 {
                apply(status)
            }
        } else if status.phase == .failed {
            let age = Date().timeIntervalSince(status.updatedAt)
            let matchesLatestRequest = status.requestID == store.latestRequest?.id
            if matchesLatestRequest,
               status.retryAvailable || (-60...15 * 60).contains(age) {
                apply(status)
            }
        } else if status.phase == .completed, store.isResultConsumed(status.resultID) {
            phase = .idle
            message = ""
            retryAvailable = false
        } else if status.phase == .idle {
            phase = .idle
            message = ""
            retryAvailable = false
        }
    }

    @discardableResult
    private func beginRequest(
        _ command: DictationCommand,
        initialPhase: DictationPhase,
        message: String
    ) -> Bool {
        localError = nil
        guard let request = store.issue(command) else {
            phase = .failed
            self.message = "Scribe’s shared container is unavailable. Reopen Scribe and try again."
            return false
        }
        currentRequestID = request.id
        currentRequestIssuedAt = request.issuedAt
        phase = initialPhase
        self.message = message
        retryAvailable = false
        return true
    }

    private func apply(_ status: DictationStatus) {
        if status.phase == .completed, store.isResultConsumed(status.resultID) {
            phase = .idle
            message = ""
            retryAvailable = false
            currentRequestID = nil
            currentRequestIssuedAt = nil
            return
        }
        phase = status.phase
        message = status.message
        retryAvailable = status.retryAvailable
    }

    @objc private func refreshFromTimer() {
        refresh()
    }
}
