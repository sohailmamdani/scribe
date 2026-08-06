import UIKit

/// Haptic feedback for key presses.
///
/// iOS 17.5 added feedback generators that are attached to a live view. The
/// old unattached initializers are deprecated and were especially unreliable
/// in the keyboard-extension process. Keep the generators associated with the
/// current input view and prime them before the first touch arrives.
@MainActor
enum KeyboardHaptics {
    private static var keyTap: UIImpactFeedbackGenerator?
    private static var deleteRepeat: UIImpactFeedbackGenerator?
    private static var wordCommit: UIImpactFeedbackGenerator?
    private static var notice: UINotificationFeedbackGenerator?

    static func attach(to view: UIView) {
        keyTap = UIImpactFeedbackGenerator(style: .light, view: view)
        deleteRepeat = UIImpactFeedbackGenerator(style: .soft, view: view)
        wordCommit = UIImpactFeedbackGenerator(style: .medium, view: view)
        notice = UINotificationFeedbackGenerator(view: view)
        prepareForInput()
    }

    /// Prime the generators while the keyboard is becoming visible. UIKit's
    /// generators fall back to a cold start after an idle pause; preparing only
    /// *after* a key press made that first press the one most likely to feel
    /// silent.
    static func prepareForInput() {
        keyTap?.prepare()
        deleteRepeat?.prepare()
        wordCommit?.prepare()
        notice?.prepare()
    }

    static func keyDown() {
        keyTap?.impactOccurred(intensity: 0.8)
        rearm(keyTap)
    }

    static func deleteTick() {
        deleteRepeat?.impactOccurred(intensity: 0.6)
        rearm(deleteRepeat)
    }

    static func cursorTick() {
        deleteRepeat?.impactOccurred(intensity: 0.35)
        rearm(deleteRepeat)
    }

    static func cursorModeBegan() {
        wordCommit?.impactOccurred(intensity: 0.8)
        rearm(wordCommit)
    }

    static func swipeCommit() {
        wordCommit?.impactOccurred()
        rearm(wordCommit)
    }

    static func swipeFailed() {
        notice?.notificationOccurred(.warning)
        rearm(notice)
    }

    /// Re-prime after returning from the touch callback. Preparing immediately
    /// before `impactOccurred` delayed the feedback; preparing synchronously
    /// after it held up the key's text path. A yielded main-actor task keeps the
    /// next press warm without doing either on the critical event stack.
    private static func rearm(_ generator: UIFeedbackGenerator?) {
        guard let generator else { return }
        Task { @MainActor in
            await Task.yield()
            generator.prepare()
        }
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
