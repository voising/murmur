import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Single observable bridge between the AppKit core (recorder, key monitor,
/// status bar) and the SwiftUI windows.
///
/// Every setting already has a canonical home — UserDefaults via the static
/// accessors on `AudioRecorder`, `GroqTranscriber`, `TextPaster`,
/// `KeyMonitor`, or the Keychain. These are write-through mirrors, so the
/// status-bar menu and the settings window can't drift apart.
/// Not actor-annotated on purpose: every touch point (AppKit callbacks, the
/// CGEvent tap's run-loop callback, SwiftUI bindings) is already on the main
/// thread, and isolating it would force `assumeIsolated` at a dozen call sites.
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    // MARK: - Live state

    @Published private(set) var phase: Phase = .idle
    @Published var statusMessage: String = "Ready"
    @Published private(set) var history: [Transcription] = []
    @Published private(set) var inputDevices: [AudioInputDevice] = []

    /// Set by AppDelegate so settings changes that need the AppKit side to act
    /// (rebinding the mouse trigger, re-showing onboarding) can reach it.
    var onSetMouseTrigger: (() -> Void)?
    var onShowHelp: (() -> Void)?

    private let store: HistoryStore

    private init() {
        store = HistoryStore()
        history = store.items
        inputDevices = AudioDeviceManager.listInputDevices()
    }

    // MARK: - Recording lifecycle (called from AppDelegate)

    func setPhase(_ phase: Phase, message: String? = nil) {
        self.phase = phase
        if let message { statusMessage = message }
    }

    func record(text: String, duration: TimeInterval) {
        store.add(text, duration: duration)
        history = store.items
    }

    // MARK: - History actions

    func delete(_ id: UUID) {
        store.delete(id)
        history = store.items
    }

    func clearHistory() {
        store.clear()
        history = store.items
    }

    func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Re-types an old transcript into whatever app had focus before Murmur.
    /// The window has to yield focus first or the paste lands in our own list.
    func pasteIntoFrontmostApp(_ text: String) {
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            TextPaster.paste(text: text)
        }
    }

    // MARK: - Settings mirrors

    var languageCode: String? {
        get { GroqTranscriber.languageCode }
        set { objectWillChange.send(); GroqTranscriber.languageCode = newValue }
    }

    var noiseSuppression: Bool {
        get { AudioRecorder.noiseSuppressionEnabled }
        set {
            objectWillChange.send()
            AudioRecorder.noiseSuppressionEnabled = newValue
            // Re-enabling means "try again" — a macOS or firmware update may
            // have fixed a device that previously refused to initialize it.
            if newValue { AudioRecorder.clearVoiceProcessingBlocklist() }
        }
    }

    var returnAfterPaste: Bool {
        get { TextPaster.pressReturnAfterPaste }
        set { objectWillChange.send(); TextPaster.pressReturnAfterPaste = newValue }
    }

    /// nil means "Automatic", which resolves to the built-in mic at record time.
    var selectedInputUID: String? {
        get { AudioDeviceManager.selectedUID }
        set { objectWillChange.send(); AudioDeviceManager.selectedUID = newValue }
    }

    var triggerMouseButton: Int? {
        get { KeyMonitor.triggerMouseButton }
        set { objectWillChange.send(); KeyMonitor.triggerMouseButton = newValue }
    }

    var apiKey: String {
        get { GroqTranscriber.apiKey ?? "" }
        set {
            objectWillChange.send()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            GroqTranscriber.apiKey = trimmed.isEmpty ? nil : trimmed
        }
    }

    var hasAPIKey: Bool { GroqTranscriber.apiKey?.isEmpty == false }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Toast.show("Couldn't update login item: \(error.localizedDescription)", kind: .error)
            }
        }
    }

    private static let showInDockKey = "MurmurShowInDock"

    /// Dock icon + full app menu, versus a pure menu-bar accessory. Defaults on
    /// so a fresh install behaves like a normal Mac app.
    var showInDock: Bool {
        get {
            UserDefaults.standard.object(forKey: Self.showInDockKey) as? Bool ?? true
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.showInDockKey)
            Self.applyActivationPolicy(showInDock: newValue)
        }
    }

    /// `.accessory` hides the Dock icon. Switching to `.regular` at runtime
    /// leaves the app unfocused, so re-activate to avoid a dead-looking window.
    static func applyActivationPolicy(showInDock: Bool) {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        if showInDock {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func refreshInputDevices() {
        inputDevices = AudioDeviceManager.listInputDevices()
    }
}
