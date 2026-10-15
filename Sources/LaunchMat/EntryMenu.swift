import AppKit
import LaunchMatCore

/// The right-click menus for icons, built when the menu opens (so cells carry no menu of their own):
/// - an app: Open, Show in Finder, Add to Dock — Quit / Force Quit… (while it runs) — Move to ▸, (Remove from Folder),
///   Hide — Get Info, Rename… — Move to Trash…
/// - a folder: Open Folder — Move to ▸
/// - several ⌘-selected items: "N Selected" — New Folder with N Apps, Add to Folder ▸ — Move to ▸, Hide N Apps —
///   Deselect All
@MainActor
enum EntryMenu {
    static func make(model: LaunchpadModel, entry: Entry, folder: UUID?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if folder == nil, model.selected.count > 1, model.selected.contains(entry) {
            multi(model: model, into: menu)
            return menu
        }
        switch entry {
        case .app(let path):
            app(model: model, path: path, folder: folder, into: menu)
        case .folder(let id):
            menu.add(L("entry.openFolder", "Open Folder"), symbol: "folder") { model.activate(.folder(id)) }
            menu.addItem(.separator())
            menu.addItem(movePages(model: model, entries: [entry]))
        }
        return menu
    }

    private static func app(model: LaunchpadModel, path: String, folder: UUID?, into menu: NSMenu) {
        let url = URL(fileURLWithPath: path)
        menu.add(L("entry.open", "Open"), symbol: "arrow.up.forward.app") { model.launch(path) }
        menu.add(L("entry.showInFinder", "Show in Finder"), symbol: "folder") { model.showInFinder(path) }
        if Dock.contains(url) {
            menu.add(L("entry.inDock", "In the Dock"), symbol: "dock.rectangle", enabled: false) {}
        } else {
            menu.add(L("entry.addToDock", "Add to Dock"), symbol: "dock.rectangle") { Dock.add(url) }
        }
        if let running = model.runningApp(path) {
            menu.addItem(.separator())
            menu.add(L("entry.quit", "Quit"), symbol: "xmark.circle") { running.terminate() }
            menu.add(L("entry.forceQuit", "Force Quit…"), symbol: "exclamationmark.octagon") {
                model.dismiss()
                let alert = NSAlert()
                let name = model.title(for: .app(path))
                alert.messageText = L("forceQuit.title", "Force quit “\(name)”?")
                alert.informativeText = L("forceQuit.body", "Anything not saved in it will be lost.")
                alert.addButton(withTitle: L("forceQuit.button", "Force Quit"))
                alert.addButton(withTitle: L("common.cancel", "Cancel"))
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { running.forceTerminate() }
            }
        }
        menu.addItem(.separator())
        menu.addItem(movePages(model: model, entries: [.app(path)], folders: [path], from: folder))
        if let folder {
            menu.add(L("entry.removeFromFolder", "Remove from Folder"), symbol: "folder.badge.minus") { model.removeFromFolder(path, folder: folder) }
        }
        menu.add(L("entry.hide", "Hide"), symbol: "eye.slash") { model.hide(path) }
        menu.addItem(.separator())
        menu.add(L("entry.getInfo", "Get Info"), symbol: "info.circle") {
            model.dismiss()
            getInfo(path)
        }
        menu.add(L("entry.rename", "Rename…"), symbol: "pencil") { model.renaming = path }
        if model.canUninstall(path) {
            menu.addItem(.separator())
            menu.add(L("entry.trash", "Move to Trash…"), symbol: "trash") { model.uninstall(path) }
        }
    }

    private static func multi(model: LaunchpadModel, into menu: NSMenu) {
        let entries = model.layout.pages.flatMap { $0 }.filter { model.selected.contains($0) }
        let apps = model.selectedApps
        let count = entries.count, appCount = apps.count
        menu.add(L("multi.selected", "\(count) Selected"), enabled: false) {}
        menu.addItem(.separator())
        menu.add(appCount == 1 ? L("multi.newFolderOne", "New Folder with 1 App") : L("multi.newFolder", "New Folder with \(appCount) Apps"), symbol: "folder.badge.plus", enabled: apps.count >= 2) { model.groupSelected() }
        let folders = model.folderList
        if !folders.isEmpty, !apps.isEmpty {
            let add = NSMenuItem(title: L("multi.addToFolder", "Add to Folder"), action: nil, keyEquivalent: "")
            add.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let sub = NSMenu()
            for f in folders { sub.add(f.name) { model.move(apps, toFolder: f.id) } }
            add.submenu = sub
            menu.addItem(add)
        }
        menu.addItem(.separator())
        menu.addItem(movePages(model: model, entries: entries))
        menu.add(appCount == 1 ? L("multi.hideOne", "Hide 1 App") : L("multi.hide", "Hide \(appCount) Apps"), symbol: "eye.slash", enabled: !apps.isEmpty) { model.hideSelected() }
        menu.addItem(.separator())
        menu.add(L("multi.deselectAll", "Deselect All")) { model.selected.removeAll() }
    }

    /// Move to ▸ Page 1…N (the item's own page disabled) and, for apps, the folders.
    private static func movePages(model: LaunchpadModel, entries: [Entry], folders apps: [String] = [], from folder: UUID? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: L("entry.moveTo", "Move to"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "arrow.right.square", accessibilityDescription: nil)
        let sub = NSMenu()
        sub.autoenablesItems = false
        let current = entries.count == 1 && folder == nil ? model.layout.locate(entries[0])?.page : nil
        for page in 0..<model.layout.pages.count {
            sub.add(L("entry.page", "Page \(page + 1)"), enabled: page != current) { model.move(entries, toPage: page) }
        }
        sub.add(L("entry.newPage", "New Page")) { model.move(entries, toPage: model.layout.pages.count) }
        let folders = model.folderList.filter { $0.id != folder }
        if !apps.isEmpty, !folders.isEmpty {
            sub.addItem(.separator())
            for f in folders { sub.add(f.name, symbol: "folder") { model.move(apps, toFolder: f.id) } }
        }
        item.submenu = sub
        return item
    }

    /// Finder's Get Info window for the app (Finder may ask once to allow LaunchMat to control it).
    private static func getInfo(_ path: String) {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(escaped)" as alias)
        end tell
        """
        DispatchQueue.main.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if error != nil { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
    }
}

/// Menu items that run a closure.
private final class ClosureItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: "")
        self.handler = handler
        target = self
    }

    @objc private func run() { handler?() }
}

private extension NSMenu {
    func add(_ title: String, symbol: String? = nil, enabled: Bool = true, _ handler: @escaping () -> Void) {
        let item = ClosureItem(title, handler: handler)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        item.isEnabled = enabled
        addItem(item)
    }
}
