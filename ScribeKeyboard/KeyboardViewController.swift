import SwiftUI
import UIKit

@MainActor
final class KeyboardDocumentState: ObservableObject {
    @Published private(set) var textRevision = 0
    @Published private(set) var selectionRevision = 0
    @Published private(set) var hasFullAccess = false
    @Published private(set) var needsInputModeSwitchKey = false
    @Published private(set) var preferences: KeyboardPreferences
    private let preferencesStore: SharedKeyboardPreferencesStore

    init() {
        let store = SharedKeyboardPreferencesStore()
        preferencesStore = store
        preferences = store.preferences
    }

    func textChanged() { textRevision &+= 1 }
    func selectionChanged() { selectionRevision &+= 1 }

    func updateEnvironment(hasFullAccess: Bool, needsInputModeSwitchKey: Bool) {
        if self.hasFullAccess != hasFullAccess {
            self.hasFullAccess = hasFullAccess
        }
        if self.needsInputModeSwitchKey != needsInputModeSwitchKey {
            self.needsInputModeSwitchKey = needsInputModeSwitchKey
        }
        let latestPreferences = preferencesStore.preferences
        if preferences != latestPreferences {
            preferences = latestPreferences
        }
    }
}

final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardRootView>?
    private let documentState = KeyboardDocumentState()
    private let autocorrectionEngine = KeyboardAutocorrectionEngine()
    private var keyboardHeightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()

        // UIKit's current feedback API must be associated with the live input
        // view. Installing it here also primes the engine before SwiftUI begins
        // handling key touches.
        KeyboardHaptics.setEnabled(documentState.preferences.hapticsEnabled)
        KeyboardHaptics.attach(to: view)

        let rootView = KeyboardRootView(
            documentState: documentState,
            insertText: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            adjustTextPosition: { [weak self] offset in
                self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
            },
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
            autocorrectionEnabled: { [weak self] in
                self?.textDocumentProxy.autocorrectionType != .no
            },
            correctionsForWord: { [weak self] word, contextBefore, evidence in
                guard let self else { return [] }
                let language = await MainActor.run {
                    self.textDocumentProxy.documentInputMode?.primaryLanguage ?? "en-US"
                }
                return await self.autocorrectionEngine.corrections(
                    for: word,
                    contextBefore: contextBefore,
                    language: language,
                    evidence: evidence
                )
            },
            recordAcceptedCorrection: { [weak self] original, replacement in
                guard let self else { return }
                Task {
                    await self.autocorrectionEngine.recordAccepted(
                        original: original,
                        replacement: replacement
                    )
                }
            },
            recordRejectedCorrection: { [weak self] original, replacement in
                guard let self else { return }
                Task {
                    await self.autocorrectionEngine.recordRejected(
                        original: original,
                        replacement: replacement
                    )
                }
            },
            openContainingApp: { [weak self] url, completion in
                guard let self else {
                    completion(false)
                    return
                }
                self.openContainingApp(url, completion: completion)
            },
            clientDocumentID: { [weak self] in
                guard let self, self.view.window != nil else { return nil }
                return Self.safeDocumentIdentifier(of: self.textDocumentProxy)
            },
            hostIsForegroundActive: { [weak self] in
                guard let view = self?.view, view.window != nil else { return false }
                // Insertion also works during the brief foreground-inactive
                // moments around transitions; only background hosts drop text.
                switch view.window?.windowScene?.activationState {
                case .foregroundActive, .foregroundInactive, nil:
                    return true
                case .background, .unattached:
                    return false
                @unknown default:
                    return true
                }
            }
        )

        let hostingController = UIHostingController(rootView: rootView)
        hostingController.view.backgroundColor = .clear
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        let heightConstraint = view.heightAnchor.constraint(
            equalToConstant: KeyboardGeometryRules.portrait.extensionHeight
        )
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

        // Warm the lexicon off the main thread so the first correction does not
        // pay for parsing a quarter of a million bigrams.
        Task { [autocorrectionEngine] in await autocorrectionEngine.prepare() }

        requestSupplementaryLexicon { [weak self] lexicon in
            // UILexicon is not Sendable, so lift the values out here and hand
            // the actor plain ones.
            let entries = lexicon.entries.map {
                KeyboardUserLexiconEntry(
                    userInput: $0.userInput,
                    documentText: $0.documentText
                )
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.autocorrectionEngine.updateSupplementaryLexicon(entries: entries)
                self.documentState.textChanged()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateKeyboardHeight()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateHostEnvironment()
        KeyboardHaptics.prepareForInput()
        updateKeyboardHeight()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop the keep-warm cadence with the keyboard; holding the Taptic
        // engine prepared past visibility is what the API contract forbids.
        KeyboardHaptics.detach()
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

    /// Reads `documentIdentifier` without letting Swift's importer unwrap it.
    ///
    /// The property is declared non-optional `UUID`, but early in keyboard
    /// startup the underlying ObjC accessor returns nil, and the direct Swift
    /// call then traps in `UUID._unconditionallyBridgeFromObjectiveC` — the
    /// exact launch crash captured in ScribeKeyboard-2026-08-05/06 .ips
    /// reports, and the reason the first attempt at document-scoped delivery
    /// was rolled back. Key-value coding calls the same getter but passes the
    /// nil through as an absent value instead of force-bridging it.
    private static func safeDocumentIdentifier(of proxy: UITextDocumentProxy) -> String? {
        guard let object = proxy as? NSObject,
              object.responds(to: NSSelectorFromString("documentIdentifier")),
              let uuid = object.value(forKey: "documentIdentifier") as? UUID else {
            return nil
        }
        return uuid.uuidString
    }

    private func updateHostEnvironment() {
        documentState.updateEnvironment(
            hasFullAccess: hasFullAccess,
            needsInputModeSwitchKey: needsInputModeSwitchKey
        )
        KeyboardHaptics.setEnabled(documentState.preferences.hapticsEnabled)
    }

    private func updateKeyboardHeight() {
        let isCompact = traitCollection.verticalSizeClass == .compact
        let geometry = isCompact ? KeyboardGeometryRules.compact : .portrait
        // Keep the complete toolbar + native four-row key-grid formula in
        // shared geometry so SwiftUI cannot compress rows into one another.
        let desiredHeight = CGFloat(geometry.extensionHeight)
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
