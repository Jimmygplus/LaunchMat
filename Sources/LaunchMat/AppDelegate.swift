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
        if args.contains("--snapshot") {
            Snapshot.run(model: model, args: args)
            return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        RenameMigration.runOnce(supportDir: support, newName: "LaunchMat")
        model.load()
        model.prepareWallpapers()
        controller = LaunchWindowController(model: model)
        controller.mainMenu = { [weak self] in
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }
        setUpStatusItem()
        installEditMenu()
        registerHotkey()
        hotCorner = HotCornerMonitor { [weak self] in self?.controller.toggle() }
        hotCorner.corner = Settings.hotCorner
        pinch.onPinchIn = { [weak self] in self?.controller.show() }
        pinch.onPinchOut = { [weak self] in self?.controller.hide() }
        startPinch(prompt: false)
        if !args.contains("--background") { controller.show() }
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
        alert.messageText = "LaunchGrid is now LaunchMat"
        alert.informativeText = "Your pages, folders and settings came along. The old LaunchGrid app is still in "
            + "\(old.deletingLastPathComponent().path), and running both means two grids on the same hotkey. "
            + "Move LaunchGrid to the Trash? If you used Launch at Login, turn it on again in the LaunchMat menu."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep It")
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

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "LaunchMat")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector?, tag: Int = 0, on: Bool = false, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.tag = tag
        item.state = on ? .on : .off
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("About LaunchMat", #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Show LaunchMat", #selector(showGrid)))
        menu.addItem(.separator())

        menu.addItem(submenu("Grid Size", GridSize.presets.enumerated().map { i, size in
            item(size.label, #selector(pickGrid(_:)), tag: i, on: size == model.gridSize)
        }))
        menu.addItem(submenu("Hotkey", HotkeyChoice.allCases.enumerated().map { i, k in
            item(k.title, #selector(pickHotkey(_:)), tag: i, on: k == Settings.hotkey)
        }))
        menu.addItem(submenu("Hot Corner", HotCorner.allCases.enumerated().map { i, corner in
            item(corner.title, #selector(pickCorner(_:)), tag: i, on: corner == Settings.hotCorner)
        }))
        var pinchItems = PinchFingers.allCases.enumerated().map { i, f in
            item(f.title, #selector(pickPinch(_:)), tag: i, on: f == Settings.pinch)
        }
        if Settings.pinch != .off && !PinchMonitor.isTrusted {
            pinchItems.append(.separator())
            pinchItems.append(item("Allow in Accessibility Settings…", #selector(openAccessibility)))
        }
        menu.addItem(submenu("Trackpad Pinch", pinchItems))
        menu.addItem(item("Launch at Login", #selector(toggleLogin), on: LoginItem.isEnabled))
        menu.addItem(.separator())

        let hiddenCount = model.layout.hidden.count
        let unhide = item("Unhide All Apps (\(hiddenCount))", #selector(unhideAll))
        unhide.isEnabled = hiddenCount > 0
        menu.addItem(unhide)
        menu.addItem(item("Import System Launchpad Layout…", #selector(importLegacy)))
        menu.addItem(item("Rescan Applications", #selector(rescan)))
        menu.addItem(item("Reset Layout…", #selector(resetLayout)))
        menu.addItem(item("Show Layout File", #selector(revealLayout)))
        menu.addItem(.separator())
        menu.addItem(item("Tips: ⌘-click to select several · hold ⌥ to uninstall", nil))
        menu.addItem(item("Quit LaunchMat", #selector(quit), key: "q"))
    }

    @objc private func showGrid() { controller.show() }
    @objc private func pickGrid(_ sender: NSMenuItem) { model.setGrid(GridSize.presets[sender.tag]) }
    @objc private func unhideAll() { model.unhideAll() }
    @objc private func rescan() { model.refreshApps() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func pickHotkey(_ sender: NSMenuItem) {
        Settings.hotkey = HotkeyChoice.allCases[sender.tag]
        registerHotkey()
    }

    @objc private func pickCorner(_ sender: NSMenuItem) {
        let corner = HotCorner.allCases[sender.tag]
        Settings.hotCorner = corner
        hotCorner.corner = corner
    }

    @objc private func pickPinch(_ sender: NSMenuItem) {
        let fingers = PinchFingers.allCases[sender.tag]
        Settings.pinch = fingers
        if fingers == .fourOrFive && PinchMonitor.systemFourFingerPinchEnabled {
            Uninstaller.alert("The system four-finger pinch is on",
                              "macOS also uses this gesture. Turn off System Settings › Trackpad › More Gestures › "
                                  + "“Launchpad” / “Apps” so only LaunchMat responds.")
        }
        if fingers != .off && !PinchMonitor.isTrusted {
            Uninstaller.alert("Allow LaunchMat in Accessibility",
                              "Reading trackpad gestures system-wide needs Accessibility permission. "
                                  + "Turn on LaunchMat in System Settings › Privacy & Security › Accessibility; "
                                  + "the pinch starts working right away.")
        }
        startPinch(prompt: true)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin() {
        if let error = LoginItem.set(!LoginItem.isEnabled) {
            Uninstaller.alert("Could not change Launch at Login", error)
        }
    }

    @objc private func revealLayout() {
        model.saveNow()
        NSWorkspace.shared.activateFileViewerSelecting([LaunchpadModel.layoutURL])
    }

    @objc private func resetLayout() {
        let alert = NSAlert()
        alert.messageText = "Reset the layout?"
        alert.informativeText = "Folders, your custom order and hidden apps will be replaced by the default arrangement."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { model.resetLayout() }
    }

    @objc private func importLegacy() {
        let pages: [[LegacyLaunchpad.Item]]
        do {
            guard let path = LegacyLaunchpad.defaultPath else { throw LegacyLaunchpad.ReadError.notFound("(unknown)") }
            pages = try LegacyLaunchpad.read(path: path)
        } catch {
            Uninstaller.alert("Nothing to import", "\(error)\n\nThis only works on a Mac that used Launchpad before macOS 26.")
            return
        }
        let folders = pages.flatMap { $0 }.filter { if case .folder = $0 { return true } else { return false } }.count
        let alert = NSAlert()
        alert.messageText = "Import the system Launchpad layout?"
        alert.informativeText = "Found \(pages.count) pages and \(folders) folders. Your current LaunchMat layout "
            + "will be replaced; apps Launchpad didn't know about are added at the end."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let placed = model.applyImported(pages)
        Uninstaller.alert("Imported", "\(placed) apps placed from the Launchpad layout.")
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
        if args.contains("--open-folder") { model.openFolder = model.firstFolderID }

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
