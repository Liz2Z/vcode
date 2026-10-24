import AppKit

enum CompactWorkspaceName {
    private static let words = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+"#)

    static func text(_ name: String, font: NSFont, width: CGFloat) -> String {
        func measure(_ value: String) -> CGFloat { (value as NSString).size(withAttributes: [.font: font]).width }
        guard measure(name) > width else { return name }
        let source = name as NSString
        let runs = words.matches(in: name, range: NSRange(location: 0, length: source.length)).map(\.range)
        guard runs.count > 1 else { return name }
        // Break only between words. A separator at the line break is replaced
        // by the newline; separators within each line retain the original name.
        let candidates = (1..<runs.count).map { index -> (text: String, overflow: CGFloat, balance: CGFloat) in
            let first = source.substring(to: NSMaxRange(runs[index - 1]))
            let second = source.substring(from: runs[index].location)
            let a = measure(first), b = measure(second)
            return (first + "\n" + second, max(0, a - width) * 10 + max(0, b - width), abs(a - b))
        }
        return candidates.min { a, b in
            a.overflow == b.overflow ? a.balance < b.balance : a.overflow < b.overflow
        }!.text
    }
}
