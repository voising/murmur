import Foundation

/// One completed dictation. Persisted so the history window has something
/// worth browsing — timestamps and durations are what make a long list
/// scannable, and the old string-only format had neither.
struct Transcription: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let date: Date
    /// Wall-clock length of the recording, or 0 for entries migrated from the
    /// pre-1.1 format where it wasn't recorded.
    let duration: TimeInterval

    init(id: UUID = UUID(), text: String, date: Date, duration: TimeInterval) {
        self.id = id
        self.text = text
        self.date = date
        self.duration = duration
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0 == " " || $0.isNewline }).count
    }
}

/// JSON-backed transcript log in Application Support.
///
/// UserDefaults held the old 5-item string list, which was fine for a menu but
/// too small and too lossy for a browsable window. Anything found there is
/// migrated once and then removed.
final class HistoryStore {
    private static let legacyKey = "MurmurHistory"
    private let limit = 500

    private(set) var items: [Transcription] = []
    private let fileURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")

        load()
        migrateLegacyIfNeeded()
    }

    @discardableResult
    func add(_ text: String, duration: TimeInterval) -> Transcription? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let entry = Transcription(text: trimmed, date: Date(), duration: duration)
        items.insert(entry, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        save()
        return entry
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([Transcription].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Folds the old `[String]` defaults list in as undated entries, newest
    /// first, then drops the key so this runs exactly once.
    private func migrateLegacyIfNeeded() {
        guard let legacy = UserDefaults.standard.stringArray(forKey: Self.legacyKey), !legacy.isEmpty else {
            return
        }
        // No timestamps existed, so space them a minute apart behind the
        // oldest real entry to keep the list order stable.
        let anchor = items.last?.date ?? Date()
        let migrated = legacy.enumerated().map { index, text in
            Transcription(
                text: text,
                date: anchor.addingTimeInterval(-60 * Double(index + 1)),
                duration: 0
            )
        }
        items.append(contentsOf: migrated)
        if items.count > limit { items = Array(items.prefix(limit)) }
        save()
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
    }
}
