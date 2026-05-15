import Cocoa

/// LSUIElement 应用默认没有主菜单，导致设置窗口里的 NSTextField 无法响应 Cmd+C/V/X/A——
/// 文本控件的快捷键依赖 mainMenu 中标准 selector（cut: / copy: / paste: / selectAll: 等）的 keyEquivalent。
/// 这里在启动时挂一个最小化主菜单：包含一个 App 子菜单（Quit）和一个 Edit 子菜单（撤销 / 剪切 / 复制 / 粘贴等）。
/// (LSUIElement apps have no main menu by default, so NSTextField in our settings windows cannot
///  receive Cmd+C/V/X/A — text-control shortcuts route through standard selectors registered on
///  the main menu. We install a minimal main menu at launch with an App submenu (Quit) and an
///  Edit submenu (Undo / Cut / Copy / Paste / etc.).)
enum MainMenuInstaller {
    static func install() {
        let main = NSMenu()
        main.addItem(makeAppMenuItem())
        main.addItem(makeEditMenuItem())
        NSApp.mainMenu = main
    }

    private static func makeAppMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "AtomVoice"
        menu.addItem(
            withTitle: String(format: loc("menu.app.quit"), appName),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.submenu = menu
        return item
    }

    private static func makeEditMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: loc("menu.edit"))

        // Undo / Redo 由 NSText / NSTextView 的 undoManager 处理，selector 用字符串避免 Swift 编译报错
        // (Undo/Redo dispatch to NSText/NSTextView's undoManager; selectors are strings to dodge Swift availability.)
        menu.addItem(
            withTitle: loc("menu.edit.undo"),
            action: NSSelectorFromString("undo:"),
            keyEquivalent: "z"
        )
        let redo = menu.addItem(
            withTitle: loc("menu.edit.redo"),
            action: NSSelectorFromString("redo:"),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(NSMenuItem.separator())

        menu.addItem(
            withTitle: loc("menu.edit.cut"),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        menu.addItem(
            withTitle: loc("menu.edit.copy"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: loc("menu.edit.paste"),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        let pasteMatch = menu.addItem(
            withTitle: loc("menu.edit.pasteAndMatchStyle"),
            action: NSSelectorFromString("pasteAsPlainText:"),
            keyEquivalent: "v"
        )
        pasteMatch.keyEquivalentModifierMask = [.command, .shift, .option]
        menu.addItem(
            withTitle: loc("menu.edit.delete"),
            action: #selector(NSText.delete(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: loc("menu.edit.selectAll"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )

        item.submenu = menu
        return item
    }
}
