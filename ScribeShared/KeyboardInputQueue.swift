import Combine
import Foundation

/// Keeps document edits in typing order while a word-boundary correction is
/// computed off the main thread. Touch feedback remains independent of edits.
@MainActor
final class KeyboardInputQueue: ObservableObject {
    private var pending: [@MainActor () async -> Void] = []
    private var worker: Task<Void, Never>?
    private var generation = 0

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        pending.append(operation)
        guard worker == nil else { return }
        let generation = generation
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.generation == generation, !pending.isEmpty {
                let next = pending.removeFirst()
                await next()
            }
            if self.generation == generation { worker = nil }
        }
    }

    /// A field switch, external cursor move, or disappearing keyboard ends the
    /// editing transaction. An old lookup must never type into a new field.
    func cancel() {
        generation &+= 1
        worker?.cancel()
        worker = nil
        pending.removeAll()
    }

    func waitUntilIdle() async {
        while let worker { await worker.value }
    }
}

/// All keyboard touch surfaces share one sequence, including Space, Return,
/// and punctuation. A new finger commits the preceding touch before starting
/// its own gesture, even when it lands in a different UIKit view.
@MainActor
final class KeyboardTouchSequence: ObservableObject {
    private var activeID: UUID?
    private var finish: (() -> Void)?

    func begin(id: UUID, finish: @escaping () -> Void) {
        finishActiveTouch()
        activeID = id
        self.finish = finish
    }

    func end(id: UUID) {
        guard activeID == id else { return }
        activeID = nil
        finish = nil
    }

    func finishActiveTouch() {
        let previous = finish
        activeID = nil
        finish = nil
        previous?()
    }
}
