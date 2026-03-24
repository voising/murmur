import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var keyMonitor: KeyMonitor!
    private var audioRecorder: AudioRecorder!
    private var transcriber: GroqTranscriber!
    private var isRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        statusBar.onSetAPIKey = { [weak self] in self?.promptForAPIKey() }
        statusBar.onQuit = { NSApp.terminate(nil) }

        audioRecorder = AudioRecorder()
        transcriber = GroqTranscriber()

        keyMonitor = KeyMonitor()
        keyMonitor.onPress = { [weak self] in
            self?.startRecording()
        }
        keyMonitor.onRelease = { [weak self] in
            self?.stopRecordingAndTranscribe()
        }
        keyMonitor.onStatusChange = { [weak self] message in
            self?.statusBar.updateStatus(message)
        }
        keyMonitor.start()

        if GroqTranscriber.apiKey == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.promptForAPIKey()
            }
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        guard GroqTranscriber.apiKey != nil else {
            statusBar.updateStatus("Set API key first")
            return
        }
        isRecording = true
        audioRecorder.startRecording()
        DispatchQueue.main.async {
            self.statusBar.setRecording()
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
            self.statusBar.setTranscribing()
        }

        Task {
            do {
                let text = try await transcriber.transcribe(wavData: wavData)
                await MainActor.run {
                    if !text.isEmpty {
                        TextPaster.paste(text: text)
                        self.statusBar.updateStatus("Pasted: \(String(text.prefix(30)))...")
                    } else {
                        self.statusBar.updateStatus("No speech detected")
                    }
                    self.statusBar.setIdle()
                }
            } catch {
                await MainActor.run {
                    self.statusBar.updateStatus("Error: \(error.localizedDescription)")
                    self.statusBar.setIdle()
                }
            }
        }
    }

    private func promptForAPIKey() {
        // Activate the app so the alert window can receive keyboard input
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Enter Groq API Key"
        alert.informativeText = "Get a free key at console.groq.com"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "gsk_..."
        if let existing = GroqTranscriber.apiKey {
            input.stringValue = existing
        }
        alert.accessoryView = input

        // Make the text field first responder once the alert window is visible
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                GroqTranscriber.apiKey = key
                statusBar.updateStatus("API key saved")
            }
        }
    }
}
