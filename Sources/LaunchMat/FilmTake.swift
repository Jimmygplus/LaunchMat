import AppKit
import LaunchMatCore
import SwiftUI

/// `LaunchMat --film-take <shot> [--takes <dir>] [--screen builtin|main] [--demo-layout <file> | --fresh]` plays one shot of the film on the real grid
/// and logs what it did, for the film's drawn cursor and camera. Test builds only.
///
/// - Synthetic events are handed to the app itself, as in `--mouse-test`: nothing is posted to the system, no
///   permission is needed, and the real pointer stays where it is (the film draws its own).
/// - Each action goes to `<dir>/<shot>.actions.jsonl`, one object per line:
///   `{t, type, x, y, t2?, x2?, y2?, text?}` with type click | right | drag | key | type; `t` in seconds since the
///   recording started (`<dir>/.<shot>.start`, written by `record.sh capture`; else the take's own start); x and y as
///   fractions of the screen from its top left; a drag ends at (x2, y2) at t2; keys and typed text in `text`.
/// - Uses the saved layout (staged by `record.sh prepare`) but saves nothing, opens no app and trashes nothing: the
///   uninstall shot cancels the dialog. `--fresh` uses the default arrangement instead, to try a shot unstaged.
/// - `--demo-layout <file>`: the film's own clean grid instead of the saved one (see `loadDemoLayout`).
/// - A pointer drawn by the app (the system arrow) glides to each action and moves with every synthetic event, so in
///   the recording it and a dragged icon follow the same path. Record without the system pointer.
///
/// Shots: open (open the grid, page 2, back), folder (hold Music over Podcasts, name the folder "Listen", close it),
/// search (wx, clear, vsc, no Return), uninstall (right-click Sketchpad › Move to Trash…, the leftovers list,
/// Cancel), close (Esc), wiggle, import; stills (the website's pictures, see stillsShot).
/// Pauses follow the film's pacing: a beat before each action, and a beat after it.
@MainActor
enum FilmTake {
    static let shots = ["open", "folder", "search", "uninstall", "close", "wiggle", "import", "stills"]
    /// Not a shot: builds (or reads) the demo layout, prints its pages and exits, showing nothing.
    static let layoutOnly = "layout"

