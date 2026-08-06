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
    let adjustTextPosition: (Int) -> Void
    let advanceInputMode: () -> Void
    let context: () -> (String?, String?)
    let fieldKind: () -> KeyboardFieldKind
    let capitalizationMode: () -> KeyboardCapitalizationMode
    let autocorrectionEnabled: () -> Bool
    let correctionsForWord: (String, String?, [KeyboardTapEvidence]) async -> [KeyboardCorrection]
    let recordAcceptedCorrection: (String, String) -> Void
    let recordRejectedCorrection: (String, String) -> Void
    let openContainingApp: (URL, @escaping (Bool) -> Void) -> Void
    let clientDocumentID: () -> String?
    let hostIsForegroundActive: () -> Bool

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
	@State private var correctionCandidates: [KeyboardCorrection] = []
	@State private var appliedCorrection: AppliedCorrection?
	@State private var localMutationGraceDeadline = Date.distantPast
	/// Corrections are computed off the main thread, so the delimiter path reads
	/// this precomputed answer instead of blocking to produce one.
	@State private var pendingCorrection: PendingCorrection?
	@State private var correctionTask: Task<Void, Never>?
	/// Immediate apostrophe restoration must still honor an undo before the
	/// actor has persisted it to defaults.
	@State private var sessionRejectedAutocorrectionWords: Set<String> = []
	/// Where the finger actually landed for each character of the word being
	/// typed, feeding spatial scoring in the correction engine.
	@State private var tapEvidence: [KeyboardTapEvidence] = []

    // Unified touch handling over the key area: frames are collected per key
    // so one cancellable touch surface can drive taps, delete repeat, and swipes.
    @State private var keyFrames: [KeyID: CGRect] = [:]
    /// Gap-free touch regions derived from `keyFrames`. Hit-testing uses these;
    /// `keyFrames` remains the visual truth for drawing and gesture geometry.
    @State private var hitRegions: [KeyID: CGRect] = [:]
    @State private var keyAreaBounds: CGRect = .zero
    @State private var pressedKey: KeyID?
    @State private var touchStart: CGPoint?
    @State private var startKey: KeyID?
    @State private var touchMode: TouchMode = .idle
    @State private var alternateHoldTask: Task<Void, Never>?
    @State private var swipePoints: [CGPoint] = []
    @State private var swipeKeys: [Character] = []
    @State private var spaceGestureIsActive = false
    @State private var spaceIsPressed = false
    @State private var spaceCursorMode = false
    @State private var spaceCursorStep = 0
    @State private var spaceTouchStartX: CGFloat?
    @State private var spaceHoldTask: Task<Void, Never>?
    @State private var dictationWakeFallbackTask: Task<Void, Never>?

    private static let keySpace = "keyArea"

    private enum KeyboardLayout {
        case letters
        case numbers
        case symbols
    }

    private enum TouchMode: Equatable {
        case idle
        case pressed
        case control
        case deleting
        case alternatePreview(Character)
        case alternateCommitted(Character)
        case alternatePalette(Character)
        case swiping
    }

    private struct AppliedCorrection: Equatable {
        let original: String
        let replacement: String
        let suffix: String
    }

    private struct PendingCorrection: Equatable {
        let word: String
        let candidates: [KeyboardCorrection]
    }

    private var usesCompactMetrics: Bool { verticalSizeClass == .compact }
    private var geometry: KeyboardGeometryRules {
        usesCompactMetrics ? .compact : .portrait
    }
    private var horizontalGap: CGFloat { geometry.horizontalGap }
    private var verticalGap: CGFloat { geometry.verticalGap }
    private var keyHeight: CGFloat { geometry.keyHeight }
    private var outerInset: CGFloat { geometry.outerInset }
    private var dictationBarHeight: CGFloat { geometry.toolbarHeight }

    var body: some View {
        Group {
            if state.phase == .recording || state.phase == .transcribing {
                listeningPanel
            } else {
                VStack(spacing: 0) {
                    dictationBar
                    VStack(spacing: verticalGap) {
                        keyArea
                            .opacity(spaceCursorMode ? 0.16 : 1)
                        bottomRow
                    }
                    .padding(.top, geometry.toolbarToKeyGap)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGray5))
        .animation(.easeOut(duration: 0.14), value: spaceCursorMode)
        .onAppear {
            synchronizeDocumentState()
            state.start(
                onTranscript: { transcript in
                    let surrounding = context()
                    let insertion = TranscriptPolisher.textForInsertion(
                        transcript,
                        contextBefore: surrounding.0,
                        contextAfter: surrounding.1
                    )
                    proxyInsertText(insertion)
                    lastInsertedText = insertion
                    // Dictated text arrives with no taps behind it.
                    tapEvidence = []
                    refreshAutomaticShift()
                },
                clientDocumentID: clientDocumentID,
                hostIsActive: hostIsForegroundActive
            )
        }
        .onChange(of: documentState.textRevision) { _, _ in
            synchronizeDocumentState()
        }
        .onChange(of: documentState.selectionRevision) { _, _ in
			// UITextDocumentProxy edits move the caret too. Do not interpret those
			// callbacks as an external selection change: doing so cancels delete
			// repeat and erases the first-space timestamp before a double-space.
			if Date() > localMutationGraceDeadline {
				lastSpaceTapAt = nil
				// The caret moved for a reason the keyboard did not cause, so
				// the recorded taps no longer describe the word at the caret.
				tapEvidence = []
				cancelActiveTouch()
			}
            synchronizeDocumentState()
        }
        .onDisappear {
            state.stop()
            dictationWakeFallbackTask?.cancel()
            dictationWakeFallbackTask = nil
            correctionTask?.cancel()
            correctionTask = nil
            cancelActiveTouch()
            cancelSpaceGesture()
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
        GeometryReader { proxy in
            let totalWidth = Double(proxy.size.width)
            let characterWidth = CGFloat(geometry.tenColumnKeyWidth(totalWidth: totalWidth))
            let homeInset = CGFloat(geometry.homeRowInset(totalWidth: totalWidth))
            let controlGap = CGFloat(geometry.controlToLetterGap(totalWidth: totalWidth))
            let controlWidth = CGFloat(geometry.controlWidth(totalWidth: totalWidth))
			let thirdRowCharacters = activeRows[2]
			let fittedThirdRowWidth = CGFloat(
				geometry.fittedControlRowKeyWidth(
					totalWidth: totalWidth,
					characterCount: thirdRowCharacters.count
				)
			)

            VStack(spacing: verticalGap) {
                characterRow(activeRows[0], width: characterWidth)
                characterRow(activeRows[1], width: characterWidth)
                    .padding(.horizontal, homeInset)
				if layout == .letters {
					HStack(spacing: 0) {
						keyCap(
							id: .shift,
							width: controlWidth,
							height: keyHeight,
							emphasized: shiftState.usesUppercase
						) {
							Image(systemName: shiftState == .locked ? "capslock.fill" : "shift.fill")
								.font(.system(size: 18, weight: .medium))
						}
						Spacer().frame(width: controlGap)
						characterRow(thirdRowCharacters, width: characterWidth)
						Spacer().frame(width: controlGap)
						keyCap(id: .delete, width: controlWidth, height: keyHeight) {
							Image(systemName: "delete.left.fill")
								.font(.system(size: 18, weight: .medium))
						}
					}
				} else {
					HStack(spacing: horizontalGap) {
						keyCap(id: .layoutToggle, width: controlWidth, height: keyHeight) {
							Text(layout == .numbers ? "#+=" : "123")
								.font(.system(size: 15))
						}
						characterRow(thirdRowCharacters, width: fittedThirdRowWidth)
						keyCap(id: .delete, width: controlWidth, height: keyHeight) {
							Image(systemName: "delete.left.fill")
								.font(.system(size: 18, weight: .medium))
						}
					}
				}
            }
            .padding(.horizontal, outerInset)
            .preference(
                key: KeyAreaBoundsKey.self,
                value: CGRect(origin: .zero, size: proxy.size)
            )
        }
        .frame(height: 3 * keyHeight + 2 * verticalGap)
        .coordinateSpace(name: Self.keySpace)
        .onPreferenceChange(KeyFramesKey.self) { frames in
            keyFrames = frames
            updateHitRegions()
        }
        .onPreferenceChange(KeyAreaBoundsKey.self) { bounds in
            keyAreaBounds = bounds
            updateHitRegions()
        }
        .contentShape(Rectangle())
        .overlay {
            KeyboardTouchSurface(
                onBegan: touchBegan,
                onMoved: touchMoved,
                onEnded: touchEnded,
                onCancelled: cancelActiveTouch
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            SwipeTrailShape(points: swipePoints)
                .stroke(
                    Color.indigo.opacity(0.55),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
                )
                .opacity(touchMode == .swiping ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) { keyPreview }
    }

    private func updateHitRegions() {
        hitRegions = KeyboardHitGrid.regions(
            forFrames: keyFrames,
            in: keyAreaBounds
        )
    }

    // MARK: - Key preview
    //
    // The enlarged glyph above the finger is the feedback loop that lets a
    // typist notice and correct a slip before lifting off. Without it a custom
    // keyboard reads as imprecise even when the hit-testing is exact.

    @ViewBuilder
    private var keyPreview: some View {
        if let previewedKey, let frame = keyFrames[previewedKey] {
            let width = frame.width * 1.42
            let height = keyHeight * 1.34
            let minX = keyAreaBounds.minX
            let maxX = max(minX, keyAreaBounds.maxX - width)
            let x = min(max(frame.midX - width / 2, minX), maxX)

            Text(previewedGlyph)
                .font(.system(size: 30))
                .foregroundStyle(.primary)
                .frame(width: width, height: height)
                .background(
                    Color(.systemBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
                .offset(x: x, y: frame.minY - height - 5)
                .allowsHitTesting(false)
                .transaction { $0.animation = nil }
        }
    }

    /// Only character keys preview, matching iOS — controls stay quiet, and
    /// landscape suppresses the popup because there is no room above the row.
    /// It tracks the key the touch began on, which is the key that commits.
    private var previewedKey: KeyID? {
        guard !usesCompactMetrics,
              let startKey,
              case .character = startKey else { return nil }
        switch touchMode {
        case .pressed, .alternatePreview, .alternateCommitted, .alternatePalette:
            return startKey
        case .idle, .control, .deleting, .swiping:
            return nil
        }
    }

    private var previewedGlyph: String {
        guard case .character(let character)? = previewedKey else { return "" }
        switch touchMode {
        case .alternatePreview(let alternate),
             .alternateCommitted(let alternate),
             .alternatePalette(let alternate):
            return String(alternate)
        case .idle, .pressed, .control, .deleting, .swiping:
            return layout == .letters && shiftState.usesUppercase && character.isLetter
                ? String(character).uppercased()
                : String(character)
        }
    }

    private var bottomRow: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width - 2 * outerInset
            let standardControlWidth = min(102, max(78, availableWidth * 0.24))
            let modeWidth = documentState.needsInputModeSwitchKey ? CGFloat(72) : standardControlWidth
            let returnWidth = documentState.needsInputModeSwitchKey ? CGFloat(78) : standardControlWidth

            HStack(spacing: horizontalGap) {
                if documentState.needsInputModeSwitchKey {
                    bottomKey(systemName: "globe", width: 45) { advanceInputMode() }
                }
                bottomKey(title: layout == .letters ? "123" : "ABC", width: modeWidth) {
                    cancelActiveTouch()
                    layout = layout == .letters ? .numbers : .letters
                    if layout == .letters { refreshAutomaticShift() }
                }
                spaceKey
                bottomKey(systemName: "return", width: returnWidth) {
                    insertDelimiter("\n")
                }
            }
            .padding(.horizontal, outerInset)
        }
        .frame(height: keyHeight)
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
        width: CGFloat,
        fontSize: CGFloat = 22
    ) -> some View {
        HStack(spacing: horizontalGap) {
            ForEach(characters, id: \.self) { character in
                let display = layout == .letters && shiftState.usesUppercase && character.isLetter
                    ? String(character).uppercased()
                    : String(character)
                let alternate = alternateSymbol(for: character)
                let showsAlternate = isPreviewingAlternate(for: character)
                keyCap(
                    id: .character(character),
                    width: width,
                    height: keyHeight,
                    isCharacterKey: true,
                    alternate: alternate
                ) {
                    ZStack(alignment: .topLeading) {
                        Text(showsAlternate ? alternate.map(String.init) ?? display : display)
                            .font(.system(size: fontSize))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let alternate {
                            Text(showsAlternate ? display : String(alternate))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 5)
                                .padding(.top, 3)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyCap<Label: View>(
        id: KeyID,
        width: CGFloat?,
        height: CGFloat = 40,
        emphasized: Bool = false,
        isCharacterKey: Bool = false,
        alternate: Character? = nil,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let isPressed = pressedKey == id
        let baseColor: Color = isCharacterKey || emphasized
            ? Color(.systemBackground)
            : Color(.systemGray3)
        let key = label()
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

        if let alternate {
            let spokenAlternate = KeyboardAlternateSymbols.spokenName(for: alternate)
            key
                .accessibilityHint(Text("Swipe down for \(spokenAlternate)."))
                .accessibilityAction(named: Text("Insert \(spokenAlternate)")) {
                    commitAlternate(alternate, from: id)
                }
        } else {
            key
        }
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

    private func alternateSymbol(for character: Character) -> Character? {
        if character.isNumber {
            return KeyboardAlternateSymbols.alternate(for: character)
        }
        guard layout == .letters, character.isLetter else { return nil }
        return KeyboardAlternateSymbols.alternate(for: character)
    }

    private func isPreviewingAlternate(for character: Character) -> Bool {
        guard startKey == .character(character) else { return false }
        switch touchMode {
        case .alternatePreview, .alternateCommitted, .alternatePalette:
            return true
        case .idle, .pressed, .control, .deleting, .swiping:
            return false
        }
    }

    private var characterKeyWidth: CGFloat {
        if let startKey, let frame = keyFrames[startKey] {
            return frame.width
        }
        return geometry.tenColumnKeyWidth(totalWidth: Double(UIScreen.main.bounds.width))
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
            .frame(width: width, height: keyHeight)
            .background(Color(.systemGray3), in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.16), radius: 0, y: 1)
        }
        .buttonStyle(HapticKeyStyle())
    }

    private var spaceKey: some View {
        Text(spaceCursorMode ? "Move cursor" : "space")
            .font(.system(size: 15, weight: spaceCursorMode ? .semibold : .regular))
            .foregroundStyle(spaceCursorMode ? Color.indigo : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: keyHeight)
            .background(
                spaceIsPressed ? Color(.systemGray2) : Color(.systemGray3),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .shadow(color: .black.opacity(0.16), radius: 0, y: 1)
            .contentShape(Rectangle())
            .overlay {
                // Use the same cancellable UIKit touch path as the letter grid.
                // SwiftUI's DragGesture could lose a fast Space when the next
                // finger landed before the first one had fully lifted.
                KeyboardTouchSurface(
                    onBegan: beginSpaceGesture,
                    onMoved: moveSpaceGesture,
                    onEnded: endSpaceGesture,
                    onCancelled: cancelSpaceGesture
                )
            }
            .accessibilityElement()
            .accessibilityLabel("Space")
            .accessibilityHint("Touch and hold, then drag to move the cursor.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { spaceTapped() }
    }

    private func moveSpaceGesture(to point: CGPoint) {
        guard spaceGestureIsActive,
              spaceCursorMode,
              let spaceTouchStartX else { return }
        let step = KeyboardCursorRules.characterOffset(
            forHorizontalTranslation: Double(point.x - spaceTouchStartX)
        )
        let delta = step - spaceCursorStep
        guard delta != 0 else { return }
        spaceCursorStep = step
        proxyAdjustTextPosition(delta)
        KeyboardHaptics.cursorTick()
    }

    private func endSpaceGesture(at _: CGPoint) {
        guard spaceGestureIsActive else { return }
        let shouldInsertSpace = !spaceCursorMode
        cancelSpaceGesture()
        if shouldInsertSpace { spaceTapped() }
    }

    private func beginSpaceGesture(at point: CGPoint) {
        spaceGestureIsActive = true
        spaceIsPressed = true
        spaceCursorStep = 0
        spaceTouchStartX = point.x
        KeyboardHaptics.keyDown()
        spaceHoldTask?.cancel()
        spaceHoldTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled,
                  spaceGestureIsActive else { return }
            lastSpaceTapAt = nil
            lastInsertedText = nil
            spaceCursorMode = true
            KeyboardHaptics.cursorModeBegan()
        }
    }

    private func cancelSpaceGesture() {
        spaceHoldTask?.cancel()
        spaceHoldTask = nil
        spaceGestureIsActive = false
        spaceIsPressed = false
        spaceCursorMode = false
        spaceCursorStep = 0
        spaceTouchStartX = nil
    }

    // MARK: - Touch handling

    private func touchBegan(at point: CGPoint) {
        touchStart = point
        let key = key(at: point)
        startKey = key
        pressedKey = key
        guard let key else { return }
        KeyboardHaptics.keyDown()
        switch key {
        case .delete:
            touchMode = .deleting
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
        case .character(let character):
            touchMode = .pressed
            if let alternate = alternateSymbol(for: character) {
                scheduleAlternateHold(for: key, alternate: alternate)
            }
        case .shift, .layoutToggle:
            touchMode = .control
        }
    }

    private func touchMoved(to point: CGPoint) {
        guard let start = touchStart else { return }
        let deltaX = point.x - start.x
        let deltaY = point.y - start.y
        let travel = hypot(deltaX, deltaY)

        if touchMode == .swiping {
            appendSwipePoint(point)
            if let letter = letterKey(at: point) {
                pressedKey = .character(letter)
            }
            return
        }

        if travel > CGFloat(KeyboardGestureResolver.previewDistance) {
            alternateHoldTask?.cancel()
            alternateHoldTask = nil
        }

        if touchMode == .deleting {
            if key(at: point) != .delete {
                deleteRepeater.stop()
                pressedKey = nil
            }
            return
        }

        if case .alternatePalette = touchMode {
            let withinSelectionArea = abs(deltaX) <= keyHeight
                && deltaY >= -keyHeight / 2
                && deltaY <= keyHeight * 1.25
            pressedKey = withinSelectionArea ? startKey : nil
            return
        }

        if case .character(let character)? = startKey,
           let alternate = alternateSymbol(for: character) {
            let currentLetter = letterKey(at: point)
            let enteredDifferentLetter = character.isLetter
                && currentLetter != nil
                && currentLetter != Character(String(character).lowercased())
            let resolution = KeyboardGestureResolver.resolve(
                deltaX: Double(deltaX),
                deltaY: Double(deltaY),
                keyWidth: Double(characterKeyWidth),
                keyHeight: Double(keyHeight),
                enteredDifferentLetter: enteredDifferentLetter,
                alternateGestureArmed: false
            )
            switch resolution {
            case .alternatePreview:
				if case .alternateCommitted = touchMode {
					pressedKey = startKey
					return
				}
                if touchMode != .alternatePreview(alternate) {
                    KeyboardHaptics.keyDown()
                }
                touchMode = .alternatePreview(alternate)
                pressedKey = startKey
                return
			case .alternateCommit:
				if touchMode != .alternateCommitted(alternate) {
					KeyboardHaptics.keyDown()
				}
				touchMode = .alternateCommitted(alternate)
				pressedKey = startKey
				return
            case .wordSwipe:
                if character.isLetter, let currentLetter {
                    beginWordSwipe(from: character, to: currentLetter, start: start, point: point)
                    return
                }
            case .primary:
                if case .alternatePreview = touchMode {
                    touchMode = .pressed
				} else if case .alternateCommitted = touchMode {
					pressedKey = startKey
					return
                }
            }
        } else if case .character(let character)? = startKey,
                  layout == .letters,
                  character.isLetter,
                  travel >= CGFloat(KeyboardGestureResolver.swipeDistance),
                  let current = letterKey(at: point),
                  current != character {
            beginWordSwipe(from: character, to: current, start: start, point: point)
            return
        }

        switch touchMode {
        case .control:
            pressedKey = key(at: point) == startKey ? startKey : nil
        case .pressed:
            // A character key commits the key the touch began on, however far
            // the finger drifts. The highlight has to say so: following the
            // finger onto a neighbour that will not be typed is what makes a
            // deliberate press feel like a mistype.
            pressedKey = startKey
        case .idle, .deleting, .alternatePreview, .alternateCommitted,
             .alternatePalette, .swiping:
            pressedKey = key(at: point)
        }
    }

    private func touchEnded(at point: CGPoint) {
        deleteRepeater.stop()
        alternateHoldTask?.cancel()
        alternateHoldTask = nil
        let endingMode = touchMode
        defer {
            touchStart = nil
            startKey = nil
            pressedKey = nil
            touchMode = .idle
            swipePoints = []
            swipeKeys = []
        }

        if endingMode == .swiping {
            if Set(swipeKeys).count >= 2 {
                commitSwipe()
            } else if let startKey {
                commitKey(startKey, at: touchStart)
            }
            return
        }

        guard let startKey else { return }
        if endingMode == .deleting { return }

        switch endingMode {
        case .alternatePreview(let alternate):
            guard let start = touchStart else { return }
            let resolution = KeyboardGestureResolver.resolve(
                deltaX: Double(point.x - start.x),
                deltaY: Double(point.y - start.y),
                keyWidth: Double(characterKeyWidth),
                keyHeight: Double(keyHeight),
                enteredDifferentLetter: false,
                alternateGestureArmed: true
            )
            if resolution == .alternateCommit {
                commitAlternate(alternate, from: startKey)
            } else {
                commitKey(startKey)
            }
            return
		case .alternateCommitted(let alternate):
			commitAlternate(alternate, from: startKey)
			return
        case .alternatePalette(let alternate):
            guard pressedKey == startKey else { return }
            commitAlternate(alternate, from: startKey)
            return
        case .idle, .deleting, .swiping:
            return
		case .pressed:
			// A quick downward lift remains the primary key. Alternates are only
			// reachable after the deliberate hold task switches to the palette.
			break
		case .control:
            break
        }

        switch startKey {
        case .character:
            // Small drifts within the row are still the original key tap. A
            // real slide only begins after entering a second distinct letter.
            // Scoring uses the touch-down point: that is where the user aimed,
            // before any drift while lifting off.
            commitKey(startKey, at: touchStart)
        case .shift, .layoutToggle:
            guard key(at: point) == startKey else { return }
            commitKey(startKey)
        case .delete:
            break
        }
    }

    private func cancelActiveTouch() {
        deleteRepeater.stop()
        alternateHoldTask?.cancel()
        alternateHoldTask = nil
        touchStart = nil
        startKey = nil
        pressedKey = nil
        touchMode = .idle
        swipePoints = []
        swipeKeys = []
    }

    private func scheduleAlternateHold(for key: KeyID, alternate: Character) {
        alternateHoldTask?.cancel()
        alternateHoldTask = Task { @MainActor in
            try? await Task.sleep(for: KeyboardGestureResolver.alternateHoldDelay)
            guard !Task.isCancelled,
                  touchMode == .pressed,
                  startKey == key else { return }
            touchMode = .alternatePalette(alternate)
            pressedKey = key
            KeyboardHaptics.keyDown()
        }
    }

    private func beginWordSwipe(
        from first: Character,
        to current: Character,
        start: CGPoint,
        point: CGPoint
    ) {
        alternateHoldTask?.cancel()
        alternateHoldTask = nil
        touchMode = .swiping
        swipePoints = [start, point]
        swipeKeys = [Character(String(first).lowercased()), current]
        pressedKey = .character(current)
    }

    private func commitKey(_ key: KeyID, at point: CGPoint? = nil) {
        switch key {
        case .character(let character):
            let value = layout == .letters && shiftState.usesUppercase && character.isLetter
                ? String(character).uppercased()
                : String(character)
            if ".,!?;:".contains(character) {
                insertDelimiter(value)
            } else {
                manualInsert(
                    value,
                    evidence: character.isLetter
                        ? tapEvidence(for: character, at: point)
                        : nil
                )
            }
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

    private func commitAlternate(_ alternate: Character, from key: KeyID) {
        manualInsert(String(alternate))
        if case .character(let primary) = key,
           layout == .letters,
           primary.isLetter,
           shiftState == .once {
            shiftState = .off
        }
        KeyboardHaptics.swipeCommit()
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

    private var verticalTapBias: Double {
        usesCompactMetrics
            ? KeyboardHitGrid.compactVerticalTapBias
            : KeyboardHitGrid.portraitVerticalTapBias
    }

    private func key(at point: CGPoint) -> KeyID? {
        KeyboardHitGrid.key(
            at: point,
            regions: hitRegions,
            verticalTapBias: verticalTapBias
        )
    }

    private func letterKey(at point: CGPoint) -> Character? {
        guard layout == .letters,
              case .character(let character)? = key(at: point),
              character.isLetter else { return nil }
        return character
    }

    /// Records where the finger landed relative to every nearby letter, so the
    /// correction engine can tell a slip from a spelling mistake. Horizontal
    /// distance is scaled by key width and vertical by row pitch, which makes
    /// an adjacent key roughly one unit away in either direction.
    /// Returns nil when there is no touch to learn from — a VoiceOver
    /// activation, or a non-letter layout. Callers drop the trail rather than
    /// recording a blank entry, which would otherwise make every substitution
    /// at that position look implausible.
    private func tapEvidence(for character: Character, at point: CGPoint?) -> KeyboardTapEvidence? {
        guard let point, layout == .letters else { return nil }
        let rowPitch = keyHeight + verticalGap
        var normalizedDistances: [Character: Double] = [:]
        for (id, frame) in keyFrames {
            guard case .character(let other) = id, other.isLetter else { continue }
            let dx = (point.x - frame.midX) / max(frame.width, 1)
            let dy = (point.y - frame.midY) / max(rowPitch, 1)
            let normalized = Double(hypot(dx, dy))
            guard normalized <= 2 else { continue }
            normalizedDistances[other] = normalized
        }
        return KeyboardTapEvidence(
            character: character,
            normalizedDistances: normalizedDistances
        )
    }

    /// Evidence is only handed to the engine when it still lines up character
    /// for character with the word in the field. Anything that edited the text
    /// behind the keyboard's back drops it rather than misaligning it.
    private func evidence(matching word: String) -> [KeyboardTapEvidence] {
        let characters = Array(word.lowercased())
        guard tapEvidence.count == characters.count,
              zip(tapEvidence, characters).allSatisfy({ $0.character == $1 }) else {
            return []
        }
        return tapEvidence
    }

    // MARK: - Text mutation

    private func manualInsert(
        _ text: String,
        resetsSpaceTap: Bool = true,
        clearsAutocorrection: Bool = true,
        evidence newEvidence: KeyboardTapEvidence? = nil
    ) {
        lastInsertedText = nil
        if clearsAutocorrection { appliedCorrection = nil }
        if resetsSpaceTap { lastSpaceTapAt = nil }
        // A letter tap extends the evidence for the word in progress. Anything
        // else — a symbol, a swiped word, a flick alternate — has no per
        // character touch behind it, so the trail is dropped rather than
        // allowed to fall out of step with the text.
        if let newEvidence {
            tapEvidence.append(newEvidence)
        } else {
            tapEvidence = []
        }
		proxyInsertText(text)
        refreshAutomaticShift()
        scheduleCorrectionRefresh()
    }

	private func proxyInsertText(_ text: String) {
		localMutationGraceDeadline = Date().addingTimeInterval(0.25)
		insertText(text)
	}

	private func proxyDeleteBackward() {
		localMutationGraceDeadline = Date().addingTimeInterval(0.25)
		deleteBackward()
	}

    private func proxyAdjustTextPosition(_ offset: Int) {
        localMutationGraceDeadline = Date().addingTimeInterval(0.25)
        adjustTextPosition(offset)
    }

    /// Reads the correction computed in the background while the user was still
    /// typing. Common apostrophe restoration also has a synchronous fallback,
    /// so a fast `dont` + Space cannot outrun the correction actor.
    @discardableResult
    private func applyAutocorrectionIfNeeded() -> AppliedCorrection? {
        guard let word = KeyboardEditingRules.autocorrectionWord(
            contextBefore: context().0,
            fieldKind: fieldKind(),
            autocorrectionEnabled: autocorrectionEnabled()
        ) else {
            return nil
        }

        let pendingReplacement = pendingCorrection
            .flatMap { $0.word == word ? $0 : nil }?
            .candidates
            .first(where: \.automaticallyReplaces)?
            .text
        let normalizedWord = word.lowercased()
        let contractionReplacement: String?
        if sessionRejectedAutocorrectionWords.contains(normalizedWord)
            || KeyboardEditingRules.isRejectedAutocorrectionWord(normalizedWord) {
            contractionReplacement = nil
        } else {
            contractionReplacement = KeyboardEditingRules
                .preferredContraction(for: normalizedWord)
                .flatMap {
                    KeyboardEditingRules.replacement(
                        $0,
                        matchingCapitalizationOf: word
                    )
                }
        }
        guard let replacement = pendingReplacement ?? contractionReplacement else {
            return nil
        }

        for _ in word { proxyDeleteBackward() }
        proxyInsertText(replacement)
        lastInsertedText = nil
        correctionCandidates = []
        pendingCorrection = nil
        tapEvidence = []
        return AppliedCorrection(
            original: word,
            replacement: replacement,
            suffix: replacement
        )
    }

    private func insertDelimiter(_ delimiter: String, resetsSpaceTap: Bool = true) {
        let correction = applyAutocorrectionIfNeeded()
        manualInsert(
            delimiter,
            resetsSpaceTap: resetsSpaceTap,
            clearsAutocorrection: correction == nil
        )
        if let correction {
            recordAcceptedCorrection(correction.original, correction.replacement)
            appliedCorrection = AppliedCorrection(
                original: correction.original,
                replacement: correction.replacement,
                suffix: correction.replacement + delimiter
            )
        }
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
			proxyDeleteBackward()
			proxyInsertText(". ")
            lastInsertedText = nil
            appliedCorrection = nil
            lastSpaceTapAt = nil
            tapEvidence = []
            refreshAutomaticShift()
            scheduleCorrectionRefresh()
        } else {
            insertDelimiter(" ", resetsSpaceTap: false)
            lastSpaceTapAt = now
        }
    }

    private func manualDelete() {
        lastInsertedText = nil
        appliedCorrection = nil
        lastSpaceTapAt = nil
        if !tapEvidence.isEmpty { tapEvidence.removeLast() }
		proxyDeleteBackward()
        refreshAutomaticShift()
        scheduleCorrectionRefresh()
    }

    private func synchronizeDocumentState() {
        if let appliedCorrection,
           context().0?.hasSuffix(appliedCorrection.suffix) != true {
            self.appliedCorrection = nil
        }
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
        scheduleCorrectionRefresh()
    }

    private func currentAutocorrectionWord() -> String? {
        KeyboardEditingRules.autocorrectionWord(
            contextBefore: context().0,
            fieldKind: fieldKind(),
            autocorrectionEnabled: autocorrectionEnabled()
        )
    }

    private func refreshCorrectionCandidates() async {
        guard appliedCorrection == nil, let word = currentAutocorrectionWord() else {
            correctionCandidates = []
            pendingCorrection = nil
            return
        }

        let suggestions = await correctionsForWord(
            word,
            context().0,
            evidence(matching: word)
        )
        // The user keeps typing while this runs. Discard anything that no
        // longer describes the word actually in the field.
        guard currentAutocorrectionWord() == word, appliedCorrection == nil else { return }

        let mapped = suggestions.compactMap { suggestion -> KeyboardCorrection? in
            guard let replacement = KeyboardEditingRules.replacement(
                suggestion.text,
                matchingCapitalizationOf: word
            ) else { return nil }
            return KeyboardCorrection(
                text: replacement,
                automaticallyReplaces: suggestion.automaticallyReplaces,
                isCompletion: suggestion.isCompletion
            )
        }
        correctionCandidates = mapped
        pendingCorrection = PendingCorrection(word: word, candidates: mapped)
    }

    /// Debounced so a fast typist causes one lookup rather than one per key,
    /// and cancellable so an in-flight lookup for a stale word is abandoned.
    private func scheduleCorrectionRefresh() {
        correctionTask?.cancel()
        correctionTask = Task { @MainActor in
            // Start the final-word lookup promptly enough to finish before the
            // following space. The old 20 ms debounce consumed a meaningful
            // part of the inter-key interval and made fast typing miss the
            // automatic-replacement path even while suggestions appeared.
            await Task.yield()
            guard !Task.isCancelled else { return }
            await refreshCorrectionCandidates()
        }
    }

    private func chooseCorrection(_ suggestion: KeyboardCorrection) {
        // `suggestion.text` already carries the original word's capitalization.
        guard let word = currentAutocorrectionWord(),
              case let replacement = suggestion.text,
              !replacement.isEmpty else { return }

        let acceptedText = KeyboardEditingRules.acceptedSuggestionText(replacement)
        for _ in word { proxyDeleteBackward() }
        proxyInsertText(acceptedText)
        lastInsertedText = nil
        correctionCandidates = []
        pendingCorrection = nil
        tapEvidence = []
        lastSpaceTapAt = Date()
        appliedCorrection = AppliedCorrection(
            original: word,
            replacement: replacement,
            suffix: acceptedText
        )
        recordAcceptedCorrection(word, replacement)
        refreshAutomaticShift()
        scheduleCorrectionRefresh()
        KeyboardHaptics.keyDown()
    }

    private func undoAutocorrection() {
        guard let appliedCorrection,
              let before = context().0,
              before.hasSuffix(appliedCorrection.suffix) else {
            self.appliedCorrection = nil
            return
        }
        for _ in appliedCorrection.suffix { proxyDeleteBackward() }
        let delimiter = String(appliedCorrection.suffix.dropFirst(appliedCorrection.replacement.count))
        proxyInsertText(appliedCorrection.original + delimiter)
        sessionRejectedAutocorrectionWords.insert(appliedCorrection.original.lowercased())
        recordRejectedCorrection(
            appliedCorrection.original,
            appliedCorrection.replacement
        )
        self.appliedCorrection = nil
        pendingCorrection = nil
        tapEvidence = []
        scheduleCorrectionRefresh()
        KeyboardHaptics.keyDown()
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
        tapEvidence = []
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
			proxyDeleteBackward()
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
			proxyDeleteBackward()
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
                if let appliedCorrection {
                    Button { undoAutocorrection() } label: {
                        Label(appliedCorrection.original, systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Undo autocorrection to \(appliedCorrection.original)")
                    compactDictationButton
                } else if !correctionCandidates.isEmpty {
                    ForEach(Array(correctionCandidates.prefix(3)), id: \.self) { suggestion in
                        Button(suggestion.text) { chooseCorrection(suggestion) }
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                        if suggestion != correctionCandidates.prefix(3).last {
                            Divider().frame(height: 22)
                        }
                    }
                    compactDictationButton
                } else if state.recoverableTranscriptAvailable {
                    // A dictation finished but its keyboard went away before it
                    // could insert (typically an app switch mid-dictation). Ask
                    // rather than guess: inserting into the wrong document is
                    // how transcripts used to vanish.
                    Button {
                        state.discardRecoveredTranscript()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Discard the finished dictation")
                    Button {
                        state.insertRecoveredTranscript()
                    } label: {
                        Label("Insert finished dictation", systemImage: "text.insert")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(Color.indigo.gradient, in: Capsule())
                    }
                } else {
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
        }
        .padding(.horizontal, 12)
        .frame(height: dictationBarHeight)
        .background(.background, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .padding(.horizontal, outerInset)
    }

    private var compactDictationButton: some View {
        Button { beginDictation() } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.indigo.gradient, in: Circle())
        }
        .accessibilityLabel("Dictate")
    }

    private func beginDictation() {
        guard documentState.hasFullAccess else {
            state.showFullAccessError()
            return
        }
        lastInsertedText = nil
        appliedCorrection = nil
        correctionCandidates = []
        let sessionWasAlive = state.sessionAlive
        guard state.beginStart() else { return }
        wakeScribeIfNeeded(sessionWasAlive: sessionWasAlive)
    }

    private func retryOrBeginDictation() {
        guard documentState.hasFullAccess else {
            state.showFullAccessError()
            return
        }

        if state.retryAvailable {
            let sessionWasAlive = state.sessionAlive
            guard state.beginRetry() else { return }
            wakeScribeIfNeeded(sessionWasAlive: sessionWasAlive)
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

    private func wakeScribeIfNeeded(sessionWasAlive: Bool) {
        dictationWakeFallbackTask?.cancel()
        if !sessionWasAlive {
            openScribe()
            return
        }

        // A heartbeat can outlive a process for a few seconds. The healthy app
        // polls in 400 ms and acknowledges before doing any model or audio
        // work; if that acknowledgement never arrives, foreground the app
        // instead of leaving this and every subsequently-created keyboard
        // waiting on the same dead session.
        dictationWakeFallbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled,
                  state.currentRequestNeedsWake else { return }
            openScribe()
        }
    }
}

private struct KeyFramesKey: PreferenceKey {
    static let defaultValue: [KeyID: CGRect] = [:]

    static func reduce(value: inout [KeyID: CGRect], nextValue: () -> [KeyID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct KeyAreaBoundsKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
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
    /// A finished transcript exists that this keyboard could insert but must
    /// not take automatically (see `KeyboardTranscriptDelivery`). Rendered as
    /// an explicit "Insert dictation" action.
    @Published private(set) var recoverableTranscriptAvailable = false

    private let store = SharedDictationStore()
    private var timer: Timer?
    private var onTranscript: ((String) -> Void)?
    /// The host document the keyboard is currently attached to. Supplied by
    /// the view controller; evaluated lazily on each refresh tick because the
    /// proxy's document can change under a live keyboard.
    private var clientDocumentID: (() -> String?) = { nil }
    /// Whether the host scene can actually accept `insertText` right now.
    private var hostIsActive: (() -> Bool) = { false }
    private var currentRequestID: String?
    private var currentRequestIssuedAt: Date?
    private var localError: String?

    private static let acknowledgementTimeout: TimeInterval = 10

    var currentRequestNeedsWake: Bool {
        guard let currentRequestID else { return false }
        return store.status.requestID != currentRequestID
    }

    func start(
        onTranscript: @escaping (String) -> Void,
        clientDocumentID: @escaping () -> String?,
        hostIsActive: @escaping () -> Bool
    ) {
        self.onTranscript = onTranscript
        self.clientDocumentID = clientDocumentID
        self.hostIsActive = hostIsActive
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

        let hostActive = hostIsActive()
        let autoClaimID = KeyboardTranscriptDelivery.autoClaimRequestID(
            currentRequestID: currentRequestID,
            latestRequest: store.latestRequest,
            activeDocumentID: clientDocumentID(),
            hostIsActive: hostActive
        )
        if let claimed = store.claimTranscript(for: autoClaimID) {
            deliver(claimed.text)
            return
        }
        recoverableTranscriptAvailable = KeyboardTranscriptDelivery.hasRecoverableResult(
            status: status,
            isConsumed: store.isResultConsumed(status.resultID),
            currentRequestID: currentRequestID,
            autoClaimRequestID: autoClaimID,
            hostIsActive: hostActive
        )

        if let currentRequestID {
            if status.requestID == currentRequestID {
                let age = Date().timeIntervalSince(status.updatedAt)
                let timeout = KeyboardTranscriptDelivery.inFlightStallTimeout(
                    phase: status.phase,
                    sessionAlive: sessionAlive
                )
                if status.isInFlight, age > timeout {
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
            let timeout = KeyboardTranscriptDelivery.inFlightStallTimeout(
                phase: status.phase,
                sessionAlive: sessionAlive
            )
            if age > timeout {
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

    private func deliver(_ transcript: String) {
        onTranscript?(transcript)
        currentRequestID = nil
        currentRequestIssuedAt = nil
        localError = nil
        phase = .idle
        message = ""
        retryAvailable = false
        recoverableTranscriptAvailable = false
    }

    /// The explicit path for a transcript the automatic rules would not touch.
    /// The user's tap is the proof of intent the document match could not give.
    func insertRecoveredTranscript() {
        guard let claimed = store.claimTranscript(for: store.status.requestID) else {
            recoverableTranscriptAvailable = false
            return
        }
        deliver(claimed.text)
    }

    /// Dismisses a recoverable transcript without inserting it, consuming the
    /// result so it stops following the user from app to app.
    func discardRecoveredTranscript() {
        _ = store.claimTranscript(for: store.status.requestID)
        recoverableTranscriptAvailable = false
    }

    @discardableResult
    private func beginRequest(
        _ command: DictationCommand,
        initialPhase: DictationPhase,
        message: String
    ) -> Bool {
        localError = nil
        // Every command carries the document affinity: results are published
        // for the ID of the *last* request in the exchange (usually .stop), so
        // the stop must be tagged as well as the start for recreation recovery
        // to match.
        guard let request = store.issue(command, clientDocumentID: clientDocumentID()) else {
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
