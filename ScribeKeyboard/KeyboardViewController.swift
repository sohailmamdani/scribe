import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        let rootView = KeyboardRootView(
            hasFullAccess: hasFullAccess,
            needsInputModeSwitchKey: needsInputModeSwitchKey,
            insertText: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            advanceInputMode: { [weak self] in self?.advanceToNextInputMode() },
            context: { [weak self] in
                (self?.textDocumentProxy.documentContextBeforeInput,
                 self?.textDocumentProxy.documentContextAfterInput)
            },
            openContainingApp: { [weak self] url, completion in
                guard let self else {
                    completion(false)
                    return
                }
                self.openContainingApp(url, completion: completion)
            }
        )

        let hostingController = UIHostingController(rootView: rootView)
        hostingController.view.backgroundColor = .clear
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 252)
        heightConstraint.priority = .required
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            heightConstraint,
        ])
        hostingController.didMove(toParent: self)
        self.hostingController = hostingController
    }

    /// The keyboard extension point does not support `extensionContext.open`,
    /// so walk the responder chain to UIApplication's `openURL:` instead.
    private func openContainingApp(_ url: URL, completion: @escaping (Bool) -> Void) {
        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                completion(true)
                return
            }
            responder = current.next
        }
        guard let extensionContext else {
            completion(false)
            return
        }
        extensionContext.open(url, completionHandler: completion)
    }
}
