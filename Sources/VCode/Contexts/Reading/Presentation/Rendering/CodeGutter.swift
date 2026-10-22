import AppKit
import CoreText

final class CodeGutter: NSRulerView {
    var lines: [CodeLine] = []
    weak var code: NSTextView?

    init(scroll: NSScrollView, text: NSTextView) {
        code = text
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = text
        ruleThickness = 58
    }
    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        guard code != nil, let scrollView else { return }
        let offset = scrollView.contentView.bounds.minY
        let first = max(0, Int((offset - Theme.Code.verticalInset) / Theme.Code.lineHeight))
        let last = min(lines.count, first + Int(bounds.height / Theme.Code.lineHeight) + 3)
        guard first < last else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.Code.font(size: Theme.Code.fontSize - 1), .foregroundColor: Theme.muted]
        let baseline = Theme.Code.baseline(for: Theme.Code.font())
        for index in first..<last {
            let line = lines[index]
            let y = CGFloat(index) * Theme.Code.lineHeight + Theme.Code.verticalInset - offset
            let color: NSColor? = line.kind == .added ? Theme.green : line.kind == .removed ? Theme.red : nil
            if let color {
                color.withAlphaComponent(0.8).setFill()
                NSRect(x: bounds.width - 3, y: y, width: 2, height: Theme.Code.lineHeight).fill()
            }
            if let number = line.number, let context = NSGraphicsContext.current?.cgContext {
                let label = CTLineCreateWithAttributedString(NSAttributedString(string: "\(number)", attributes: attributes))
                let width = CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil))
                context.saveGState()
                context.translateBy(x: bounds.width - 13 - width, y: y + baseline)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                context.textPosition = .zero
                CTLineDraw(label, context)
                context.restoreGState()
            }
        }
    }
}