    private static var model: LaunchpadModel!
    private static var controller: LaunchWindowController!
    private static var window: NSWindow { controller.window }
    private static var screen: NSScreen!
    private static var t0 = 0.0
    private static var output: URL!
    private static var count = 0
    private static var arguments: [String] = []
    private static func value(_ flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    static func run(model: LaunchpadModel, args: [String]) -> Never {
        arguments = args
        #if DEBUG
        let testBuild = true
        #else
        let testBuild = !((Bundle.main.infoDictionary?["LaunchMatCommit"] as? String) ?? "").isEmpty
        #endif
        guard testBuild else { fail("only in test builds (./build.sh), not in a release") }
        guard let shot = value("--film-take"), shots.contains(shot) || shot == layoutOnly else {
            fail("which shot? one of: \(shots.joined(separator: ", ")) (or layout, with --demo-layout)")
        }

        // Where the log goes, and when the recording started.
        let dir = URL(fileURLWithPath: value("--takes") ?? "takes",
                      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        output = dir.appendingPathComponent("\(shot).actions.jsonl")
        if shot != layoutOnly { try? Data().write(to: output) }
        t0 = Date().timeIntervalSince1970
        let startFile = dir.appendingPathComponent(".\(shot).start")
        if let text = try? String(contentsOf: startFile, encoding: .utf8),
           let start = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            t0 = start
        }

        // The screen: the built-in one (Retina) unless asked otherwise.
        let builtin = NSScreen.screens.first { CGDisplayIsBuiltin($0.displayID) != 0 }
        screen = (value("--screen") == "main" ? nil : builtin) ?? NSScreen.screens.first
        guard let screen else { fail("no screen") }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
        CGGetActiveDisplayList(16, &displays, &n)
        let index = (displays.prefix(Int(n)).firstIndex(of: screen.displayID) ?? 0) + 1
        print("film-take \(shot): \(screen.localizedName), \(Int(screen.frame.width)) × \(Int(screen.frame.height)) pt, "
            + "@\(Int(screen.backingScaleFactor))x (screencapture -D \(index)) → \(output.path)")

        self.model = model
        model.persistenceEnabled = false
        model.launchHandler = { _ in }
        if let file = value("--demo-layout") {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            loadDemoLayout(URL(fileURLWithPath: file, relativeTo: cwd).standardizedFileURL)
        } else {
            model.load(fresh: args.contains("--fresh"), sync: true)
        }
        if shot == layoutOnly {
            for (i, page) in model.layout.pages.enumerated() {
                print("page \(i + 1): " + page.map { model.title(for: $0) }.joined(separator: " · "))
            }
            exit(0)
        }
        controller = LaunchWindowController(model: model)
        // Started from a script the app may not become active; the content takes clicks anyway.
        window.contentView = TestHostingView(rootView: RootView(model: model))
        NSApp.activate()
        Pointer.setUp(on: screen, at: CGPoint(x: screen.frame.width * 0.55, y: screen.frame.height * 0.72))
        wait(1.0)

        switch shot {
        case "open": openShot()
        case "folder": folderShot()
        case "search": searchShot()
        case "uninstall": uninstallShot()
        case "wiggle": wiggleShot()
        case "import": importShot()
        case "stills": stillsShot()
        default: closeShot()
        }
        print("film-take \(shot): \(count) actions logged")
        exit(0)
    }

    // MARK: - Shots

    private static func openShot() {
        wait(1.5)
        key("shift+cmd+space")
        show()
        wait(1.6)
        guard model.pageCount >= 2 else { fail("the layout has one page; the open shot turns to page 2") }
        let m = model.metrics
        // Both presses land between two icons of the middle row, which is blank on every page (the end of the first
        // drag is not: on page 2 an icon may sit there). The drag stays within the distance the pages follow 1:1
        // (Paging.follow: 8% of the width, 48–72 pt), past the 50 pt that turns the page: the pointer stays on the
        // point it grabbed, and on release the page settles on the next one.
        let row = m.iconCenter(model.gridSize.cols).y
        let gap = CGPoint(x: m.cellCenter(model.gridSize.cols / 2).x + m.cell.width / 2, y: row)
        let oneToOne = min(72, max(48, Double(m.size.width) * 0.08))
        let distance = CGFloat(max(Paging.threshold + 6, oneToOne - 4))
        // The film shows page turns as a trackpad swipe: no pointer while the pages move.
        Pointer.isHidden = true
        drag(from: gap, to: CGPoint(x: gap.x - distance, y: row), seconds: 0.4)
        wait(1.6)
        guard model.isBlank(at: gap) else { fail("the gap between icons isn't blank on page 2") }
        drag(from: gap, to: CGPoint(x: gap.x + distance, y: row), seconds: 0.4)
        wait(1.0)
        Pointer.isHidden = false
        wait(1.8)
    }

    /// Hold Music over Podcasts until they make a folder, close it after a beat, and write the layout to
    /// <takes>/folder.layout.json: the search take can use it as its --demo-layout, so the two grids follow on.
    /// `--from` and `--onto` choose other apps (by name); `--name` types a name over the folder's own. Tight, for a
    /// beat of about 4.5 s.
    private static func folderShot() {
        openGrid()
        let fromName = value("--from"), ontoName = value("--onto")
        guard let music = fromName.map({ slot(name: $0) }) ?? slot(bundleID: "com.apple.Music", name: "Music"),
              let podcasts = ontoName.map({ slot(name: $0) }) ?? slot(bundleID: "com.apple.podcasts", name: "Podcasts"),
              podcasts.page == music.page else {
            fail("\(fromName ?? "Music") and \(ontoName ?? "Podcasts") must be on the same page")
        }
        goTo(music.page)
        let m = model.metrics
        // Held over the target only as long as spec C6 takes to offer the folder (0.1 s, then the plate pops).
        drag(from: m.iconCenter(music.slot), to: m.iconCenter(podcasts.slot), seconds: 0.8, hold: 0.3)
        wait(0.45) // the folder opens (0.28 s)
        if model.openFolder == nil, let id = model.layout.folders.first(where: { $0.value.apps.count == 2 })?.key,
           let i = model.layout.pages[model.currentPage].firstIndex(of: .folder(id)) {
            click(m.iconCenter(i))
            wait(0.45)
        }
        guard let id = model.openFolder else { fail("no folder opened after the drop") }
        let panel = model.folderPanel(for: id)
        // A name only with --name, typed once over the selected default (no Select All and retyping); without it the
        // folder keeps its own name.
        if let newName = value("--name") {
            let title = CGPoint(x: panel.frame.midX, y: panel.frame.minY + panel.header * 0.55)
            click(title, pause: 0.2)
            Pointer.glide(to: CGPoint(x: title.x + 80, y: title.y + 80), seconds: 0.3) // off the name
            let name = model.folderNameBinding(id)
            if editing { (window.firstResponder as? NSTextView)?.selectAll(nil) } else { name.wrappedValue = "" }
            type(newName, interval: 0.06, pause: 0.1, value: { name.wrappedValue }) { name.wrappedValue += $0 }
            key("return", code: 36, characters: "\r")
        }
        // About 0.6 s, then blank space below the panel closes the folder; the pointer is on its way meanwhile.
        let blank = CGPoint(x: panel.frame.midX, y: (panel.frame.maxY + m.size.height) / 2)
        Pointer.glide(to: blank, seconds: 0.4)
        click(blank, pause: 0.2)
        wait(1.5)
        if model.openFolder != nil { model.closeFolder() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = output.deletingLastPathComponent().appendingPathComponent("folder.layout.json")
        try? encoder.encode(model.layout).write(to: file)
        print("film-take folder: layout after the take → \(file.path)")
    }

    private static func searchShot() {
        openGrid()
        type("wx", interval: 0.2, value: { model.query }) { model.query += $0 }
        wait(2.0)
        for _ in 0..<2 {
            key("delete", code: 51, characters: "\u{7F}", value: { model.query }) { if !model.query.isEmpty { model.query.removeLast() } }
            wait(0.14)
        }
        wait(0.7)
        type("vsc", interval: 0.2, value: { model.query }) { model.query += $0 }
        wait(2.0)
    }

    private static func uninstallShot() {
        openGrid()
        guard let sketchpad = slot(path: { $0.hasSuffix("/Sketchpad.app") }, name: "Sketchpad") else {
            fail("no Sketchpad in the grid (record.sh prepare makes the dummy and puts it on page 1)")
        }
        goTo(sketchpad.page)
        let path = model.layout.pages[sketchpad.page][sketchpad.slot].appPath!
        guard model.canUninstall(path) else { fail("Sketchpad can't be moved to the Trash from here") }
        let trashTitle = L("entry.trash", "Move to Trash…")
        let point = model.metrics.iconCenter(sketchpad.slot)

        Pointer.glide(to: point)
        wait(0.45)
        // The right-click opens the icon's menu, which runs its own loop until it closes; these timers act inside it.
        var tracked: NSMenu?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                                              queue: nil) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated { if tracked == nil { tracked = menu } }
        }
        var chosen: (NSMenu, Int)?
        later(1.3) {
            guard let menu = tracked, let i = menu.items.firstIndex(where: { $0.title == trashTitle }) else { return }
            // The item is the last one in the menu: its centre sits about 16 pt above the menu's bottom edge.
            let p: CGPoint
            if let frame = NSApp.windows.first(where: { $0.isVisible && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue })?.frame,
               i == menu.items.count - 1 {
                p = rootPoint(fromScreen: CGPoint(x: frame.minX + min(64, frame.width * 0.3), y: frame.minY + 16))
            } else {
                p = CGPoint(x: point.x + 64, y: point.y + 12 + CGFloat(i) * 24)
            }
            Pointer.glideLater(to: p, seconds: 0.4) {
                hover(p)
                later(0.3) {
                    record("click", at: p)
                    chosen = (menu, i)
                    menu.cancelTracking()
                }
            }
        }
        rightClick(point, approach: false)
        NotificationCenter.default.removeObserver(observer)
        guard let (menu, i) = chosen else { fail("the icon's menu didn't offer \(trashTitle)") }

        // The confirmation lists the leftovers; it stays up for a while, then Cancel, so nothing is moved.
        for k in 0..<60 { later(0.2 + 0.02 * Double(k)) { keepAlertOnScreen() } }
        later(4.0) {
            guard let alert = NSApp.modalWindow, let cancel = button(L("common.cancel", "Cancel"), in: alert.contentView) else { return }
            let frame = alert.convertToScreen(cancel.convert(cancel.bounds, to: nil))
            let p = rootPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
            Pointer.glideLater(to: p, seconds: 0.5) {
                later(0.35) {
                    record("click", at: p)
                    cancel.performClick(nil)
                }
            }
        }
        // Should Cancel not be found, the dialog is closed anyway; for the uninstaller that is a cancel too.
        later(7.0) { if NSApp.modalWindow != nil { NSApp.abortModal() } }
        menu.performActionForItem(at: i)
        wait(6.0)
        wait(1.0)
    }

