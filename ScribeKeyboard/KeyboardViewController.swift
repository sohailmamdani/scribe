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
                guard let extensionContext = self?.extensionContext else {
                    completion(false)
                    return
                }
                extensionContext.open(url, completionHandler: completion)
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
}
