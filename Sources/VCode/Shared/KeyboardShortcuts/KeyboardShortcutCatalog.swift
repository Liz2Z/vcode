import AppKit

struct KeyboardShortcutEntry: Equatable {
    let group: String
    let title: String
    let keys: String
    var detail = ""
    var aliases = ""

    func matches(_ query: String) -> Bool {
        let text = "\(group) \(title) \(keys) \(detail) \(aliases)"
        return query.split(whereSeparator: { $0.isWhitespace || $0 == "+" }).allSatisfy { text.localizedStandardContains(String($0)) }
    }
}

enum KeyboardShortcutCatalog {
    static let menuIdentifier = NSUserInterfaceItemIdentifier("keyboard-shortcuts")
    static let chord = "⌘K ⌘S"
    // AppKit injects extra system commands and alternate copies into menus.
    // Keep only the exact VCode command items registered by the menu builder.
    private static let commands = NSHashTable<NSMenuItem>(options: [.weakMemory, .objectPointerPersonality])

    static func register(_ item: NSMenuItem) { commands.add(item) }

    static func entries(in menu: NSMenu?) -> [KeyboardShortcutEntry] {
        var entries: [KeyboardShortcutEntry] = []
        func read(_ menu: NSMenu, group: String) {
            for item in menu.items where !item.isSeparatorItem {
                if let submenu = item.submenu { read(submenu, group: item.title); continue }
                guard commands.contains(item) else { continue }
                if item.identifier == menuIdentifier {
                    entries.append(KeyboardShortcutEntry(group: group, title: item.title.replacingOccurrences(of: "…", with: ""), keys: chord,
                        detail: "Press ⌘K, then ⌘S", aliases: "command cmd keyboard shortcuts 快捷键 列表"))
                } else if !item.keyEquivalent.isEmpty, item.action != nil {
                    let flags = item.keyEquivalentModifierMask
                    let aliases = [(NSEvent.ModifierFlags.command, "command cmd"), (.control, "control ctrl"), (.option, "option alt"), (.shift, "shift")]
                        .filter { flags.contains($0.0) }.map(\.1).joined(separator: " ")
                    entries.append(KeyboardShortcutEntry(group: group, title: item.title.replacingOccurrences(of: "…", with: ""),
                        keys: displayKey(item.keyEquivalent, modifiers: flags), aliases: aliases))
                }
            }
        }
        if let menu { read(menu, group: "Application") }
        entries += [
            KeyboardShortcutEntry(group: "Code", title: "Go to Definition / Find References", keys: "⌘Click",
                detail: "Usage → definition · Definition → references", aliases: "command cmd click 跳转 定义 引用"),
            KeyboardShortcutEntry(group: "Code", title: "Show Type Information", keys: "Hover", detail: "Hover over a TypeScript identifier", aliases: "类型 悬停"),
            KeyboardShortcutEntry(group: "Lists & Popovers", title: "Select Previous / Next Result", keys: "↑ / ↓", aliases: "up down 上下 选择"),
            KeyboardShortcutEntry(group: "Lists & Popovers", title: "Open Selected Result", keys: "Return", aliases: "enter 回车 打开"),
            KeyboardShortcutEntry(group: "Lists & Popovers", title: "Close Popover / Cancel", keys: "Escape", aliases: "esc 关闭 取消")
        ]
        return entries
    }

    static func displayKey(_ key: String, modifiers: NSEvent.ModifierFlags) -> String {
        let flags = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let prefix = flags.filter { modifiers.contains($0.0) }.map(\.1).joined()
        let names = [String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑", String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
                     String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←", String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
                     "\r": "Return", "\u{1b}": "Escape", "\t": "Tab", " ": "Space"]
        return prefix + (names[key] ?? key.uppercased())
    }
}

struct KeyboardShortcutChord {
    enum Result: Equatable { case passThrough, waiting, cancelled, open }
    private(set) var deadline: TimeInterval?
    static let timeout: TimeInterval = 2
    mutating func cancel() { deadline = nil }

    mutating func handle(_ event: NSEvent, now: TimeInterval) -> Result {
        if let deadline, now > deadline { cancel() }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if deadline != nil {
            if event.keyCode == 53 { cancel(); return .cancelled }
            if modifiers == .command, key == "s" { cancel(); return .open }
            if modifiers == .command, key == "k" { return .waiting }
            cancel()
            return .passThrough
        }
        if modifiers == .command, key == "k", !event.isARepeat {
            deadline = now + Self.timeout
            return .waiting
        }
        return .passThrough
    }
}