    /// Hold ⌥ (as the window's modifier monitor sees it): every icon wiggles and the removable ones show ✕;
    /// 2 seconds; let go.
    private static func wiggleShot() {
        openGrid()
        wait(0.5)
        record("key", text: "option down")
        model.optionHeld = true
        wait(2.0)
        record("key", text: "option up")
        model.optionHeld = false
        wait(1.5)
    }

    /// Pictures for the website, of the app's own windows as they are on screen: the grid on page 1, the grid
    /// searching "vsc", and Settings at each of its five tabs (in the light appearance). For each it prints
    /// `STILL <name> <window number>` and holds still for 1.2 s, so a script can take the window
    /// (`screencapture -o -l <number>`); the drawn pointer is a window of its own and isn't in them.
    private static func stillsShot() {
        func still(_ name: String, _ window: NSWindow) {
            print("STILL \(name) \(window.windowNumber)")
            fflush(stdout)
            wait(1.2)
        }
        Pointer.isHidden = true
        AppDelegate.showsCommit = false
        openGrid()
        still("grid", window)
        model.query = "vsc"
        wait(0.8)
        still("search", window)
        model.query = ""
        controller.hide()
        wait(0.6)
        let settings = SettingsWindowController(model: model, actions: FilmSettingsActions(pages: []), showGuide: nil)
        for (tab, name) in [(SettingsWindowController.Tab.general, "general"), (.interface, "interface"), (.apps, "apps"),
                            (.advanced, "advanced"), (.about, "about")] {
            settings.show(tab)
            guard let w = settings.window else { fail("no settings window") }
            w.appearance = NSAppearance(named: .aqua)
            w.setFrameOrigin(NSPoint(x: screen.frame.midX - w.frame.width / 2, y: screen.frame.midY - w.frame.height / 2 + 60))
            wait(0.6)
            still("settings-\(name)", w)
        }
        settings.window?.close()
        wait(0.3)
    }

