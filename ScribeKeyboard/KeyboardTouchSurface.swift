import SwiftUI
import UIKit

/// A UIKit touch surface for the letter grid.
///
/// SwiftUI's `DragGesture` does not expose cancellation. When the system
/// cancelled one, the keyboard could retain its pressed key indefinitely and
/// interpret the next tap as movement in the abandoned gesture. UIKit delivers
/// `touchesCancelled`, letting us tear down every timer and pressed state.
///
/// Fast typists also overlap fingers. If a new touch begins before the previous
/// one lifts, commit the previous touch at its last location and immediately
/// begin the new one instead of dropping the second key.
struct KeyboardTouchSurface: UIViewRepresentable {
    let onBegan: (CGPoint) -> Void
    let onMoved: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onCancelled: () -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isExclusiveTouch = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        update(view)
        return view
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        update(uiView)
    }

    private func update(_ view: TouchView) {
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.onCancelled = onCancelled
    }

    final class TouchView: UIView {
        var onBegan: ((CGPoint) -> Void)?
        var onMoved: ((CGPoint) -> Void)?
        var onEnded: ((CGPoint) -> Void)?
        var onCancelled: (() -> Void)?

        private var activeTouch: UITouch?
        private var lastLocation: CGPoint?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
                if activeTouch != nil, let lastLocation {
                    onEnded?(lastLocation)
                }
                activeTouch = touch
                let location = touch.location(in: self)
                lastLocation = location
                onBegan?(location)
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            guard let touch = touches.first(where: { $0 === activeTouch }) else { return }
            let location = touch.location(in: self)
            lastLocation = location
            onMoved?(location)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            guard let touch = touches.first(where: { $0 === activeTouch }) else { return }
            let location = touch.location(in: self)
            onEnded?(location)
            activeTouch = nil
            lastLocation = nil
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            guard touches.contains(where: { $0 === activeTouch }) else { return }
            cancelActiveTouch()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil, activeTouch != nil {
                cancelActiveTouch()
            }
        }

        private func cancelActiveTouch() {
            activeTouch = nil
            lastLocation = nil
            onCancelled?()
        }
    }
}
