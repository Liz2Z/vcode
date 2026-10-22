import AppKit

// Foundation's Markdown parser preserves code blocks and documentation structure;
// the shared code renderer supplies the same TypeScript colors as the editor.
enum HoverTextRenderer {
    static func render(_ markdown: String) -> NSAttributedString {
        let limited = String(markdown.prefix(80_000))
        let result = NSMutableAttributedString()
        guard let parsed = try? AttributedString(markdown: limited) else {
            return NSAttributedString(string: limited, attributes: bodyAttributes)
        }
        var blockID: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let currentID = components.first?.identity
            if currentID != blockID, result.length > 0 {
                result.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
            }
            let newBlock = currentID != blockID
            blockID = currentID
            let content = String(parsed[run.range].characters)
            if let code = components.first(where: { if case .codeBlock = $0.kind { return true }; return false }),
               case .codeBlock(let language) = code.kind {
                let storage = NSTextStorage(string: content)
                let path = ["typescript", "ts", "tsx", "javascript", "js"].contains(language ?? "") ? "hover.ts" : "hover.txt"
                Syntax.apply(to: storage, path: path, font: Theme.Code.font())
                result.append(storage)
            } else {
                var attributes = bodyAttributes
                if run.inlinePresentationIntent?.contains(.code) == true {
                    attributes[.font] = Theme.Code.font()
                    attributes[.foregroundColor] = Theme.accent
                } else if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                    attributes[.font] = NSFont.systemFont(ofSize: 12, weight: .semibold)
                } else if run.inlinePresentationIntent?.contains(.emphasized) == true {
                    attributes[.font] = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
                }
                if components.contains(where: { if case .header = $0.kind { return true }; return false }) {
                    attributes[.font] = NSFont.systemFont(ofSize: 13, weight: .semibold)
                }
                if newBlock, let item = components.first(where: { if case .listItem = $0.kind { return true }; return false }), case .listItem(let ordinal) = item.kind {
                    let ordered = components.contains { if case .orderedList = $0.kind { return true }; return false }
                    result.append(NSAttributedString(string: ordered ? "\(ordinal). " : "• ", attributes: bodyAttributes))
                }
                if let link = run.link {
                    attributes[.link] = link
                    attributes[.foregroundColor] = Theme.accent
                }
                result.append(NSAttributedString(string: content, attributes: attributes))
            }
        }
        if markdown.count > limited.count {
            result.append(NSAttributedString(string: "\n\n… Type information truncated.", attributes: bodyAttributes))
        }
        return result
    }

    private static var bodyAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.text, .paragraphStyle: paragraph]
    }
}

// Screen coordinates: keep the entire hover inside both the application window
// and its screen, preferring below the identifier and flipping when necessary.
enum HoverGeometry {
    static func frame(anchor: NSRect, contentSize: NSSize, bounds: NSRect) -> NSRect {
        let width = min(contentSize.width, bounds.width)
        let below = max(0, anchor.minY - bounds.minY - 5)
        let above = max(0, bounds.maxY - anchor.maxY - 5)
        let useBelow = below >= min(contentSize.height, 360) || below >= above
        let height = min(contentSize.height, 360, max(below, above))
        let x = max(bounds.minX, min(anchor.minX, bounds.maxX - width))
        let y = useBelow ? anchor.minY - 5 - height : anchor.maxY + 5
        return NSRect(x: x, y: max(bounds.minY, min(y, bounds.maxY - height)), width: width, height: height)
    }
}