    /// Settings › Advanced › Import…, the app's own question ("Found 4 pages and 9 folders…"), Import, and the grid in
    /// the old arrangement. The old layout is demo data made here (demoOldLayout); the Mac's real Launchpad database
    /// and the saved layout are never read or written.
    private static func importShot() {
        let pages = demoOldLayout()
        let actions = FilmSettingsActions(pages: pages)
        let settings = SettingsWindowController(model: model, actions: actions, showGuide: nil)
        settings.show(.advanced)
        guard let window = settings.window else { fail("no settings window") }
        window.setFrameOrigin(NSPoint(x: screen.frame.midX - window.frame.width / 2,
                                      y: screen.frame.midY - window.frame.height / 2 + 60))
        wait(1.5)
        // The tab's buttons are, from the top: Import…, Show in Finder, Reset….
        guard let importButton = buttons(in: window.contentView)
            .max(by: { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY }) else {
            fail("no Import… button in Settings › Advanced")
        }
        let frame = window.convertToScreen(importButton.convert(importButton.bounds, to: nil))
        let p = rootPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
        Pointer.glide(to: p)
        wait(0.45)
        record("click", at: p)
        // The question runs its own loop; FilmSettingsActions answers it from inside.
        importButton.performClick(nil)
        wait(0.6)
        window.close()
        wait(0.4)
        openGrid()
        wait(2.5)
    }

    /// Answers Settings' import from the demo data: the app's question, the pointer to Import, the layout applied.
    private final class FilmSettingsActions: AppActions {
        let pages: [[LegacyLaunchpad.Item]]
        init(pages: [[LegacyLaunchpad.Item]]) { self.pages = pages }

        func importLegacyLayout() -> Bool {
            let alert = ImportPrompt.alert(for: pages)
            for k in 0..<60 { later(0.2 + 0.02 * Double(k)) { keepAlertOnScreen() } }
            later(1.4) {
                guard let sheet = NSApp.modalWindow, let button = button(L("import.import", "Import"), in: sheet.contentView) else { return }
                let frame = sheet.convertToScreen(button.convert(button.bounds, to: nil))
                let p = rootPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
                Pointer.glideLater(to: p, seconds: 0.5) {
                    later(0.35) {
                        record("click", at: p)
                        button.performClick(nil)
                    }
                }
            }
            later(6.0) { if NSApp.modalWindow != nil { NSApp.abortModal() } }
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            model.applyImported(pages)
            return true
        }
        func setHotkey(_ choice: HotkeyChoice) {}
        func setHotCorner(_ corner: HotCorner) {}
        func setPinch(_ fingers: PinchFingers) {}
        func setLaunchAtLogin(_ on: Bool) {}
        func confirmResetLayout() {}
        func revealLayoutFile() {}
        func openAccessibilitySettings() {}
        func openURL(_ url: URL) {}
    }

