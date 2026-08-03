import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var keyMonitor: KeyMonitor!
    private var audioRecorder: AudioRecorder!
    private var transcriber: GroqTranscriber!
    private var isRecording = false
    private var recordingStartedAt: Date?

    private let state = AppState.shared

    private let startSound = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)
    private let stopSound = NSSound(contentsOfFile: "/System/Library/Sounds/Pop.aiff", byReference: true)

    private static let onboardedKey = "MurmurOnboarded"

    func applicationDidFinishLaunching(_ notification: Notification) {
        startSound?.volume = 0.35
        stopSound?.volume = 0.35

        statusBar = StatusBarController()
        statusBar.onOpenHistory = { AppWindows.shared.showHistory() }
        statusBar.onOpenSettings = { AppWindows.shared.showSettings() }
        statusBar.onShowHelp = { [weak self] in self?.showOnboarding(force: true) }
        statusBar.onQuit = { NSApp.terminate(nil) }
        statusBar.onHistorySelect = { [weak self] text in
            self?.state.copyToPasteboard(text)
            Toast.show("Copied to clipboard", kind: .success, duration: 1.5)
        }
        statusBar.setHistory(state.history)

        state.onSetMouseTrigger = { [weak self] in self?.beginLearningMouseButton() }
        state.onShowHelp = { [weak self] in self?.showOnboarding(force: true) }

        audioRecorder = AudioRecorder()
        transcriber = GroqTranscriber()

        audioRecorder.requestMicPermission { [weak self] granted in
            if !granted {
                Toast.show("Microphone access denied — enable in System Settings → Privacy", kind: .error, duration: 5)
                self?.setStatus("Mic permission denied")
            }
        }

        keyMonitor = KeyMonitor()
        keyMonitor.onPress = { [weak self] in self?.startRecording() }
        keyMonitor.onRelease = { [weak self] in self?.stopRecordingAndTranscribe() }
        keyMonitor.onToggle = { [weak self] in
            guard let self = self else { return }
            if self.isRecording {
                self.stopRecordingAndTranscribe()
            } else {
                self.startRecording()
            }
        }
        keyMonitor.onStatusChange = { [weak self] message in self?.setStatus(message) }
        keyMonitor.start()

        let firstRun = !UserDefaults.standard.bool(forKey: Self.onboardedKey)
        if firstRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showOnboarding(force: false)
            }
        } else if GroqTranscriber.apiKey == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppWindows.shared.showSettings()
            }
        } else if state.showInDock {
            // A Dock-visible app that launches with no window looks broken.
            AppWindows.shared.showHistory()
        }
    }

    /// Clicking the Dock icon with no window open reopens the history window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppWindows.shared.showHistory() }
        return true
    }

    /// Closing the last window shouldn't quit — the hotkey still works.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Menu actions

    @objc func showSettings(_ sender: Any?) { AppWindows.shared.showSettings() }
    @objc func showHistoryWindow(_ sender: Any?) { AppWindows.shared.showHistory() }
    @objc func showHelp(_ sender: Any?) { showOnboarding(force: true) }

    @objc func showAbout(_ sender: Any?) {
        AppWindows.shared.showSettings()
    }

    // MARK: - Recording

    private func startRecording() {
        guard !isRecording else { return }
        guard GroqTranscriber.apiKey != nil else {
            Toast.show("Set your Groq API key first", kind: .error)
            AppWindows.shared.showSettings()
            return
        }
        if let err = audioRecorder.startRecording() {
            let msg: String
            switch err {
            case .micPermissionDenied: msg = "Microphone access denied"
            case .invalidInputFormat: msg = "Audio input format unsupported"
            case .noInputDevice: msg = "No input device available"
            case .audioUnitFailed(let status): msg = "Audio unit error \(status)"
            }
            DispatchQueue.main.async {
                self.statusBar.setIdle()
                self.state.setPhase(.idle, message: msg)
                Toast.show(msg, kind: .error)
            }
            return
        }
        isRecording = true
        recordingStartedAt = Date()
        DispatchQueue.main.async {
            self.startSound?.play()
            self.statusBar.setRecording()
            self.statusBar.updateStatus("Recording…")
            self.state.setPhase(.recording, message: "Recording…")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }
        isRecording = false
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil

        guard let wavData = audioRecorder.stopRecording() else {
            DispatchQueue.main.async {
                self.statusBar.setIdle()
                self.setStatus("No audio captured")
                Toast.show("No audio captured — check that your input device isn't muted", kind: .error, duration: 4)
            }
            return
        }

        DispatchQueue.main.async {
            self.stopSound?.play()
            self.statusBar.setTranscribing()
            self.statusBar.updateStatus("Transcribing…")
            self.state.setPhase(.transcribing, message: "Transcribing…")
        }

        Task {
            do {
                let text = try await transcriber.transcribe(wavData: wavData)
                await MainActor.run {
                    if !text.isEmpty {
                        TextPaster.paste(text: text)
                        self.state.record(text: text, duration: duration)
                        self.statusBar.setHistory(self.state.history)
                        self.setStatus("Ready — hold right Option")
                    } else {
                        Toast.show("No speech detected", kind: .info)
                        self.setStatus("Ready")
                    }
                    self.statusBar.setIdle()
                    self.state.setPhase(.idle)
                }
            } catch {
                await MainActor.run {
                    Toast.show("Transcription failed: \(error.localizedDescription)", kind: .error, duration: 4)
                    self.setStatus("Ready")
                    self.statusBar.setIdle()
                    self.state.setPhase(.idle)
                }
            }
        }
    }

    private func setStatus(_ message: String) {
        statusBar.updateStatus(message)
        state.statusMessage = message
    }

    private func beginLearningMouseButton() {
        Toast.show("Click the mouse button you want to use (any button except left/right)…", kind: .info, duration: 5)
        keyMonitor.startLearningMouseButton { [weak self] button in
            Toast.show("Bound to mouse button \(button) — click to start/stop recording", kind: .success)
            self?.statusBar.refreshMenu()
            self?.setStatus("Ready — click mouse button \(button) to record")
        }
    }

    // MARK: - Onboarding

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
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Get API Key")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)

        switch response {
        case .alertFirstButtonReturn:
            AppWindows.shared.showSettings()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(Self.groqKeysURL)
            AppWindows.shared.showSettings()
        default:
            if !force && GroqTranscriber.apiKey == nil {
                Toast.show("Add your API key in Settings", kind: .info)
            }
        }
    }
}
