import AppKit

enum StandardEditCommands {
    static func addUndoRedo(to menu: NSMenu) {
        let undo = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        undo.keyEquivalentModifierMask = .command
        // AppKit compares the shifted character as well as the modifier mask.
        let redo = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(undo)
        menu.addItem(redo)
    }
}
