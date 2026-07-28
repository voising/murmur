import SwiftUI

/// Main window: everything Murmur has transcribed, newest first, grouped by
/// day and filterable.
struct HistoryView: View {
    @ObservedObject var state: AppState
    @State private var query = ""
    @State private var selection: UUID?
    @State private var confirmingClear = false

    private var filtered: [Transcription] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return state.history }
        return state.history.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Newest day first, entries already newest-first within each day.
    private var groups: [(day: Date, entries: [Transcription])] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return buckets.keys.sorted(by: >).map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchHeader(
                query: $query,
                canClear: !state.history.isEmpty,
                clear: { confirmingClear = true }
            )

            Group {
                if state.history.isEmpty {
                    EmptyState(
                        symbol: "waveform",
                        title: "No transcriptions yet",
                        message: "Hold the right Option key, say something, and it will show up here."
                    )
                } else if filtered.isEmpty {
                    EmptyState(
                        symbol: "magnifyingglass",
                        title: "No results",
                        message: "Nothing in your history matches “\(query)”."
                    )
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StatusBar(
                phase: state.phase,
                message: state.statusMessage,
                count: state.history.count
            )
        }
        .onChange(of: selection) { id in
            guard let id, let entry = state.history.first(where: { $0.id == id }) else { return }
            state.copyToPasteboard(entry.text)
            Toast.show("Copied to clipboard", kind: .success, duration: 1.5)
        }
        .confirmationDialog(
            "Delete every transcription?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { state.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(state.history.count) transcription\(state.history.count == 1 ? "" : "s"). It can't be undone.")
        }
        .frame(minWidth: 520, minHeight: 380)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.day) { group in
                Section {
                    ForEach(group.entries) { entry in
                        HistoryRow(entry: entry) {
                            state.copyToPasteboard(entry.text)
                            Toast.show("Copied to clipboard", kind: .success, duration: 1.5)
                        }
                        .tag(entry.id)
                        .contextMenu {
                            Button("Copy") { state.copyToPasteboard(entry.text) }
                            Button("Paste into Frontmost App") {
                                state.pasteIntoFrontmostApp(entry.text)
                            }
                            Divider()
                            Button("Delete", role: .destructive) { state.delete(entry.id) }
                        }
                    }
                } header: {
                    Text(Self.dayLabel(group.day))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .padding(.top, 2)
                }
            }
        }
        .listStyle(.inset)
    }

    private static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
            ? "EEEE, MMMM d"
            : "EEEE, MMMM d, yyyy"
        return formatter.string(from: day)
    }
}

// MARK: - Search header

/// The search field lives in the content rather than the titlebar: this window
/// is a bare NSWindow with no NSToolbar, so `.searchable(placement: .toolbar)`
/// fell back to an inline bar whose margins we couldn't set.
private struct SearchHeader: View {
    @Binding var query: String
    let canClear: Bool
    let clear: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)

                    TextField("Search", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            focused ? Color.accentColor.opacity(0.8)
                                    : Color(nsColor: .separatorColor),
                            lineWidth: 1
                        )
                )

                Button(action: clear) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!canClear)
                .help("Delete every transcription")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()
        }
    }
}

// MARK: - Row

/// Time lives in a fixed left gutter so every entry's text starts on the same
/// column; the duration/word count sits under the text as quiet metadata.
private struct HistoryRow: View {
    let entry: Transcription
    let copy: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Button(action: copy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Copy to clipboard")
            .opacity(hovering ? 1 : 0)
            .padding(.top, 1)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var detail: String {
        var parts: [String] = []
        // Migrated pre-1.1 entries have no duration; showing "0.0s" would be a lie.
        if entry.duration > 0 {
            parts.append(String(format: "%.1fs", entry.duration))
        }
        parts.append("\(entry.wordCount) word\(entry.wordCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Status bar

/// Bottom strip: live phase on the left, library size on the right. Keeping it
/// out of the toolbar leaves the title bar to the search field alone.
private struct StatusBar: View {
    let phase: AppState.Phase
    let message: String
    let count: Int

    private var color: Color {
        switch phase {
        case .idle: return .secondary
        case .recording: return .red
        case .transcribing: return .accentColor
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 7) {
                PhaseDot(color: color, pulsing: phase != .idle)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(message)

                Spacer(minLength: 12)

                if count > 0 {
                    Text("\(count) transcription\(count == 1 ? "" : "s")")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
        }
        .background(.bar)
    }
}

/// Small dot that breathes while recording or transcribing, so the window
/// shows state without stealing attention when idle.
private struct PhaseDot: View {
    let color: Color
    let pulsing: Bool

    @State private var animating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.3))
                .scaleEffect(animating ? 1 : 0.35)
                .opacity(animating ? 0 : 1)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .animation(
            pulsing ? .easeOut(duration: 1.1).repeatForever(autoreverses: false) : .default,
            value: animating
        )
        .onAppear { animating = pulsing }
        .onChange(of: pulsing) { animating = $0 }
    }
}

// MARK: - Empty state

/// Stand-in for ContentUnavailableView, which is macOS 14+.
private struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
