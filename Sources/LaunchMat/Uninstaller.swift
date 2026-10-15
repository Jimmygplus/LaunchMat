import AppKit
import LaunchMatCore

/// Moves an app (and optionally its ~/Library leftovers) to the Trash. Never deletes permanently.
@MainActor
enum Uninstaller {
    static func canUninstall(_ app: AppRecord) -> Bool {
        // System apps (incl. Safari, a symlink into /System/Cryptexes) can't be removed; App Store apps can.
        !URL(fileURLWithPath: app.id).resolvingSymlinksInPath().path.hasPrefix("/System/")
            && app.bundleID != Bundle.main.bundleIdentifier
    }

    /// Leftovers by bundle ID / name, skipping any that another installed copy (e.g. a beta, or a second
    /// Python's IDLE) shares, because that app still uses them.
    static func relatedFiles(for app: AppRecord, installed: [AppRecord]) -> [URL] {
        let others = installed.filter { $0.id != app.id }
        let sharedID = app.bundleID.map { id in others.contains { $0.bundleID == id } } ?? true
        let sharedName = others.contains { $0.bundleName == app.bundleName || $0.name == app.name }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return RelatedFiles.find(bundleID: sharedID ? nil : app.bundleID, appName: sharedName ? "" : app.bundleName,
                                 library: library)
    }

    /// Asks, then trashes. `completion(true)` when the app bundle is gone.
    static func confirmAndUninstall(_ app: AppRecord, installed: [AppRecord], completion: @escaping (Bool) -> Void) {
        if let id = app.bundleID, !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            let name = app.name
            alert(L("uninstall.running.title", "“\(name)” is running"), L("uninstall.running.body", "Quit it first, then try again."))
            completion(false)
            return
        }
        let related = relatedFiles(for: app, installed: installed)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let a = NSAlert()
        a.alertStyle = .warning
        a.icon = NSWorkspace.shared.icon(forFile: app.id)
        let name = app.name
        a.messageText = L("uninstall.title", "Move “\(name)” to the Trash?")
        if related.isEmpty {
            a.informativeText = L("uninstall.noFiles", "No related files were found in your Library folder.")
        } else {
            let list = related.prefix(12).map { "• " + $0.path.replacingOccurrences(of: home, with: "~") }.joined(separator: "\n")
            let extra = related.count - 12
            let more = extra > 0 ? "\n" + L("uninstall.more", "… and \(extra) more") : ""
            a.informativeText = L("uninstall.found", "Related files found:") + "\n\(list)\(more)\n\n"
                + L("uninstall.putBack", "Everything goes to the Trash, so you can put it back.")
        }
        // The safer choice is the default button.
        let fileCount = related.count
        a.addButton(withTitle: related.isEmpty ? L("uninstall.trash", "Move to Trash") : L("uninstall.appOnly", "Move App Only"))
        if fileCount == 1 { a.addButton(withTitle: L("uninstall.appAndOne", "Move App and 1 File")) }
        if fileCount > 1 { a.addButton(withTitle: L("uninstall.appAndFiles", "Move App and \(fileCount) Files")) }
        a.addButton(withTitle: L("common.cancel", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        let response = a.runModal()
        let files: [URL]
        switch response {
        case .alertFirstButtonReturn: files = []
        case .alertSecondButtonReturn where !related.isEmpty: files = related
        default:
            completion(false)
            return
        }
        trash([URL(fileURLWithPath: app.id)] + files) { failed in
            let appGone = !FileManager.default.fileExists(atPath: app.id)
            if !failed.isEmpty {
                let names = failed.map { $0.path.replacingOccurrences(of: home, with: "~") }.joined(separator: "\n")
                alert(L("uninstall.failed", "Some items could not be moved to the Trash"), names)
            }
            completion(appGone)
        }
    }

    /// NSWorkspace first; anything it can't move (root-owned bundles) goes through Finder, which asks for a password.
    private static func trash(_ urls: [URL], completion: @escaping ([URL]) -> Void) {
        NSWorkspace.shared.recycle(urls) { moved, _ in
            MainActor.assumeIsolated {
                let left = urls.filter { moved[$0] == nil && FileManager.default.fileExists(atPath: $0.path) }
                completion(left.filter { !finderDelete($0) })
            }
        }
    }

    private static func finderDelete(_ url: URL) -> Bool {
        // `as alias` would resolve a symlink to its target; never hand Finder a symlink.
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        guard type != .typeSymbolicLink else { return false }
        let path = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "with timeout of 600 seconds\ntell application \"Finder\" to delete (POSIX file \"\(path)\" as alias)\nend timeout")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil && !FileManager.default.fileExists(atPath: url.path)
    }

    static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
