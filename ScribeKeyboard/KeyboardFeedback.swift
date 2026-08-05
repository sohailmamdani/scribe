import UIKit

/// Haptic feedback for key presses. Keyboard extensions may play haptics as
/// of iOS 17.5 when the keyboard has Full Access; without it these calls are
/// silently ignored, so no gating is needed.
@MainActor
enum KeyboardHaptics {
    private static let keyTap = UIImpactFeedbackGenerator(style: .light)
    private static let deleteRepeat = UIImpactFeedbackGenerator(style: .soft)
    private static let wordCommit = UIImpactFeedbackGenerator(style: .medium)
    private static let notice = UINotificationFeedbackGenerator()

    /// Prime the generators while the keyboard is becoming visible. UIKit's
    /// generators fall back to a cold start after an idle pause; preparing only
    /// *after* a key press made that first press the one most likely to feel
    /// silent.
    static func prepareForInput() {
        keyTap.prepare()
        deleteRepeat.prepare()
        wordCommit.prepare()
        notice.prepare()
    }

    static func keyDown() {
        keyTap.prepare()
        keyTap.impactOccurred(intensity: 0.8)
        keyTap.prepare()
    }

    static func deleteTick() {
        deleteRepeat.prepare()
        deleteRepeat.impactOccurred(intensity: 0.6)
        deleteRepeat.prepare()
    }

    static func cursorTick() {
        deleteRepeat.prepare()
        deleteRepeat.impactOccurred(intensity: 0.35)
        deleteRepeat.prepare()
    }

    static func cursorModeBegan() {
        wordCommit.prepare()
        wordCommit.impactOccurred(intensity: 0.8)
        wordCommit.prepare()
    }

    static func swipeCommit() {
        wordCommit.prepare()
        wordCommit.impactOccurred()
        wordCommit.prepare()
    }

    static func swipeFailed() {
        notice.prepare()
        notice.notificationOccurred(.warning)
        notice.prepare()
    }
}

/// Drives press-and-hold deletion: single characters at an accelerating pace,
/// then whole words once the key has been held for a while.
@MainActor
final class KeyRepeatEngine: ObservableObject {
    private var timer: Timer?
    private var characterDeletions = 0
    private var deleteCharacter: (() -> Void)?
    private var deleteWord: (() -> Void)?

    func begin(deleteCharacter: @escaping () -> Void, deleteWord: @escaping () -> Void) {
        stop()
        characterDeletions = 0
        self.deleteCharacter = deleteCharacter
        self.deleteWord = deleteWord
        schedule(after: 0.45)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        deleteCharacter = nil
        deleteWord = nil
    }

    private func schedule(after interval: TimeInterval) {
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fire() {
        if characterDeletions < 18 {
            characterDeletions += 1
            deleteCharacter?()
            schedule(after: characterDeletions > 8 ? 0.08 : 0.11)
        } else {
            deleteWord?()
            schedule(after: 0.28)
        }
    }
}
