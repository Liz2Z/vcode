import Foundation

/// Content around an anchor lets a refresh follow insertions above the reader.
struct ReadingTextAnchor: Codable, Equatable {
    var line: Int
    var character: Int
    var text: String
    var previous: String?
    var next: String?

    init(line: Int, character: Int = 0, lines: [String]) {
        self.line = max(0, min(line, max(0, lines.count - 1)))
        self.character = max(0, character)
        text = lines.indices.contains(self.line) ? lines[self.line] : ""
        previous = self.line > 0 ? lines[self.line - 1] : nil
        next = self.line + 1 < lines.count ? lines[self.line + 1] : nil
    }

    func resolvedLine(in lines: [String]) -> Int {
        guard !lines.isEmpty else { return 0 }
        let matches = lines.indices.filter { lines[$0] == text }
        if let best = matches.max(by: { score($0, in: lines) < score($1, in: lines) }) { return best }
        // The cursor's own line may have changed. Neighbouring text still anchors it.
        let neighbours = lines.indices.compactMap { index -> Int? in
            if let previous, lines[index] == previous { return min(index + 1, lines.count - 1) }
            if let next, lines[index] == next { return max(0, index - 1) }
            return nil
        }
        return neighbours.min(by: { abs($0 - line) < abs($1 - line) }) ?? min(line, lines.count - 1)
    }

    private func score(_ index: Int, in lines: [String]) -> Int {
        let before = index > 0 && previous != nil && lines[index - 1] == previous ? 1 : 0
        let after = index + 1 < lines.count && next != nil && lines[index + 1] == next ? 1 : 0
        return (before + after) * (lines.count + 1) - abs(index - line)
    }
}

struct PaneReadingPosition: Codable, Equatable {
    var start: ReadingTextAnchor
    var end: ReadingTextAnchor
    var top: ReadingTextAnchor
    var verticalOffset: Double
    var horizontalOffset: Double
}

struct MarkdownReadingPosition: Codable, Equatable {
    var selection: NSRange
    var x: Double
    var y: Double
    var top: ReadingTextAnchor? = nil
    var verticalOffset: Double = 0
}

struct ReadingLocation: Codable, Equatable {
    var document: ReadingDocument
    var right: PaneReadingPosition
    var left: PaneReadingPosition
    var markdown: MarkdownReadingPosition?
    var preview: Bool
}

/// Each editor group owns its own bounded timeline. Restoring never adds a visit.
struct ReadingHistory {
    private(set) var locations: [ReadingLocation] = []
    private(set) var index = -1
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index + 1 < locations.count }

    mutating func updateCurrent(_ location: ReadingLocation) {
        if locations.indices.contains(index) { locations[index] = location }
        else { visit(location) }
    }

    mutating func visit(_ location: ReadingLocation) {
        if locations.indices.contains(index), locations[index] == location { return }
        locations = Array(locations.prefix(index + 1))
        locations.append(location)
        if locations.count > 200 { locations.removeFirst(locations.count - 200) }
        index = locations.count - 1
    }

    mutating func move(forward: Bool, current: ReadingLocation?) -> ReadingLocation? {
        if let current { updateCurrent(current) }
        guard forward ? canGoForward : canGoBack else { return nil }
        index += forward ? 1 : -1
        return locations[index]
    }

    mutating func renamePaths(_ renames: [String: String]) {
        for i in locations.indices {
            if let path = renames[locations[i].document.path] {
                locations[i].document = ReadingDocument(path: path, comparison: locations[i].document.comparison)
            }
        }
    }
}
