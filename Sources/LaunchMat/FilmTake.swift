import AppKit
import LaunchMatCore
import SwiftUI

/// `LaunchMat --film-take <shot> [--takes <dir>] [--screen builtin|main] [--fresh]` plays one shot of the film on the real grid
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
///
/// Shots: open (open the grid, page 2, back), folder (hold Podcasts over Music, rename the folder), search (vsc,
/// clear, wx, no Return), uninstall (right-click Sketchpad › Move to Trash…, the leftovers list, Cancel), close (Esc).
/// Pauses follow the film's pacing: a beat before each action, and a beat after it.
@MainActor
enum FilmTake {
    static let shots = ["open", "folder", "search", "uninstall", "close"]

    private static var model: LaunchpadModel!
    private static var controller: LaunchWindowController!
    private static var window: NSWindow { controller.window }
    private static var screen: NSScreen!
    private static var t0 = 0.0
    private static var output: URL!
    private static var count = 0

    static func run(model: LaunchpadModel, args: [String]) -> Never {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        #if DEBUG
        let testBuild = true
        #else
        let testBuild = !((Bundle.main.infoDictionary?["LaunchMatCommit"] as? String) ?? "").isEmpty
        #endif
        guard testBuild else { fail("only in test builds (./build.sh), not in a release") }
        guard let shot = value("--film-take"), shots.contains(shot) else {
            fail("which shot? one of: \(shots.joined(separator: ", "))")
        }

        // Where the log goes, and when the recording started.
        let dir = URL(fileURLWithPath: value("--takes") ?? "takes",
                      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        output = dir.appendingPathComponent("\(shot).actions.jsonl")
        try? Data().write(to: output)
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
        model.load(fresh: args.contains("--fresh"), sync: true)
        controller = LaunchWindowController(model: model)
        // Started from a script the app may not become active; the content takes clicks anyway.
        window.contentView = TestHostingView(rootView: RootView(model: model))
        NSApp.activate()
        wait(1.0)

        switch shot {
        case "open": openShot()
        case "folder": folderShot()
        case "search": searchShot()
        case "uninstall": uninstallShot()
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
        // drag is not: on page 2 an icon may sit there).
        let row = m.iconCenter(model.gridSize.cols).y
        let gap = CGPoint(x: m.cellCenter(model.gridSize.cols / 2).x + m.cell.width / 2, y: row)
        drag(from: gap, to: CGPoint(x: gap.x - 320, y: row), seconds: 0.55)
        wait(1.6)
        guard model.isBlank(at: gap) else { fail("the gap between icons isn't blank on page 2") }
        drag(from: gap, to: CGPoint(x: gap.x + 320, y: row), seconds: 0.55)
        wait(1.8)
    }

    private static func folderShot() {
        openGrid()
        guard let podcasts = slot(bundleID: "com.apple.podcasts", name: "Podcasts"),
              let music = slot(bundleID: "com.apple.Music", name: "Music"), podcasts.page == music.page else {
            fail("Podcasts and Music must be on the same page (record.sh prepare puts them on page 1)")
        }
        goTo(podcasts.page)
        let m = model.metrics
        drag(from: m.iconCenter(podcasts.slot), to: m.iconCenter(music.slot), seconds: 1.0, hold: 0.9)
        wait(1.2)
        if model.openFolder == nil, let id = model.layout.folders.first(where: { $0.value.apps.count == 2 })?.key,
           let i = model.layout.pages[model.currentPage].firstIndex(of: .folder(id)) {
            click(m.iconCenter(i))
            wait(1.0)
        }
        guard let id = model.openFolder else { fail("no folder opened after the drop") }
        let panel = model.folderPanel(for: id)
        click(CGPoint(x: panel.frame.midX, y: panel.frame.minY + panel.header * 0.55), textField: true)
        wait(0.6)
        let name = model.folderNameBinding(id)
        key("cmd+a", code: 0, characters: "a", modifiers: .command)
        // Select All, whether or not the key reached a menu.
        if editing { (window.firstResponder as? NSTextView)?.selectAll(nil) } else { name.wrappedValue = "" }
        wait(0.3)
        type("Listening", interval: 0.09, value: { name.wrappedValue }) { name.wrappedValue += $0 }
        wait(0.5)
        key("return", code: 36, characters: "\r")
        wait(1.8)
    }

    private static func searchShot() {
        openGrid()
        type("vsc", interval: 0.2, value: { model.query }) { model.query += $0 }
        wait(1.4)
        for _ in 0..<3 {
            key("delete", code: 51, characters: "\u{7F}", value: { model.query }) { if !model.query.isEmpty { model.query.removeLast() } }
            wait(0.14)
        }
        wait(0.7)
        type("wx", interval: 0.2, value: { model.query }) { model.query += $0 }
        wait(2.2)
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
            hover(p)
            later(0.25) {
                record("click", at: p)
                chosen = (menu, i)
                menu.cancelTracking()
            }
        }
        wait(0.5)
        rightClick(point)
        NotificationCenter.default.removeObserver(observer)
        guard let (menu, i) = chosen else { fail("the icon's menu didn't offer \(trashTitle)") }

        // The confirmation lists the leftovers; it stays up for a while, then Cancel, so nothing is moved.
        for k in 0..<60 { later(0.2 + 0.02 * Double(k)) { keepAlertOnScreen() } }
        later(4.6) {
            guard let alert = NSApp.modalWindow, let cancel = button(L("common.cancel", "Cancel"), in: alert.contentView) else { return }
            let frame = alert.convertToScreen(cancel.convert(cancel.bounds, to: nil))
            record("click", at: rootPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY)))
            cancel.performClick(nil)
        }
        // Should Cancel not be found, the dialog is closed anyway; for the uninstaller that is a cancel too.
        later(7.0) { if NSApp.modalWindow != nil { NSApp.abortModal() } }
        menu.performActionForItem(at: i)
        wait(6.0)
        wait(1.0)
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
    private static func click(_ p: CGPoint, textField: Bool = false) {
        wait(0.45)
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
        wait(0.45)
        let start = now
        send(.leftMouseDown, a)
        wait(0.12)
        let steps = max(2, Int(seconds * 60))
        for k in 1...steps {
            let u = Double(k) / Double(steps)
            let e = u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
            send(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e))
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

    private static func rightClick(_ p: CGPoint) {
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
    private static func type(_ text: String, interval: Double, value: () -> String, fallback: (String) -> Void) {
        wait(0.45)
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
