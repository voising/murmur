import SwiftUI

/// System Settings-style preferences: source list on the left, one grouped
/// form per section on the right.
struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var section: Section = .general

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case audio = "Audio"
        case transcription = "Transcription"
        case shortcuts = "Shortcuts"
        case about = "About"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .audio: return "mic"
            case .transcription: return "waveform"
            case .shortcuts: return "keyboard"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            detail
                .formStyle(.grouped)
                .navigationTitle(section.rawValue)
                .frame(minWidth: 420)
        }
        .frame(minHeight: 440)
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .general: GeneralSettings(state: state)
        case .audio: AudioSettings(state: state)
        case .transcription: TranscriptionSettings(state: state)
        case .shortcuts: ShortcutSettings(state: state)
        case .about: AboutSettings()
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.launchAtLogin = $0 }
                ))
                Toggle("Show icon in Dock", isOn: Binding(
                    get: { state.showInDock },
                    set: { state.showInDock = $0 }
                ))
            } header: {
                Text("Startup")
            } footer: {
                Text("With the Dock icon hidden, Murmur runs from the menu bar only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                Toggle("Press Return after pasting", isOn: Binding(
                    get: { state.returnAfterPaste },
                    set: { state.returnAfterPaste = $0 }
                ))
            } header: {
                Text("Pasting")
            } footer: {
                Text("Sends Return once the transcription lands — handy for chat boxes, disruptive in a text editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Audio

private struct AudioSettings: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            SwiftUI.Section {
                Picker("Microphone", selection: Binding(
                    get: { state.selectedInputUID },
                    set: { state.selectedInputUID = $0 }
                )) {
                    Text("Automatic (built-in mic)").tag(String?.none)
                    Divider()
                    ForEach(state.inputDevices, id: \.uid) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                Button("Refresh device list") { state.refreshInputDevices() }
            } header: {
                Text("Input")
            } footer: {
                Text("Automatic always records from the built-in microphone, ignoring whatever you're listening on. Bluetooth headsets drop to a 24 kHz phone-call codec when their mic opens, which transcribes noticeably worse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                Toggle("Noise suppression", isOn: Binding(
                    get: { state.noiseSuppression },
                    set: { state.noiseSuppression = $0 }
                ))
            } header: {
                Text("Processing")
            } footer: {
                Text("Runs capture through Apple's voice processing. Worth it on a laptop mic in a noisy room; unnecessary on AirPods, which already do their own. Devices that refuse it fall back automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Transcription

private struct TranscriptionSettings: View {
    @ObservedObject var state: AppState
    @State private var key: String = ""
    @State private var saved = false

    private static let keysURL = URL(string: "https://console.groq.com/keys")!

    var body: some View {
        Form {
            SwiftUI.Section {
                SecureField("API key", text: $key)
                    .onSubmit(save)
                HStack {
                    Link("Get a key at console.groq.com", destination: Self.keysURL)
                        .font(.caption)
                    Spacer()
                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Button("Save", action: save)
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Groq account")
            } footer: {
                Text("Stored in your login keychain, never on disk in the clear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                Picker("Language", selection: Binding(
                    get: { state.languageCode },
                    set: { state.languageCode = $0 }
                )) {
                    ForEach(GroqTranscriber.supportedLanguages, id: \.name) { language in
                        Text(language.name).tag(language.code)
                        if language.code == nil { Divider() }
                    }
                }
            } header: {
                Text("Speech")
            } footer: {
                Text(state.languageCode == "en"
                     ? "English uses whisper-large-v3-turbo — the fastest model."
                     : "Uses whisper-large-v3, which is slower than turbo but markedly better outside English.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { key = state.apiKey }
    }

    private func save() {
        state.apiKey = key
        withAnimation { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { saved = false }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("Push to talk") {
                    KeyCap("⌥ right Option")
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Hold to record, release to transcribe and paste. Requires Accessibility permission in System Settings → Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                LabeledContent("Mouse trigger") {
                    HStack(spacing: 8) {
                        if let button = state.triggerMouseButton {
                            KeyCap("Button \(button)")
                        } else {
                            Text("Not set").foregroundStyle(.secondary)
                        }
                        Button("Change…") { state.onSetMouseTrigger?() }
                        if state.triggerMouseButton != nil {
                            Button("Clear") { state.triggerMouseButton = nil }
                        }
                    }
                }
            } header: {
                Text("Mouse")
            } footer: {
                Text("Any button except left and right. Unlike the key, the mouse trigger toggles: click once to start, again to stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Small keycap-style chip, matching how macOS renders shortcut hints.
private struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(.body, design: .rounded).weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor))
            )
    }
}

// MARK: - About

private struct AboutSettings: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("Murmur")
                .font(.system(size: 24, weight: .semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Hold a key, speak, and the text lands wherever your cursor is.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Link("github.com/voising/murmur",
                 destination: URL(string: "https://github.com/voising/murmur")!)
                .font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
