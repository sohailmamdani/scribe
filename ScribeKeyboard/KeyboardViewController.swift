import SwiftUI
import UIKit

@MainActor
final class KeyboardDocumentState: ObservableObject {
    @Published private(set) var textRevision = 0
    @Published private(set) var selectionRevision = 0
    @Published private(set) var hasFullAccess = false
    @Published private(set) var needsInputModeSwitchKey = false

    func textChanged() { textRevision &+= 1 }
    func selectionChanged() { selectionRevision &+= 1 }

    func updateEnvironment(hasFullAccess: Bool, needsInputModeSwitchKey: Bool) {
        if self.hasFullAccess != hasFullAccess {
            self.hasFullAccess = hasFullAccess
        }
        if self.needsInputModeSwitchKey != needsInputModeSwitchKey {
            self.needsInputModeSwitchKey = needsInputModeSwitchKey
        }
    }
}

final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardRootView>?
    private let documentState = KeyboardDocumentState()
    private var keyboardHeightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()

        let rootView = KeyboardRootView(
            documentState: documentState,
            insertText: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            advanceInputMode: { [weak self] in self?.advanceToNextInputMode() },
            context: { [weak self] in
                (self?.textDocumentProxy.documentContextBeforeInput,
                 self?.textDocumentProxy.documentContextAfterInput)
            },
            fieldKind: { [weak self] in
                Self.fieldKind(for: self?.textDocumentProxy.keyboardType ?? .default)
            },
            capitalizationMode: { [weak self] in
                Self.capitalizationMode(
                    for: self?.textDocumentProxy.autocapitalizationType ?? .sentences
                )
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
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 286)
        heightConstraint.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            heightConstraint,
        ])
        hostingController.didMove(toParent: self)
        self.hostingController = hostingController
        keyboardHeightConstraint = heightConstraint
        updateKeyboardHeight()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateKeyboardHeight()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateHostEnvironment()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        updateHostEnvironment()
        documentState.textChanged()
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        updateHostEnvironment()
        documentState.selectionChanged()
    }

    private func updateHostEnvironment() {
        documentState.updateEnvironment(
            hasFullAccess: hasFullAccess,
            needsInputModeSwitchKey: needsInputModeSwitchKey
        )
    }

    private func updateKeyboardHeight() {
        let desiredHeight: CGFloat = traitCollection.verticalSizeClass == .compact ? 224 : 286
        if keyboardHeightConstraint?.constant != desiredHeight {
            keyboardHeightConstraint?.constant = desiredHeight
        }
    }

    private func openContainingApp(_ url: URL, completion: @escaping (Bool) -> Void) {
        guard let extensionContext else {
            completion(false)
            return
        }
        extensionContext.open(url, completionHandler: completion)
    }

    private static func fieldKind(for keyboardType: UIKeyboardType) -> KeyboardFieldKind {
        switch keyboardType {
        case .URL:
            .URL
        case .emailAddress:
            .email
        case .webSearch:
            .webSearch
        case .phonePad, .namePhonePad:
            .phone
        case .numberPad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad:
            .number
        case .default, .asciiCapable, .alphabet, .twitter:
            .text
        @unknown default:
            .other
        }
    }

    private static func capitalizationMode(
        for type: UITextAutocapitalizationType
    ) -> KeyboardCapitalizationMode {
        switch type {
        case .none:
            .none
        case .words:
            .words
        case .sentences:
            .sentences
        case .allCharacters:
            .allCharacters
        @unknown default:
            .sentences
        }
    }
}
