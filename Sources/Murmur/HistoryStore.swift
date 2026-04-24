import Foundation

final class HistoryStore {
    private let key = "MurmurHistory"
    private let limit = 5

    private(set) var items: [String] = []

    init() {
        items = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.removeAll { $0 == trimmed }
        items.insert(trimmed, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        UserDefaults.standard.set(items, forKey: key)
    }

    func clear() {
        items = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}
