import Foundation

enum Diff {
    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    // Zero-context hunks give us alignment; the actual text always comes from the full files.
    static func align(before: String, after: String, patch: String) throws -> [DiffRow] {
        let oldLines = lines(before)
        let newLines = lines(after)
        let regex = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        var rows: [DiffRow] = []
        var oldIndex = 0
        var newIndex = 0

        func line(_ text: [String], _ index: Int, _ kind: LineKind) -> CodeLine {
            CodeLine(number: index + 1, text: text[index], kind: kind)
        }
        let blank = CodeLine(number: nil, text: "", kind: .placeholder)

        for header in patch.components(separatedBy: "\n") where header.hasPrefix("@@ ") {
            let source = header as NSString
            guard let match = regex.firstMatch(in: header, range: NSRange(location: 0, length: source.length)) else {
                throw ReadingError.invalidPatch
            }
            func value(_ index: Int, default fallback: Int) -> Int {
                let range = match.range(at: index)
                return range.location == NSNotFound ? fallback : Int(source.substring(with: range)) ?? fallback
            }
            let oldStart = value(1, default: 0)
            let oldCount = value(2, default: 1)
            let newStart = value(3, default: 0)
            let newCount = value(4, default: 1)
            let oldTarget = oldCount == 0 ? oldStart : oldStart - 1
            let newTarget = newCount == 0 ? newStart : newStart - 1
            guard oldTarget >= oldIndex, newTarget >= newIndex,
                  oldTarget + oldCount <= oldLines.count, newTarget + newCount <= newLines.count,
                  oldTarget - oldIndex == newTarget - newIndex else { throw ReadingError.invalidPatch }

            while oldIndex < oldTarget {
                rows.append(DiffRow(left: line(oldLines, oldIndex, .unchanged), right: line(newLines, newIndex, .unchanged)))
                oldIndex += 1
                newIndex += 1
            }
            for offset in 0..<max(oldCount, newCount) {
                rows.append(DiffRow(
                    left: offset < oldCount ? line(oldLines, oldIndex + offset, .removed) : blank,
                    right: offset < newCount ? line(newLines, newIndex + offset, .added) : blank
                ))
            }
            oldIndex += oldCount
            newIndex += newCount
        }
        guard oldLines.count - oldIndex == newLines.count - newIndex else { throw ReadingError.invalidPatch }
        while oldIndex < oldLines.count {
            rows.append(DiffRow(left: line(oldLines, oldIndex, .unchanged), right: line(newLines, newIndex, .unchanged)))
            oldIndex += 1
            newIndex += 1
        }
        if patch.isEmpty && before != after && oldLines != newLines { throw ReadingError.invalidPatch }
        return rows
    }
}
