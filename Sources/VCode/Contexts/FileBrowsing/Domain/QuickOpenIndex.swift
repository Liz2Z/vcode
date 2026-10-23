import Foundation

struct QuickOpenIndex {
    private struct Entry { let path: String; let folded: String; let name: String }
    private let entries: [Entry]
    init(paths: [String]) {
        entries = Array(Set(paths)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map {
            Entry(path: $0, folded: $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
                  name: ($0 as NSString).lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        }
    }

    func matches(_ query: String, recent: [String], limit: Int = 100) -> [String] {
        let tokens = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).split(whereSeparator: \.isWhitespace).map(String.init)
        let recency = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        if tokens.isEmpty {
            let available = Set(entries.map(\.path))
            let first = recent.filter { available.contains($0) }
            return Array((first + entries.map(\.path).filter { recency[$0] == nil }).prefix(limit))
        }
        return entries.compactMap { entry -> (String, Int)? in
            var score = 0
            for token in tokens {
                guard let pathScore = Self.score(token, in: entry.folded) else { return nil }
                score += max(pathScore, (Self.score(token, in: entry.name) ?? -1000) + 80)
            }
            score += recency[entry.path].map { max(1, 60 - $0) } ?? 0
            return (entry.path, score)
        }.sorted { $0.1 == $1.1 ? $0.0.localizedStandardCompare($1.0) == .orderedAscending : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func score(_ token: String, in text: String) -> Int? {
        if text == token { return 1000 }
        if text.hasPrefix(token) { return 700 - min(100, text.count) }
        if text.contains(token) { return 500 - min(100, text.count) }
        var cursor = text.startIndex, skipped = 0
        for character in token {
            guard cursor < text.endIndex, let index = text[cursor...].firstIndex(of: character) else { return nil }
            skipped += text.distance(from: cursor, to: index)
            cursor = text.index(after: index)
        }
        return 200 - min(150, skipped)
    }
}
