import AppKit

enum DiffHighlights {
    static func apply(_ snapshot: FileSnapshot, left: CodePane, right: CodePane) {
        for (index, row) in snapshot.rows.enumerated() where row.left.kind == .removed && row.right.kind == .added {
            let old = Array(row.left.text), new = Array(row.right.text)
            var prefix = 0, suffix = 0
            while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
            while suffix < min(old.count, new.count) - prefix, old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
            for (pane, characters, color) in [(left, old, Theme.red), (right, new, Theme.green)] {
                let start = (String(characters.prefix(prefix)) as NSString).length
                let count = (String(characters.dropFirst(prefix).dropLast(suffix)) as NSString).length
                if count > 0, pane.offsets.indices.contains(index) {
                    pane.text.textStorage?.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.16), range: NSRange(location: pane.offsets[index] + start, length: count))
                }
            }
        }
    }
}
