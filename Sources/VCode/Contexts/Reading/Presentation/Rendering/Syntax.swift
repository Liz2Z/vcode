import AppKit

enum Syntax {
    // Code needs a wider palette than chrome so syntax roles remain easy to scan.
    private static let keyword = NSColor(hex: 0xCBB0EE)
    private static let primitive = NSColor(hex: 0x8EBEEA)
    private static let number = NSColor(hex: 0xB7CEA0)
    private static let type = NSColor(hex: 0x81C7BA)
    private static let function = NSColor(hex: 0xE8D294)
    private static let property = NSColor(hex: 0xA8C9E5)
    private static let literal = NSColor(hex: 0xE3AF96)
    private static let string = NSColor(hex: 0xE0B58F)
    private static let comment = NSColor(hex: 0xB3BAB2)
    private static let keywords = Set("abstract as asserts async await break case catch class const continue debugger declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface is keyof let namespace new of override private protected public readonly return satisfies set static super switch this throw try type typeof unique var void while with yield".split(separator: " ").map(String.init))
    private static let primitives = Set("any bigint boolean never number object string symbol undefined unknown null true false".split(separator: " ").map(String.init))
    private static let literals: Set<String> = ["true", "false", "null", "undefined"]
    // A single lexical pass keeps comment markers inside strings from changing their color.
    private static let tokens = try! NSRegularExpression(pattern: #"(?<comment>//[^\n]*|/\*[\s\S]*?(?:\*/|$))|(?<string>\"(?:\\[\s\S]|[^\"\\])*\"|'(?:\\[\s\S]|[^'\\])*'|`(?:\\[\s\S]|[^`\\])*`)|(?<number>\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?n?)\b)|(?<function>[A-Za-z_$][\w$]*(?=\s*\())|(?<property>[A-Za-z_$][\w$]*(?=\s*\??\s*:)|(?<=\.)[A-Za-z_$][\w$]*)|(?<identifier>[A-Za-z_$][\w$]*)"#)

    static func apply(to storage: NSTextStorage, path: String, font: NSFont) {
        let range = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: Theme.text], range: range)
        let supported = ["ts", "tsx", "js", "jsx", "mts", "cts", "json", "swift", "css"]
        if supported.contains((path as NSString).pathExtension.lowercased()), storage.length < 800_000 {
            let source = storage.string as NSString
            tokens.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                guard let match else { return }
                let word = source.substring(with: match.range)
                let color: NSColor?
                if match.range(withName: "comment").location != NSNotFound { color = comment }
                else if match.range(withName: "string").location != NSNotFound { color = string }
                else if match.range(withName: "number").location != NSNotFound { color = number }
                else if ["get", "set"].contains(word), match.range(withName: "function").location != NSNotFound { color = function }
                else if keywords.contains(word) { color = keyword }
                else if literals.contains(word) { color = literal }
                else if primitives.contains(word) { color = primitive }
                else if match.range(withName: "function").location != NSNotFound { color = function }
                else if match.range(withName: "property").location != NSNotFound { color = property }
                else if word.first?.isUppercase == true { color = type }
                else { color = nil }
                if let color { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Theme.Code.lineHeight
        paragraph.maximumLineHeight = Theme.Code.lineHeight
        paragraph.tabStops = []
        paragraph.defaultTabInterval = max(7, font.maximumAdvancement.width) * 4
        storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
        storage.endEditing()
    }
}
