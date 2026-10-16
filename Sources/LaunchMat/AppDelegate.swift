import AppKit
import Carbon.HIToolbox
import LaunchMatCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = LaunchpadModel()
    private var controller: LaunchWindowController!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var hotCorner: HotCornerMonitor!
    private let pinch = PinchMonitor()
    private var trustPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            Snapshot.renderIcon(to: args[i + 1])
        }
        if args.contains("--selftest") {
            SelfTest.run(model: model)
        }
        if args.contains("--fps-bench") {
            FrameBench.run(model: model)
        }
        if args.contains("--mouse-test") {
            MouseTest.run(model: model)
        }
        if args.contains("--film-take") {
            FilmTake.run(model: model, args: args)
        }
        if let i = args.firstIndex(of: "--snapshot-guide"), i + 1 < args.count {
            GuideSnapshot.run(dir: args[i + 1])
        }
        if let i = args.firstIndex(of: "--snapshot-settings"), i + 1 < args.count {
            SettingsSnapshot.run(model: model, dir: args[i + 1])
        }
        if args.contains("--snapshot") {
            Snapshot.run(model: model, args: args)
            return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        RenameMigration.runOnce(supportDir: support, newName: "LaunchMat")
        // A fresh install (no layout yet, also none carried over from LaunchGrid) starts with the welcome guide.
        let freshInstall = !FileManager.default.fileExists(atPath: LaunchpadModel.layoutURL.path)
            && !UserDefaults.standard.bool(forKey: GuideWindowController.seenKey)
        // New users meet the guide; the "What's New" card is for people upgrading.
        if freshInstall { WhatsNew.markSeen() }
        model.openReleaseNotes = { [weak self] in self?.openURL(Links.releaseNotes) }
        model.load()
        model.prepareWallpapers()
        controller = LaunchWindowController(model: model)
        controller.mainMenu = { [weak self] in self?.makeMainMenu() ?? NSMenu() }
        setUpStatusItem()
        installEditMenu()
        registerHotkey()
        hotCorner = HotCornerMonitor { [weak self] in self?.controller.toggle() }
        hotCorner.corner = Settings.hotCorner
        pinch.onPinchIn = { [weak self] in self?.controller.show() }
        pinch.onPinchOut = { [weak self] in self?.controller.hide() }
        startPinch(prompt: false)
        if freshInstall && !args.contains("--background") {
            showGuide()
        } else if !args.contains("--background") {
            controller.show()
        }
        DispatchQueue.main.async { [weak self] in self?.offerToRemoveOldApp() }
    }

    /// 0.1.0 was called LaunchGrid. If it is still installed, offer once to move it to the Trash: running both means
    /// two grids answering the same hotkey. Its layout and settings were already copied by RenameMigration.
    private func offerToRemoveOldApp() {
        let key = "oldAppNoticeShown"
        let fm = FileManager.default
        let folders = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        guard !UserDefaults.standard.bool(forKey: key),
              let old = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: RenameMigration.oldBundleID)
                .first(where: { url in folders.contains { url.deletingLastPathComponent().standardizedFileURL == $0.standardizedFileURL } })
        else { return }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        let folder = old.deletingLastPathComponent().path
        alert.messageText = L("rename.title", "LaunchGrid is now LaunchMat")
        alert.informativeText = L("rename.body", "Your pages, folders and settings came along. The old LaunchGrid app is still in \(folder), and running both means two grids on the same hotkey. Move LaunchGrid to the Trash? If you used Launch at Login, turn it on again in LaunchMat’s Settings.")
        alert.addButton(withTitle: L("rename.trash", "Move to Trash"))
        alert.addButton(withTitle: L("rename.keep", "Keep It"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: RenameMigration.oldBundleID) { app.terminate() }
        NSWorkspace.shared.recycle([old]) { _, error in
            if let error { NSLog("LaunchMat: could not move LaunchGrid to the Trash: \(error.localizedDescription)") }
        }
    }

    /// Clicking the app in the Dock / Finder again toggles the grid, like Launchpad's Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.toggle()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { model.saveNow() }

    /// Default ⇧⌘Space: ⌃Space/⌃⌥Space switch input sources on Macs with several keyboards (e.g. Chinese).
    private func registerHotkey() {
        hotKey = nil
        guard let key = Settings.hotkey.key else { return }
        hotKey = HotKey(keyCode: key.code, modifiers: key.modifiers) { [weak self] in self?.controller.toggle() }
    }

    /// An accessory app has no visible menu bar, but ⌘C/⌘V/⌘A in text fields still need the Edit menu items.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - Pinch (needs Accessibility)

    private func startPinch(prompt: Bool) {
        trustPoll?.invalidate()
        let fingers = Settings.pinch
        guard fingers != .off else {
            pinch.stop()
            return
        }
        if pinch.start(fingers: fingers) { return }
        if prompt { PinchMonitor.requestTrust() }
        // Start as soon as the user flips the switch in System Settings.
        trustPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, PinchMonitor.isTrusted else { return }
                timer.invalidate()
                self.pinch.start(fingers: Settings.pinch)
            }
        }
    }

    // MARK: - About

    /// The version as the About panel shows it: "0.1.2 (3)", plus the short commit on builds that aren't a notarized
    /// release ("0.1.2 (3) · bbdcb5a"), so a test build says which one it is.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        var line = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        if let commit = info["LaunchMatCommit"] as? String, !commit.isEmpty { line += " · \(commit)" }
        return line
    }

    @objc func showAbout() {
        controller?.hide()
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: Self.versionLine, .version: ""])
    }

    // MARK: - Menus

    /// The menu bar icon: a click opens (or closes) the grid; a right-click or Control-click shows its menu (only
    /// opening the grid, settings, feedback, about and quit; everything else lives in the settings window or the
    /// main menu). Jimmy's call, whatever LaunchOS does.
    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "LaunchMat")
        statusMenu.identifier = NSUserInterfaceItemIdentifier("status")
        statusMenu.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private let statusMenu = NSMenu()

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            // The menu belongs to the item only while it shows, so the next click opens the grid again.
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            controller.toggle()
        }
    }

    /// The main menu, opened by a right-click on blank grid space or the ⋯ button next to the search field.
    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier("main")
        menu.delegate = self
        return menu
    }

    private func item(_ title: String, _ action: Selector?, tag: Int = 0, on: Bool = false, key: String = "",
                      symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.tag = tag
        item.state = on ? .on : .off
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func submenu(_ title: String, symbol: String? = nil, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let menu = NSMenu()
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.identifier?.rawValue == "main" {
            menu.addItem(item(L("menu.settings", "Settings…"), #selector(showSettings), key: ",", symbol: "gearshape"))
            menu.addItem(.separator())
            let hidden = model.layout.hidden.count
            menu.addItem(item(hidden > 0 ? L("menu.hiddenAppsCount", "Hidden Apps (\(hidden))…") : L("menu.hiddenApps", "Hidden Apps…"),
                              #selector(showHiddenApps), symbol: "eye.slash"))
            menu.addItem(submenu(L("menu.gridSize", "Grid Size"), symbol: "square.grid.2x2", GridSize.presets.enumerated().map { i, size in
                item(size.label, #selector(pickGrid(_:)), tag: i, on: size == model.gridSize)
            }))
            menu.addItem(.separator())
            menu.addItem(item(L("menu.about", "About LaunchMat"), #selector(showAbout), symbol: "info.circle"))
            menu.addItem(item(L("menu.restart", "Restart LaunchMat"), #selector(restart), symbol: "arrow.clockwise"))
            menu.addItem(item(L("menu.quit", "Quit LaunchMat"), #selector(quit), symbol: "power"))
        } else {
            menu.addItem(item(L("menu.open", "Open LaunchMat"), #selector(showGrid)))
            menu.addItem(item(L("menu.settings", "Settings…"), #selector(showSettings), key: ","))
            menu.addItem(item(L("menu.feedback", "Send Feedback…"), #selector(sendFeedback)))
            menu.addItem(item(L("menu.about", "About LaunchMat"), #selector(showAbout)))
            menu.addItem(.separator())
            menu.addItem(item(L("menu.quit", "Quit LaunchMat"), #selector(confirmQuit), key: "q"))
        }
    }

    private lazy var settings = SettingsWindowController(model: model, actions: self, showGuide: { [weak self] in self?.showGuide() })
    private lazy var guide: GuideWindowController = {
        let guide = GuideWindowController(model: model, actions: self)
        guide.onFinish = { [weak self] in self?.controller.show() }
        return guide
    }()

    /// The welcome guide; the grid closes first (it sits above every window).
    func showGuide() {
        controller.hide()
        settings.close()
        guide.show()
    }

    @objc private func showGrid() { controller.show() }
    @objc private func showSettings() {
        controller.hide()
        settings.show()
    }
    @objc private func showHiddenApps() {
        controller.hide()
        settings.show(.apps)
    }
    @objc private func sendFeedback() { openURL(Links.feedback) }
    @objc private func pickGrid(_ sender: NSMenuItem) { model.setGrid(GridSize.presets[sender.tag]) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Quitting from the menu bar asks first: without the app running, the hotkey and the menu bar icon are gone too.
    @objc private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = L("quit.title", "Quit LaunchMat?")
        alert.informativeText = L("quit.body", "The hotkey, hot corner and menu bar icon stop working until you open LaunchMat again.")
        alert.addButton(withTitle: L("quit.quit", "Quit"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    /// Opens a second copy of the app and quits this one.
    @objc private func restart() {
        model.saveNow()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--background"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Settings actions

extension AppDelegate: AppActions, GuideActions {
    func setHotkey(_ choice: HotkeyChoice) {
        Settings.hotkey = choice
        registerHotkey()
    }

    func setHotCorner(_ corner: HotCorner) {
        Settings.hotCorner = corner
        hotCorner.corner = corner
    }

    func setPinch(_ fingers: PinchFingers) {
        Settings.pinch = fingers
        if fingers == .fourOrFive && PinchMonitor.systemFourFingerPinchEnabled {
            Uninstaller.alert(L("pinchConflict.title", "The system four-finger pinch is on"),
                              L("pinchConflict.body", "macOS also uses this gesture. Turn off System Settings › Trackpad › More Gestures › “Launchpad” / “Apps” so only LaunchMat responds."))
        }
        if fingers != .off && !PinchMonitor.isTrusted {
            let alert = NSAlert()
            alert.messageText = L("accessibility.title", "Allow LaunchMat in Accessibility")
            alert.informativeText = L("accessibility.body", "LaunchMat needs this only to read the trackpad pinch.")
            alert.addButton(withTitle: L("accessibility.open", "Open System Settings"))
            alert.addButton(withTitle: L("common.cancel", "Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                // Puts LaunchMat in the list (macOS shows its own prompt the first time), then opens the list.
                PinchMonitor.requestTrust()
                openAccessibilitySettings()
            }
        }
        // Starts now if allowed, otherwise as soon as it is.
        startPinch(prompt: false)
    }

    func setGridSize(_ size: GridSize) { model.setGrid(size) }

    func setLaunchAtLogin(_ on: Bool) {
        if let error = LoginItem.set(on) {
            Uninstaller.alert(L("login.error", "Could not change Launch at Login"), error)
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openURL(_ url: URL) {
        controller.hide()
        NSWorkspace.shared.open(url)
    }

    func revealLayoutFile() {
        model.saveNow()
        NSWorkspace.shared.activateFileViewerSelecting([LaunchpadModel.layoutURL])
    }

    func confirmResetLayout() {
        let alert = NSAlert()
        alert.messageText = L("reset.title", "Reset your layout?")
        alert.informativeText = L("reset.body", "Your pages, folders and hidden apps go back to the default arrangement.")
        alert.addButton(withTitle: L("reset.reset", "Reset"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { model.resetLayout() }
    }

    @discardableResult func importLegacyLayout() -> Bool {
        let pages: [[LegacyLaunchpad.Item]]
        do {
            guard let path = LegacyLaunchpad.defaultPath else { throw LegacyLaunchpad.ReadError.notFound("(unknown)") }
            pages = try LegacyLaunchpad.read(path: path)
        } catch {
            Uninstaller.alert(L("import.nothing.title", "Nothing to import"),
                              "\(error)\n\n" + L("import.nothing.body", "This only works on a Mac that used Launchpad before macOS 26."))
            return false
        }
        let folders = pages.flatMap { $0 }.filter { if case .folder = $0 { return true } else { return false } }.count
        let alert = NSAlert()
        let pageCount = pages.count
        alert.messageText = L("import.title", "Import the system Launchpad layout?")
        alert.informativeText = L("import.body", "Found \(pageCount) pages and \(folders) folders. Your current LaunchMat layout will be replaced; apps Launchpad didn’t know about are added at the end.")
        alert.addButton(withTitle: L("import.import", "Import"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let placed = model.applyImported(pages)
        Uninstaller.alert(L("import.done.title", "Imported"), L("import.done.body", "\(placed) apps placed from the Launchpad layout."))
        return true
    }
}

/// `LaunchMat --snapshot out.png [--width W --height H] [--query q] [--page n] [--open-folder] [--fresh]`
/// renders the UI off-screen to a PNG and exits. Never writes the user's layout file.
@MainActor
enum Snapshot {
    /// 1024px app icon: dark rounded square with a 3×3 grid of colored tiles.
    static func renderIcon(to path: String) -> Never {
        let colors: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .yellow, .red, .indigo]
        let icon = ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
            VStack(spacing: 46) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 46) {
                        ForEach(0..<3, id: \.self) { c in
                            RoundedRectangle(cornerRadius: 42, style: .continuous)
                                .fill(colors[r * 3 + c].gradient)
                                .frame(width: 170, height: 170)
                        }
                    }
                }
            }
        }
        .frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { exit(1) }
        exit(0)
    }

    static func run(model: LaunchpadModel, args: [String]) {
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let output = value("--snapshot") ?? "snapshot.png"
        let size = NSSize(width: Double(value("--width") ?? "") ?? 1512, height: Double(value("--height") ?? "") ?? 982)
        model.persistenceEnabled = false
        model.load(fresh: args.contains("--fresh"), sync: true)
        if let screen = NSScreen.main { model.wallpaper = Wallpaper.blurred(for: screen) }
        model.metrics = GridMetrics(size: size, cols: model.gridSize.cols, rows: model.gridSize.rows)
        if let q = value("--query") { model.query = q }
        if let p = value("--page").flatMap(Int.init) { model.currentPage = min(p, model.pageCount - 1) }
        if let s = value("--select").flatMap(Int.init) { model.selection = s }
        if args.contains("--open-folder") {
            model.openFolder = model.firstFolderID
            model.folderPresentation.expanded = true // as it is once open
        }
        if args.contains("--whats-new") { model.whatsNew = WhatsNew.current }

        let host = NSHostingView(rootView: RootView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try png.write(to: URL(fileURLWithPath: output))
            print("snapshot: \(output) apps=\(model.apps.count) pages=\(model.pageCount) results=\(model.results.count)")
            exit(0)
        } catch {
            print("snapshot failed: \(error)")
            exit(1)
        }
    }
}