    /// An old Launchpad layout for the import take: 4 pages and 9 folders of apps any Mac has, plus the global ones
    /// the demo layout shows. Apps not installed here are left out when it is applied.
    private static func demoOldLayout() -> [[LegacyLaunchpad.Item]] {
        func app(_ id: String) -> LegacyLaunchpad.Item { .app(.init(bundleID: id, title: "")) }
        func folder(_ title: String, _ ids: [String]) -> LegacyLaunchpad.Item {
            .folder(title: title, apps: ids.map { .init(bundleID: $0, title: "") })
        }
        return [
            ["com.apple.Safari", "com.google.Chrome", "com.apple.mail", "com.apple.iCal", "com.apple.Notes",
             "com.apple.reminders", "com.apple.Maps", "com.apple.Photos", "com.apple.MobileSMS", "com.apple.FaceTime",
             "com.tinyspeck.slackmacgap", "us.zoom.xos"].map(app)
                + [folder("Work", ["com.apple.iWork.Keynote", "com.apple.iWork.Numbers", "com.apple.iWork.Pages"]),
                   folder("Music", ["com.apple.Music", "com.spotify.client", "com.apple.podcasts"]),
                   folder("Developer", ["com.microsoft.VSCode", "com.apple.Terminal", "com.figma.Desktop"])],
            ["com.apple.AppStore", "com.apple.systempreferences", "com.apple.weather", "com.apple.clock",
             "com.apple.calculator", "com.apple.freeform"].map(app)
                + [folder("Watch", ["com.apple.TV", "com.apple.PhotoBooth", "com.apple.QuickTimePlayerX"]),
                   folder("Reading", ["com.apple.iBooksX", "com.apple.news", "com.apple.stocks"]),
                   folder("Home", ["com.apple.Home", "com.apple.findmy"])],
            ["com.apple.VoiceMemos", "com.apple.shortcuts", "com.apple.Preview"].map(app)
                + [folder("Utilities", ["com.apple.ActivityMonitor", "com.apple.Console", "com.apple.DiskUtility",
                                        "com.apple.SystemProfiler"]),
                   folder("Color", ["com.apple.Image_Capture", "com.apple.DigitalColorMeter", "com.apple.ColorSyncUtility"])],
            ["com.apple.Dictionary", "com.apple.TextEdit", "com.apple.FontBook"].map(app)
                + [folder("Other", ["com.apple.Stickies", "com.apple.grapher", "com.apple.ScreenSharing"])],
        ]
    }

    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

    private static func closeShot() {
        openGrid()
        key("escape", code: 53, characters: "\u{1B}")
        if controller.isVisible { controller.hide() }
        wait(1.5)
    }

    // MARK: - Steps

    /// The grid on the film's screen, opened the way the hotkey does it, then a beat.
    private static func openGrid() {
        key("shift+cmd+space")
        show()
        wait(1.8)
    }

    private static func show() {
        controller.show(on: screen)
        window.makeKey()
    }

    /// A text field tracks the press in its own loop, reading the release from the app's event queue: for one, the
    /// release is queued first.
    private static func click(_ p: CGPoint, textField: Bool = false, pause: Double = 0.45) {
        Pointer.glide(to: p)
        wait(pause)
        record("click", at: p)
        if textField, let up = mouseEvent(.leftMouseUp, p) {
            NSApp.postEvent(up, atStart: false)
            send(.leftMouseDown, p)
            return
        }
        send(.leftMouseDown, p)
        wait(0.08)
        send(.leftMouseUp, p)
    }

    /// Press, move with ease-in-out over `seconds`, stay for `hold`, release.
    private static func drag(from a: CGPoint, to b: CGPoint, seconds: Double, hold: Double = 0) {
        Pointer.glide(to: a)
        wait(0.45)
        let start = now
        send(.leftMouseDown, a)
        wait(0.12)
        let steps = max(2, Int(seconds * 60))
        for k in 1...steps {
            let u = Double(k) / Double(steps)
            let e = u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
            let p = CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
            Pointer.move(to: p)
            send(.leftMouseDragged, p)
            wait(1.0 / 60)
        }
        let until = Date().addingTimeInterval(hold)
        while Date() < until {
            send(.leftMouseDragged, b)
            wait(1.0 / 60)
        }
        send(.leftMouseUp, b)
        record("drag", at: a, to: b, from: start, until: now)
    }

