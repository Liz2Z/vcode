import AppKit

final class ResultTableView: NSTableView {
    var onEscape: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if let action { NSApp.sendAction(action, to: target, from: self) }
        } else if event.keyCode == 53 { onEscape?() }
        else { super.keyDown(with: event) }
    }

    func moveSelection(by delta: Int) {
        var index = selectedRow < 0 ? (delta > 0 ? -1 : numberOfRows) : selectedRow
        while true {
            index += delta
            guard index >= 0, index < numberOfRows else { return }
            if delegate?.tableView?(self, shouldSelectRow: index) != false {
                selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                scrollRowToVisible(index)
                return
            }
        }
    }
}
