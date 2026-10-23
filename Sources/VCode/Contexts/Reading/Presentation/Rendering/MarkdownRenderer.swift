import AppKit

enum MarkdownRenderer {
    static let codeBlock = NSAttributedString.Key("VCodeMarkdownCodeBlock")
    static let sourceRange = NSAttributedString.Key("VCodeMarkdownSourceRange")

    static func supports(_ path: String) -> Bool {
        ["md", "markdown", "mdown"].contains((path as NSString).pathExtension.lowercased())
    }

    static func render(_ source: String) throws -> NSAttributedString {
        let parsed = try AttributedString(markdown: source, options: .init(appliesSourcePositionAttributes: true))
        let result = NSMutableAttributedString()
        let sourceLines = source.components(separatedBy: "\n")
        var sourceOffset = 0
        let lineOffsets = sourceLines.map { line in defer { sourceOffset += (line as NSString).length + 1 }; return sourceOffset }
        // Use the parser's UTF-8 line/column coordinates. On some Foundation
        // versions NSRange(position, in:) retains only the first character.
        func sourceRange(_ position: AttributedString.MarkdownSourcePosition) -> NSRange? {
            guard sourceLines.indices.contains(position.startLine - 1), sourceLines.indices.contains(position.endLine - 1) else { return nil }
            func offset(line: Int, byte: Int) -> Int {
                let value = sourceLines[line - 1]
                let bytes = value.utf8
                let boundary = bytes.index(bytes.startIndex, offsetBy: min(max(0, byte), bytes.count))
                let prefix = String(decoding: bytes[..<boundary], as: UTF8.self)
                return lineOffsets[line - 1] + (prefix as NSString).length
            }
            let start = offset(line: position.startLine, byte: position.startColumn - 1)
            let end = offset(line: position.endLine, byte: position.endColumn)
            return NSRange(location: start, length: max(0, end - start))
        }
        var previousBlock: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let newBlock = previousBlock != block
            if newBlock, result.length > 0 {
                result.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
            }
            previousBlock = block
            let content = String(parsed[run.range].characters)
            let sourceSpan = run.markdownSourcePosition.flatMap { sourceRange($0) }
            if let code = components.first(where: { if case .codeBlock = $0.kind { return true }; return false }),
               case .codeBlock(let language) = code.kind {
                let text = NSTextStorage(string: content.hasSuffix("\n") ? String(content.dropLast()) : content)
                Syntax.apply(to: text, path: "preview." + codeExtension(language), font: Theme.Code.font())
                text.addAttribute(codeBlock, value: true, range: NSRange(location: 0, length: text.length))
                if let sourceSpan {
                    // A fenced block's native source span includes its fences.
                    let literal = (source as NSString).range(of: text.string, range: sourceSpan)
                    text.addAttribute(Self.sourceRange, value: NSValue(range: literal.location == NSNotFound ? sourceSpan : literal), range: NSRange(location: 0, length: text.length))
                }
                result.append(text)
                continue
            }
            var attributes = bodyAttributes
            if let sourceSpan { attributes[Self.sourceRange] = NSValue(range: sourceSpan) }
            let paragraph = (attributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            let items = components.filter { if case .listItem = $0.kind { return true }; return false }
            if let item = items.first, case .listItem(let ordinal) = item.kind {
                let indent = CGFloat(items.count - 1) * 20
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent + 22
                if newBlock {
                    let list = components.first { if case .orderedList = $0.kind { return true }; if case .unorderedList = $0.kind { return true }; return false }
                    let ordered: Bool
                    if let list, case .orderedList = list.kind { ordered = true } else { ordered = false }
                    result.append(NSAttributedString(string: ordered ? "\(ordinal). " : "• ", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: Theme.muted, .paragraphStyle: paragraph]))
                }
            }
            if components.contains(where: { if case .blockQuote = $0.kind { return true }; return false }) {
                paragraph.firstLineHeadIndent += 16
                paragraph.headIndent += 16
                attributes[.foregroundColor] = Theme.muted
            }
            for component in components {
                if case .header(let level) = component.kind {
                    let sizes: [CGFloat] = [28, 23, 19, 17, 15, 14]
                    attributes[.font] = NSFont.systemFont(ofSize: sizes[min(max(level - 1, 0), 5)], weight: .semibold)
                    paragraph.paragraphSpacingBefore = level < 3 ? 18 : 12
                    paragraph.paragraphSpacing = 10
                }
            }
            let inline = run.inlinePresentationIntent ?? []
            var font = attributes[.font] as! NSFont
            var traits = font.fontDescriptor.symbolicTraits
            if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if inline.contains(.emphasized) { traits.insert(.italic) }
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
            if inline.contains(.code) { font = Theme.Code.font(); attributes[.backgroundColor] = Theme.surface; attributes[.foregroundColor] = Theme.accent }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            attributes[.font] = font
            attributes[.paragraphStyle] = paragraph
            if let link = run.link { attributes[.link] = link; attributes[.foregroundColor] = Theme.accent; attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: content, attributes: attributes))
        }
        return result
    }

    private static var bodyAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 10
        return [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: Theme.text, .paragraphStyle: paragraph]
    }

    private static func codeExtension(_ language: String?) -> String {
        switch language?.lowercased() {
        case "typescript", "ts": return "ts"
        case "tsx": return "tsx"
        case "javascript", "js": return "js"
        case "json", "swift", "css": return language!.lowercased()
        default: return "txt"
        }
    }
}