    private static func rightClick(_ p: CGPoint, approach: Bool = true) {
        if approach {
            Pointer.glide(to: p)
            wait(0.45)
        }
        record("right", at: p)
        // Through the app, not the window: the right-click menu is opened by the app's event monitor.
        if let e = mouseEvent(.rightMouseDown, p) { NSApp.sendEvent(e) }
        if let e = mouseEvent(.rightMouseUp, p) { NSApp.sendEvent(e) }
    }

    /// Moves the app's idea of the pointer (a menu highlights the item under it); the real pointer stays put.
    private static func hover(_ p: CGPoint) {
        let s = screenPoint(p)
        if let e = NSEvent.mouseEvent(with: .mouseMoved, location: s, modifierFlags: [], timestamp: uptime, windowNumber: 0,
                                      context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// One key press through the app, as the keyboard would send it. With `value`, a key that didn't change it (no
    /// text field took the key) is applied by `fallback` instead, so the picture is the same either way.
    private static func key(_ name: String, code: UInt16? = nil, characters: String = "", modifiers: NSEvent.ModifierFlags = [],
                            value: (() -> String)? = nil, fallback: (() -> Void)? = nil) {
        record("key", text: name)
        guard let code else { return }
        let before = value?()
        sendKey(code: code, characters: characters, modifiers: modifiers)
        if let value, !changes(value, from: before!) { fallback?() }
    }

    /// Types `text` one character at a time into the field whose text `value` reads; a character that didn't arrive
    /// is added by `fallback`.
    private static func type(_ text: String, interval: Double, pause: Double = 0.45, value: () -> String,
                             fallback: (String) -> Void) {
        wait(pause)
        for ch in text {
            record("type", text: String(ch))
            let before = value()
            sendKey(code: keyCodes[ch] ?? 0, characters: String(ch), modifiers: [])
            if !changes(value, from: before) { fallback(String(ch)) }
            wait(interval)
        }
    }

    /// Whether `value` moves away from `before` within 0.15 s (a text field may pass its text on a moment later).
    private static func changes(_ value: () -> String, from before: String) -> Bool {
        let until = Date().addingTimeInterval(0.15)
        while value() == before {
            if Date() >= until { return false }
            wait(0.01)
        }
        return true
    }

    /// True while a text field (the search or a folder name) has the keyboard.
    private static var editing: Bool { window.firstResponder is NSTextView }

    private static func sendKey(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: uptime,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: code) {
                NSApp.sendEvent(e)
            }
        }
        wait(0.02)
    }

    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "L": 37,
    ]

    // MARK: - Events and positions

    private static func send(_ type: NSEvent.EventType, _ p: CGPoint) {
        if let e = mouseEvent(type, p) { window.sendEvent(e) }
        wait(1.0 / 120)
    }

    /// `p` in the grid's coordinates (SwiftUI: origin top left), as an event in the window (origin bottom left).
    private static func mouseEvent(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: window.frame.height - p.y), modifierFlags: [],
                           timestamp: uptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
    }

    private static func screenPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: screen.frame.minX + p.x, y: screen.frame.maxY - p.y)
    }

    private static func rootPoint(fromScreen s: CGPoint) -> CGPoint {
        CGPoint(x: s.x - screen.frame.minX, y: screen.frame.maxY - s.y)
    }

    /// Where the app with this bundle ID, path or name is in the grid.
    private static func slot(bundleID: String? = nil, path match: ((String) -> Bool)? = nil, name: String) -> (page: Int, slot: Int)? {
        for (p, page) in model.layout.pages.enumerated() {
            if let s = page.firstIndex(where: { entry in
                guard let path = entry.appPath, let app = model.apps[path] else { return false }
                return app.bundleID == bundleID || match?(path) == true || app.name == name
            }) { return (p, s) }
        }
        return nil
    }

    /// Takes are staged on page 1; anywhere else the grid turns there first (only when trying a shot unstaged).
    private static func goTo(_ page: Int) {
        guard page != model.currentPage else { return }
        model.go(to: page)
        wait(1.0)
    }

    private static func button(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let b = view as? NSButton, b.title == title { return b }
        for sub in view.subviews { if let b = button(title, in: sub) { return b } }
        return nil
    }

    /// The confirmation opens on the main screen; on another one it is moved to the film's screen, same place.
    private static func keepAlertOnScreen() {
        guard let alert = NSApp.modalWindow, let from = alert.screen, from != screen else { return }
        let dx = (alert.frame.midX - from.frame.minX) / from.frame.width
        let dy = (alert.frame.midY - from.frame.minY) / from.frame.height
        alert.setFrameOrigin(CGPoint(x: screen.frame.minX + dx * screen.frame.width - alert.frame.width / 2,
                                     y: screen.frame.minY + dy * screen.frame.height - alert.frame.height / 2))
    }

    // MARK: - Log and time

    private static var now: Double { Date().timeIntervalSince1970 - t0 }
    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func record(_ type: String, at p: CGPoint? = nil, to q: CGPoint? = nil, from start: Double? = nil,
                               until end: Double? = nil, text: String? = nil) {
        // Written by hand for short numbers: t to the millisecond, x and y to four places.
        let w = Double(screen.frame.width), h = Double(screen.frame.height)
        var fields = [#""t":\#(String(format: "%.3f", start ?? now))"#, #""type":"\#(type)""#]
        if let p { fields += [#""x":\#(String(format: "%.4f", Double(p.x) / w))"#, #""y":\#(String(format: "%.4f", Double(p.y) / h))"#] }
        if let end { fields.append(#""t2":\#(String(format: "%.3f", end))"#) }
        if let q { fields += [#""x2":\#(String(format: "%.4f", Double(q.x) / w))"#, #""y2":\#(String(format: "%.4f", Double(q.y) / h))"#] }
        if let text, let data = try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed) {
            fields.append(#""text":"# + String(decoding: data, as: UTF8.self))
        }
        guard let handle = try? FileHandle(forWritingTo: output) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(("{" + fields.joined(separator: ",") + "}\n").utf8))
        try? handle.close()
        count += 1
    }

    /// Runs `action` after `seconds`, also inside a menu's or a dialog's own loop.
    private static func later(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { action() } }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private static func fail(_ message: String) -> Never {
        print("film-take: \(message)")
        exit(1)
    }
}

// MARK: - The film's demo layout

extension FilmTake {
    /// The film's own grid, so a take shows what a new Mac has and none of the apps really installed here: system
    /// apps and Apple's apps in Launchpad's default arrangement (read from the Dock's own LaunchPadLayout.plist on
    /// this Mac), the other system apps by name, then Chrome, Visual Studio Code, Slack, Spotify, Figma and Zoom
    /// where installed.
    /// Read from `url` when it exists, so later takes show the same pages; otherwise built and written there.
    /// The saved layout (layout.json) is neither read nor written.
    static func loadDemoLayout(_ url: URL) {
        let order = DefaultOrder.read()
        // Apps people everywhere know (film v4: no WeChat, no Chinese names, nothing else installed here).
        let extras = ["com.google.Chrome", "com.microsoft.VSCode", "com.tinyspeck.slackmacgap", "com.spotify.client",
                      "com.figma.Desktop", "us.zoom.xos"]
        let listed = Set(order.flatMap(\.bundleIDs) + extras)
        model.appFilter = { app in
            app.id.hasPrefix("/System/Applications/") || app.bundleID.map(listed.contains) == true
        }
        model.load(fresh: true, sync: true)
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(PadLayout.self, from: data) {
            // The file decides which apps are in the grid: what was taken out of it stays out.
            let inFile = Set(saved.orderedApps).union(saved.folders.values.flatMap(\.apps))
            model.appFilter = { inFile.contains($0.id) }
            model.layout = saved
            model.refreshApps(sync: true) // drops what isn't installed here
            print("film-take: demo layout \(url.path)")
            return
        }
        let capacity = model.capacity
        var byBundle: [String: String] = [:]
        for app in model.apps.values.sorted(by: { $0.id < $1.id }) {
            if let id = app.bundleID, byBundle[id] == nil { byBundle[id] = app.id }
        }
        var layout = PadLayout(pages: [[]])
        var placed = Set<String>()
        func take(_ id: String) -> String? {
            guard let path = byBundle[id], placed.insert(path).inserted else { return nil }
            return path
        }
        for item in order {
            switch item {
            case .app(let id):
                if let path = take(id) { layout.append(.app(path), capacity: capacity) }
            case .group(let title, let ids):
                // Utilities newer than the Dock's list belong in its folder too.
                let newer = model.apps.values.filter { $0.isUtility && !ids.contains($0.bundleID ?? "") }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.compactMap(\.bundleID)
                let paths = (ids + newer).compactMap(take)
                if paths.count > 1 {
                    let folder = Folder(name: title, apps: paths)
                    layout.folders[folder.id] = folder
                    layout.append(.folder(folder.id), capacity: capacity)
                } else if let path = paths.first {
                    layout.append(.app(path), capacity: capacity)
                }
            }
        }
        let rest = model.apps.values.filter { !placed.contains($0.id) && !extras.contains($0.bundleID ?? "") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for app in rest { layout.append(.app(app.id), capacity: capacity) }
        for id in extras { if let path = take(id) { layout.append(.app(path), capacity: capacity) } }
        model.layout = layout
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(layout).write(to: url)
        print("film-take: demo layout built in Launchpad's default order (\(order.isEmpty ? "not found, by name" : "found")) → \(url.path)")
    }

    /// Launchpad's default arrangement as the Dock ships it: the main page in order, groups being folders.
    enum DefaultOrder {
        case app(String)
        case group(String, [String])

        var bundleIDs: [String] {
            switch self {
            case .app(let id): return [id]
            case .group(_, let ids): return ids
            }
        }

        static func read() -> [DefaultOrder] {
            let url = URL(fileURLWithPath: "/System/Library/CoreServices/Dock.app/Contents/Resources/LaunchPadLayout.plist")
            guard let plist = NSDictionary(contentsOf: url),
                  let main = ((plist["launchpad"] as? [String: Any])?["layout"] as? [String: Any])?["mainPage"] as? [[String: Any]]
            else { return [] }
            return main.compactMap { item in
                if let id = item["bundleid"] as? String { return .app(id) }
                guard item["type"] as? String == "group", let contents = item["contents"] as? [[String: Any]] else { return nil }
                return .group(item["title"] as? String ?? "Other", contents.compactMap { $0["bundleid"] as? String })
            }
        }
    }
}

// MARK: - The film's pointer

/// The system arrow, drawn by the app in a window of its own above everything it shows (the grid, menus, dialogs),
/// clicks passing through. It glides to each action and then moves with every synthetic event, so the pointer and a
/// dragged icon follow one path. Only in --film-take.
@MainActor
private enum Pointer {
    private static var window: NSWindow?
    private static let layer = CALayer()
    private static var screen: NSScreen?
    /// In grid coordinates (origin top left of the screen).
    private(set) static var at = CGPoint.zero

    /// Hidden while the open take turns pages (shown as a trackpad swipe); it keeps following the events meanwhile.
    static var isHidden: Bool {
        get { layer.isHidden }
        set {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.isHidden = newValue
            CATransaction.commit()
        }
    }

    static func setUp(on screen: NSScreen, at start: CGPoint) {
        self.screen = screen
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        w.contentView = view
        let arrow = NSCursor.arrow
        layer.contents = arrow.image
        layer.contentsScale = screen.backingScaleFactor
        layer.bounds = CGRect(origin: .zero, size: arrow.image.size)
        // The hot spot is measured from the image's top left; the layer's anchor from its bottom left.
        layer.anchorPoint = CGPoint(x: arrow.hotSpot.x / arrow.image.size.width, y: 1 - arrow.hotSpot.y / arrow.image.size.height)
        view.layer?.addSublayer(layer)
        w.setFrame(screen.frame, display: false)
        w.orderFrontRegardless()
        window = w
        move(to: start)
    }

    static func move(to p: CGPoint) {
        guard let screen else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = CGPoint(x: p.x, y: screen.frame.height - p.y)
        CATransaction.commit()
        at = p
    }

    /// Ease-in-out from where it is, about 0.35–0.8 s depending on the distance.
    static func glide(to p: CGPoint, seconds: Double? = nil) {
        let from = at
        guard hypot(p.x - from.x, p.y - from.y) >= 1 else { return } // already there
        let duration = seconds ?? travel(from, p)
        let frames = max(1, Int(duration * 60))
        for k in 1...frames {
            move(to: point(from, p, Double(k) / Double(frames)))
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
        }
    }

    /// The same, driven by timers, for inside a menu's or a dialog's own loop; then `done`.
    static func glideLater(to p: CGPoint, seconds: Double, then done: @escaping @MainActor () -> Void) {
        let from = at
        let frames = max(1, Int(seconds * 60))
        for k in 1...frames {
            let timer = Timer(timeInterval: Double(k) / 60, repeats: false) { _ in
                MainActor.assumeIsolated {
                    move(to: point(from, p, Double(k) / Double(frames)))
                    if k == frames { done() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private static func travel(_ a: CGPoint, _ b: CGPoint) -> Double {
        min(0.8, max(0.35, Double(hypot(b.x - a.x, b.y - a.y)) / 1400))
    }

    private static func point(_ a: CGPoint, _ b: CGPoint, _ u: Double) -> CGPoint {
        let e = u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
        return CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
    }
}
