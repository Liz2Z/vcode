import Foundation

struct FileSnapshot: Equatable {
    static let maximumByteCount = 4 * 1024 * 1024
    let path: String
    let before: String
    let after: String
    let rows: [DiffRow]
    let message: String?
    let isBinary: Bool

    let comparison: GitComparison?

    init(path: String, before: String, after: String, rows: [DiffRow], message: String?, isBinary: Bool, comparison: GitComparison? = nil) {
        self.path = path; self.before = before; self.after = after; self.rows = rows
        self.message = message; self.isBinary = isBinary; self.comparison = comparison
    }

    var additions: Int { rows.filter { $0.right.kind == .added }.count }
    var deletions: Int { rows.filter { $0.left.kind == .removed }.count }
    var changedRows: [Int] {
        rows.indices.filter { rows[$0].left.kind == .removed || rows[$0].right.kind == .added }
    }
}
