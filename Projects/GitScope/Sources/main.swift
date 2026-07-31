import AppKit
import Sparkle

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

// Programmatic main menu. Standard edit shortcuts (⌘V, ⌘C, ⌘X, ⌘Z…) are
// dispatched through menu items down the responder chain, so a complete
// Edit menu is what makes paste work in text fields.
let mainMenu = NSMenu()

// App menu.
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(
    withTitle: "About GitScope",
    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
    keyEquivalent: ""
)
appMenu.addItem(.separator())
let checkUpdatesItem = NSMenuItem(
    title: "检查更新…",
    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
    keyEquivalent: ""
)
checkUpdatesItem.target = UpdaterController.shared.menuTarget
appMenu.addItem(checkUpdatesItem)
appMenu.addItem(.separator())
appMenu.addItem(
    withTitle: "Hide GitScope",
    action: #selector(NSApplication.hide(_:)),
    keyEquivalent: "h"
)
appMenu.addItem(.separator())
appMenu.addItem(
    withTitle: "Quit GitScope",
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q"
)
appMenuItem.submenu = appMenu

// Edit menu — full standard set so all text fields get the usual shortcuts.
let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu

// Window menu (minimize / zoom / cycle windows).
let windowMenuItem = NSMenuItem()
mainMenu.addItem(windowMenuItem)
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(
    withTitle: "Minimize",
    action: #selector(NSWindow.performMiniaturize(_:)),
    keyEquivalent: "m"
)
windowMenu.addItem(
    withTitle: "Zoom",
    action: #selector(NSWindow.performZoom(_:)),
    keyEquivalent: ""
)
windowMenuItem.submenu = windowMenu
app.windowsMenu = windowMenu

app.mainMenu = mainMenu
app.run()
