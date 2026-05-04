import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var keyMonitor: KeyMonitor!
    private var audioRecorder: AudioRecorder!
    private var transcriber: GroqTranscriber!
    private var history = HistoryStore()
    private var isRecording = false

    private let startSound = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)
    private let stopSound = NSSound(contentsOfFile: "/System/Library/Sounds/Pop.aiff", byReference: true)

    private static let onboardedKey = "MurmurOnboarded"

    func applicationDidFinishLaunching(_ notification: Notification) {
        startSound?.volume = 0.35
        stopSound?.volume = 0.35

        statusBar = StatusBarController()
        statusBar.onSetAPIKey = { [weak self] in self?.promptForAPIKey() }
        statusBar.onShowHelp = { [weak self] in self?.showOnboarding(force: true) }
        statusBar.onQuit = { NSApp.terminate(nil) }
        statusBar.onHistorySelect = { text in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            Toast.show("Copied to clipboard", kind: .success, duration: 1.5)
        }
        statusBar.onHistoryClear = { [weak self] in
            self?.history.clear()
            self?.statusBar.setHistory([])
        }
        statusBar.setHistory(history.items)

        audioRecorder = AudioRecorder()
        transcriber = GroqTranscriber()

        audioRecorder.requestMicPermission { [weak self] granted in
            if !granted {
                Toast.show("Microphone access denied — enable in System Settings → Privacy", kind: .error, duration: 5)
                self?.statusBar.updateStatus("Mic permission denied")
            }
        }

        keyMonitor = KeyMonitor()
        keyMonitor.onPress = { [weak self] in self?.startRecording() }
        keyMonitor.onRelease = { [weak self] in self?.stopRecordingAndTranscribe() }
        keyMonitor.onStatusChange = { [weak self] message in
            self?.statusBar.updateStatus(message)
        }
        keyMonitor.start()

        let firstRun = !UserDefaults.standard.bool(forKey: Self.onboardedKey)
        if firstRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showOnboarding(force: false)
            }
        } else if GroqTranscriber.apiKey == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.promptForAPIKey()
            }
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        guard GroqTranscriber.apiKey != nil else {
            Toast.show("Set your Groq API key first", kind: .error)
            return
        }
        if let err = audioRecorder.startRecording() {
            let msg: String
            switch err {
            case .micPermissionDenied: msg = "Microphone access denied"
            case .invalidInputFormat: msg = "No audio input device available"
            case .converterUnavailable: msg = "Audio converter init failed"
            case .engineFailed(let e): msg = "Audio engine error: \(e.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.statusBar.setIdle()
                Toast.show(msg, kind: .error)
            }
            return
        }
        isRecording = true
        DispatchQueue.main.async {
            self.startSound?.play()
            self.statusBar.setRecording()
            self.statusBar.updateStatus("Recording…")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }
        isRecording = false

        guard let wavData = audioRecorder.stopRecording() else {
            DispatchQueue.main.async {
                self.statusBar.setIdle()
                self.statusBar.updateStatus("No audio captured")
            }
            return
        }

        DispatchQueue.main.async {
            self.stopSound?.play()
            self.statusBar.setTranscribing()
            self.statusBar.updateStatus("Transcribing…")
        }

        Task {
            do {
                let text = try await transcriber.transcribe(wavData: wavData)
                await MainActor.run {
                    if !text.isEmpty {
                        TextPaster.paste(text: text)
                        self.history.add(text)
                        self.statusBar.setHistory(self.history.items)
                        self.statusBar.updateStatus("Ready — hold right Option")
                    } else {
                        Toast.show("No speech detected", kind: .info)
                        self.statusBar.updateStatus("Ready")
                    }
                    self.statusBar.setIdle()
                }
            } catch {
                await MainActor.run {
                    Toast.show("Transcription failed: \(error.localizedDescription)", kind: .error, duration: 4)
                    self.statusBar.updateStatus("Ready")
                    self.statusBar.setIdle()
                }
            }
        }
    }

    private static let groqKeysURL = URL(string: "https://console.groq.com/keys")!

    private func showOnboarding(force: Bool) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Welcome to Murmur"
        alert.informativeText = """
        Press and hold the right Option (⌥) key to record, release to paste the transcription wherever your cursor is.

        You'll need to grant two permissions the first time:
          • Microphone — to capture your voice
          • Accessibility — so the right-Option hotkey works

        A free Groq API key is required.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Set API Key")
        alert.addButton(withTitle: "Get API Key")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)

        switch response {
        case .alertFirstButtonReturn:
            promptForAPIKey()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(Self.groqKeysURL)
            promptForAPIKey()
        default:
            if !force && GroqTranscriber.apiKey == nil {
                Toast.show("Add your API key later from the menu", kind: .info)
            }
        }
    }

    private func promptForAPIKey() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Enter Groq API Key"
        alert.informativeText = "Paste your key below. Don't have one yet? Click the link."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 52))
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6

        let input = NSSecureTextField()
        input.placeholderString = "gsk_..."
        input.translatesAutoresizingMaskIntoConstraints = false
        if let existing = GroqTranscriber.apiKey {
            input.stringValue = existing
        }

        let linkString = NSMutableAttributedString(string: "→ Get a key at console.groq.com/keys")
        linkString.addAttributes([
            .link: Self.groqKeysURL,
            .foregroundColor: NSColor.linkColor,
            .font: NSFont.systemFont(ofSize: 11),
            .cursor: NSCursor.pointingHand,
        ], range: NSRange(location: 0, length: linkString.length))
        let link = NSTextField(labelWithAttributedString: linkString)
        link.allowsEditingTextAttributes = true
        link.isSelectable = true

        container.addArrangedSubview(input)
        container.addArrangedSubview(link)
        NSLayoutConstraint.activate([
            input.widthAnchor.constraint(equalToConstant: 320),
        ])
        container.setFrameSize(NSSize(width: 320, height: 52))

        alert.accessoryView = container
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                GroqTranscriber.apiKey = key
                Toast.show("API key saved", kind: .success)
            }
        }
    }
}
