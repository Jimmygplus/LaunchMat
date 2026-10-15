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
            menu.add("Open Folder", symbol: "folder") { model.activate(.folder(id)) }
            menu.addItem(.separator())
            menu.addItem(movePages(model: model, entries: [entry]))
        }
        return menu
    }

    private static func app(model: LaunchpadModel, path: String, folder: UUID?, into menu: NSMenu) {
        let url = URL(fileURLWithPath: path)
        menu.add("Open", symbol: "arrow.up.forward.app") { model.launch(path) }
        menu.add("Show in Finder", symbol: "folder") { model.showInFinder(path) }
        if Dock.contains(url) {
            menu.add("In the Dock", symbol: "dock.rectangle", enabled: false) {}
        } else {
            menu.add("Add to Dock", symbol: "dock.rectangle") { Dock.add(url) }
        }
        if let running = model.runningApp(path) {
            menu.addItem(.separator())
            menu.add("Quit", symbol: "xmark.circle") { running.terminate() }
            menu.add("Force Quit…", symbol: "exclamationmark.octagon") {
                model.dismiss()
                let alert = NSAlert()
                alert.messageText = "Force quit “\(model.title(for: .app(path)))”?"
                alert.informativeText = "Anything not saved in it will be lost."
                alert.addButton(withTitle: "Force Quit")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { running.forceTerminate() }
            }
        }
        menu.addItem(.separator())
        menu.addItem(movePages(model: model, entries: [.app(path)], folders: [path], from: folder))
        if let folder {
            menu.add("Remove from Folder", symbol: "folder.badge.minus") { model.removeFromFolder(path, folder: folder) }
        }
        menu.add("Hide", symbol: "eye.slash") { model.hide(path) }
        menu.addItem(.separator())
        menu.add("Get Info", symbol: "info.circle") {
            model.dismiss()
            getInfo(path)
        }
        menu.add("Rename…", symbol: "pencil") { model.renaming = path }
        if model.canUninstall(path) {
            menu.addItem(.separator())
            menu.add("Move to Trash…", symbol: "trash") { model.uninstall(path) }
        }
    }

    private static func multi(model: LaunchpadModel, into menu: NSMenu) {
        let entries = model.layout.pages.flatMap { $0 }.filter { model.selected.contains($0) }
        let apps = model.selectedApps
        menu.add("\(entries.count) Selected", enabled: false) {}
        menu.addItem(.separator())
        menu.add("New Folder with \(apps.count) Apps", symbol: "folder.badge.plus", enabled: apps.count >= 2) { model.groupSelected() }
        let folders = model.folderList
        if !folders.isEmpty, !apps.isEmpty {
            let add = NSMenuItem(title: "Add to Folder", action: nil, keyEquivalent: "")
            add.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let sub = NSMenu()
            for f in folders { sub.add(f.name) { model.move(apps, toFolder: f.id) } }
            add.submenu = sub
            menu.addItem(add)
        }
        menu.addItem(.separator())
        menu.addItem(movePages(model: model, entries: entries))
        menu.add("Hide \(apps.count) Apps", symbol: "eye.slash", enabled: !apps.isEmpty) { model.hideSelected() }
        menu.addItem(.separator())
        menu.add("Deselect All") { model.selected.removeAll() }
    }

    /// Move to ▸ Page 1…N (the item's own page disabled) and, for apps, the folders.
    private static func movePages(model: LaunchpadModel, entries: [Entry], folders apps: [String] = [], from folder: UUID? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "arrow.right.square", accessibilityDescription: nil)
        let sub = NSMenu()
        sub.autoenablesItems = false
        let current = entries.count == 1 && folder == nil ? model.layout.locate(entries[0])?.page : nil
        for page in 0..<model.layout.pages.count {
            sub.add("Page \(page + 1)", enabled: page != current) { model.move(entries, toPage: page) }
        }
        sub.add("New Page") { model.move(entries, toPage: model.layout.pages.count) }
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
