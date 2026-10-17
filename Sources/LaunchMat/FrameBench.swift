import AppKit
import QuartzCore

/// Frame-interval log for animations, a debugging aid: `LAUNCHMAT_FPS_LOG=1` (or `--fps-bench`) records every display
/// frame while an open, close or page animation runs, then prints the frame count, the longest gap and the frames
/// that took more than 1.5 refresh intervals ("dropped"). The display link fires on the main run loop, so a busy main
/// thread shows up as a long gap.
///
/// It also times the main thread's busy stretches (from waking up to going back to sleep) over the same span: a
/// stretch longer than one refresh interval can't make every frame, whatever the display. That is what tells a
/// 120 Hz display apart (8.3 ms per frame) on a Mac whose screens only do 60 Hz.
@MainActor
final class FrameLog: NSObject {
    static let shared = FrameLog()

    struct Record {
        let label: String
        let frames: Int
        let maxGap: Double
        let dropped: Int
        let maxFPS: Int
        /// Time spent waiting beyond one refresh interval on late frames, and the total time measured.
        let hitch: Double
        let duration: Double
        /// The main thread's longest busy stretch, and how many were longer than a 120 Hz and a 60 Hz frame.
        let busyMax: Double
        let busyOver120: Int
        let busyOver60: Int
        /// Icon cells drawn again meanwhile.
        let cells: Int
    }

    var enabled = ProcessInfo.processInfo.environment["LAUNCHMAT_FPS_LOG"] == "1"
    /// How many times an icon cell was drawn again: its SwiftUI body evaluated, or its layers updated (counted only while
    /// the log is on).
    private(set) var cellBodies = 0
    func countCell() { if enabled { cellBodies += 1 } }
    weak var view: NSView?
    private(set) var records: [Record] = []
    private var link: CADisplayLink?
    private var timer: Timer?
    private var active = false
    private var label = ""
    private var stamps: [CFTimeInterval] = []
    private var until: CFTimeInterval = 0
    private var cellsAtStart = 0
    private var busy: [CFTimeInterval] = []
    private var woke: CFTimeInterval = 0
    private var observers: [CFRunLoopObserver] = []

    func begin(_ label: String, seconds: Double) {
        guard enabled, let view else { return }
        finish()
        installObservers()
        active = true
        self.label = label
        stamps = [CACurrentMediaTime()]
        until = stamps[0] + seconds
        cellsAtStart = cellBodies
        busy = []
        woke = stamps[0]
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // A window on no real screen gets no display frames: end on time anyway.
        let timer = Timer(timeInterval: seconds + 0.05, repeats: false) { _ in
            MainActor.assumeIsolated { FrameLog.shared.finish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        if link.timestamp >= until { finish() }
    }

    /// Busy = from the run loop waking up (first observer) to it going to sleep again (last observer, after Core
    /// Animation's commit), so event handling, SwiftUI's update and the commit are all inside.
    private func installObservers() {
        guard observers.isEmpty else { return }
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            MainActor.assumeIsolated { FrameLog.shared.woke = CACurrentMediaTime() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                let log = FrameLog.shared
                guard log.active else { return }
                log.busy.append(CACurrentMediaTime() - log.woke)
            }
        }
        for o in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
            observers.append(o)
        }
    }

    func finish() {
        guard active else { return }
        active = false
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        let fps = max(60, view?.window?.screen?.maximumFramesPerSecond ?? 60)
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let interval = 1 / Double(fps)
        let late = gaps.filter { $0 > 1.5 * interval }
        let record = Record(label: label, frames: gaps.count, maxGap: gaps.max() ?? 0, dropped: late.count, maxFPS: fps,
                            hitch: late.reduce(0) { $0 + $1 - interval }, duration: gaps.reduce(0, +),
                            busyMax: busy.max() ?? 0, busyOver120: busy.filter { $0 > 1.0 / 120 }.count,
                            busyOver60: busy.filter { $0 > 1.0 / 60 }.count, cells: cellBodies - cellsAtStart)
        records.append(record)
        print(String(format: "fps %@: %d frames, longest %.1f ms, dropped %d (%d Hz); main thread longest %.1f ms, over 8.3 ms %d, over 16.7 ms %d; cells %d",
                     record.label, record.frames, record.maxGap * 1000, record.dropped, record.maxFPS,
                     record.busyMax * 1000, record.busyOver120, record.busyOver60, record.cells))
    }
}

/// `LaunchMat --fps-bench`: opens and closes the grid 10 times, flips pages with synthetic trackpad swipes and
/// mouse-wheel notches, drags icons (making room on the page, and over the edge to the next page), wiggles them with
/// ⌥, and opens and closes a folder, all through the real event handlers, logging each with FrameLog; then prints
/// medians and quits. Reads the saved layout but never writes it.
///
/// - `--scenes open,page,drag,dragpage,jiggle,jdrag,folder`: only these (default all). `cold` or `coldlater` instead:
///   the first open after launch, alone (see coldStart).
/// - `--runs N`: each drag, wiggle and folder scene N times (default 3).
/// - `--bench-screen N`: on `NSScreen.screens[N]` instead of the screen Settings picks.
/// - `--offscreen`: on a made-up screen far from the real ones, so nothing is seen and the app isn't activated. No
///   display frames there: only the main thread's busy stretches and the cell counts mean anything.
@MainActor
enum FrameBench {
    static func run(model: LaunchpadModel) -> Never {
        let args = CommandLine.arguments
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let scenes = Set((value("--scenes") ?? "open,page,drag,dragpage,jiggle,jdrag,folder").split(separator: ",").map(String.init))
        let runs = max(1, Int(value("--runs") ?? "") ?? 3)
        let offscreen = args.contains("--offscreen")
        let screenIndex = value("--bench-screen").flatMap(Int.init).flatMap { NSScreen.screens.indices.contains($0) ? $0 : nil }
        if scenes.contains("cold") || scenes.contains("coldlater") {
            coldStart(model, later: scenes.contains("coldlater"), offscreen: offscreen, screen: screenIndex.map { NSScreen.screens[$0] })
        }

        model.persistenceEnabled = false
        let loadStart = CACurrentMediaTime()
        model.load(sync: true)
        print(String(format: "fps load: %d apps with icons in %.0f ms", model.icons.count, (CACurrentMediaTime() - loadStart) * 1000))
        model.prepareWallpapers()
        let controller = LaunchWindowController(model: model)
        var screen: NSScreen?
        if offscreen {
            let frame = CGRect(x: 40_000, y: 40_000, width: 1600, height: 900)
            controller.displays = { [.init(id: 1, frame: frame, visibleFrame: frame)] }
            controller.activeDisplay = { 1 }
            controller.pointer = { CGPoint(x: frame.midX, y: frame.midY) }
            controller.showOn = { .cursor }
            controller.activatesApp = false
            print("fps bench: off screen (1600 × 900), main thread and cell counts only")
        } else if let n = screenIndex {
            screen = NSScreen.screens[n]
        }
        // Started from a script the app may stay inactive (off screen it always does), and then the window's first click
        // would only activate it: the content takes clicks anyway, as in the self-test and the film takes.
        controller.window.contentView = TestHostingView(rootView: RootView(model: model))
        FrameRateBoost.view = controller.window.contentView
        FrameLog.shared.enabled = true
        FrameLog.shared.view = controller.window.contentView
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func show() {
            controller.show(on: screen)
            wait(1.0)
        }
        func hide() {
            controller.hide()
            wait(0.7)
        }

        wait(1.0)
        if scenes.contains("open") {
            for _ in 0..<10 {
                controller.show(on: screen)
                wait(0.7)
                controller.hide()
                wait(0.7)
            }
        }
        show()
        if let s = controller.window.screen {
            print("fps bench: screen \(s.localizedName), \(Int(s.frame.width)) × \(Int(s.frame.height)), \(s.maximumFramesPerSecond) Hz; "
                  + "\(model.placedEntries.count) cells on \(model.pageCount) pages")
        }
        if scenes.contains("page") { paging(model) }
        let mouse = Mouse(window: controller.window)
        if scenes.contains("drag") {
            for _ in 0..<runs { dragOnPage(model, mouse); wait(0.5) }
        }
        if scenes.contains("dragpage") {
            for _ in 0..<runs {
                dragToNextPage(model, mouse)
                model.go(to: 0)
                wait(1.0)
            }
        }
        if scenes.contains("jiggle") {
            for _ in 0..<runs {
                FrameLog.shared.begin("jiggle", seconds: 2.3)
                model.optionHeld = true // as the ⌥ key does (the window's flagsChanged monitor)
                wait(2.0)
                model.optionHeld = false
                wait(0.8)
            }
        }
        if scenes.contains("jdrag") {
            for _ in 0..<runs {
                model.optionHeld = true
                wait(0.4)
                dragOnPage(model, mouse, label: "jdrag")
                model.optionHeld = false
                wait(0.6)
            }
        }
        if scenes.contains("folder") { folder(model, mouse, runs: runs) }
        hide()

        print("fps summary (median of runs; dropped = frames over 1.5 refresh intervals; hitch ratio = ms late per s;")
        print("  main = the main thread's longest busy stretch; over 8.3 ms would miss a 120 Hz frame, over 16.7 ms a 60 Hz one):")
        let byLabel = Dictionary(grouping: FrameLog.shared.records, by: \.label)
        for label in ["open", "close", "track", "page", "drag", "dragpage", "jiggle", "jdrag", "fopen", "fclose"] {
            guard let runs = byLabel[label], !runs.isEmpty else { continue }
            func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
            let ratio = runs.map(\.hitch).reduce(0, +) / max(0.001, runs.map(\.duration).reduce(0, +)) * 1000
            print(String(format: "  %@: n=%d, dropped median %.0f (max %d), longest gap median %.1f ms (worst %.1f ms), hitch ratio %.0f ms/s; "
                         + "main median %.1f ms (worst %.1f ms), over 8.3 ms median %.0f, over 16.7 ms median %.0f; cells median %.0f",
                         label, runs.count, median(runs.map { Double($0.dropped) }), runs.map(\.dropped).max()!,
                         median(runs.map(\.maxGap)) * 1000, runs.map(\.maxGap).max()! * 1000, ratio,
                         median(runs.map(\.busyMax)) * 1000, runs.map(\.busyMax).max()! * 1000,
                         median(runs.map { Double($0.busyOver120) }), median(runs.map { Double($0.busyOver60) }),
                         median(runs.map { Double($0.cells) })))
        }
        exit(0)
    }

    // MARK: - Cold start

    /// The first open after the app starts, as at launch (LaunchWindowController.launch): the grid opens at once
    /// (`cold`, as when the app is opened) or 3 s later (`coldlater`, as with the hotkey after a login). Prints when the
    /// apps were scanned and their icons loaded, how many of the first page's icons were there when the grid opened, and
    /// the opening and the 1.5 s after it. Each needs a fresh process, so it runs alone and quits.
    private static func coldStart(_ model: LaunchpadModel, later: Bool, offscreen: Bool, screen: NSScreen?) -> Never {
        let launched = CACurrentMediaTime()
        func ms(_ t: CFTimeInterval?) -> String { t.map { String(format: "%.0f ms", ($0 - launched) * 1000) } ?? "not yet" }
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        model.persistenceEnabled = false
        FrameLog.shared.enabled = true
        let controller = LaunchWindowController.launch(model: model) { c in
            guard offscreen else { return }
            let frame = CGRect(x: 40_000, y: 40_000, width: 1600, height: 900)
            c.displays = { [.init(id: 1, frame: frame, visibleFrame: frame)] }
            c.activeDisplay = { 1 }
            c.pointer = { CGPoint(x: frame.midX, y: frame.midY) }
            c.showOn = { .cursor }
            c.activatesApp = false
        }
        var scanned: CFTimeInterval?, firstIcons: CFTimeInterval?, allIcons: CFTimeInterval?
        let watch = Timer(timeInterval: 0.002, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                if scanned == nil, !model.apps.isEmpty { scanned = now }
                if firstIcons == nil, !model.icons.isEmpty { firstIcons = now }
                if allIcons == nil, !model.apps.isEmpty, model.icons.count >= model.apps.count { allIcons = now }
            }
        }
        RunLoop.main.add(watch, forMode: .common)
        if later { wait(3.0) }
        let firstPage = model.layout.pages.first ?? []
        func ready() -> Int {
            firstPage.filter { entry in
                switch entry {
                case .app(let path): model.icons[path] != nil
                case .folder(let id): (model.layout.folders[id]?.apps ?? []).allSatisfy { model.icons[$0] != nil }
                }
            }.count
        }
        var shown = CACurrentMediaTime()
        if later {
            controller.show(on: screen)
        } else {
            // As the app does at launch: it opens once the first two pages' icons are in (at most 0.6 s).
            controller.showWhenReady(on: screen)
            while !controller.isVisible, CACurrentMediaTime() - shown < 2 { wait(0.002) }
            shown = CACurrentMediaTime()
        }
        let readyAtOpen = ready()
        wait(0.5)
        FrameLog.shared.begin("afteropen", seconds: 1.5)
        wait(1.7)
        watch.invalidate()
        print("fps \(later ? "coldlater" : "cold"): apps scanned at \(ms(scanned)), first icons at \(ms(firstIcons)), all icons at "
              + "\(ms(allIcons)) (\(model.icons.count) of \(model.apps.count)); opened at \(ms(shown)) with \(readyAtOpen) of "
              + "\(firstPage.count) first-page icons ready")
        controller.hide()
        wait(0.6)
        exit(0)
    }

    // MARK: - Scenes

    /// Synthetic left-button events sent to the grid's window, one every 1/120 s while moving (as a 120 Hz pointer).
    @MainActor
    private struct Mouse {
        let window: NSWindow

        func send(_ type: NSEvent.EventType, _ p: CGPoint) {
            if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: window.frame.height - p.y), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                window.sendEvent(e)
            }
        }

        /// Moves with the button down from `a` to `b` in `seconds`, easing in and out.
        func glide(_ a: CGPoint, _ b: CGPoint, seconds: Double) {
            let steps = max(1, Int(seconds * 120))
            for k in 1...steps {
                let t = Double(k) / Double(steps)
                let e = CGFloat(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
                send(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e))
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            }
        }

        func hold(_ p: CGPoint, seconds: Double) {
            let steps = max(1, Int(seconds * 120))
            for _ in 0..<steps {
                send(.leftMouseDragged, p)
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            }
        }

        func click(_ p: CGPoint) {
            send(.leftMouseDown, p)
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            send(.leftMouseUp, p)
        }
    }

    /// The line below the icons of the first row, inside the cells: there the pointer only sorts (the merge zone is
    /// the middle of an icon), so the drag makes room without making folders.
    private static func gap(_ m: GridMetrics, _ slot: Int) -> CGPoint {
        let c = m.cellCenter(slot)
        return CGPoint(x: c.x, y: c.y + m.cell.height * 0.42)
    }

    /// Picks up the second icon of the page and carries it four cells right and back two, below the icons, so the
    /// others make room (0.36 s each time), then drops it.
    private static func dragOnPage(_ model: LaunchpadModel, _ mouse: Mouse, label: String = "drag") {
        let m = model.metrics
        let cols = model.gridSize.cols
        let page = model.currentPage < model.layout.pages.count ? model.layout.pages[model.currentPage] : []
        guard page.count >= 3 else { return print("fps bench: too few icons on the page for \(label)") }
        let far = min(cols - 1, min(page.count - 1, 5))
        let start = m.iconCenter(1)
        let order = page
        defer { if model.layout.pages[model.currentPage] == order { print("fps bench: \(label) moved nothing (no clicks reached the grid?)") } }
        FrameLog.shared.begin(label, seconds: 3.4)
        mouse.send(.leftMouseDown, start)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
        mouse.glide(start, gap(m, 1), seconds: 0.2)
        mouse.glide(gap(m, 1), gap(m, far), seconds: 1.6)
        mouse.glide(gap(m, far), gap(m, 2), seconds: 1.0)
        mouse.send(.leftMouseUp, gap(m, 2))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }

    /// Picks up the third icon, carries it to the right edge and holds it there until the page turns (0.6 s), then
    /// into the next page and drops it.
    private static func dragToNextPage(_ model: LaunchpadModel, _ mouse: Mouse) {
        let m = model.metrics
        let page = model.currentPage < model.layout.pages.count ? model.layout.pages[model.currentPage] : []
        guard page.count >= 3 else { return print("fps bench: too few icons on the page for dragpage") }
        let start = m.iconCenter(2)
        let before = model.currentPage
        defer { if model.currentPage == before { print("fps bench: dragpage turned no page (no clicks reached the grid?)") } }
        let edge = CGPoint(x: m.size.width - 8, y: gap(m, 2).y)
        FrameLog.shared.begin("dragpage", seconds: 3.0)
        mouse.send(.leftMouseDown, start)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
        mouse.glide(start, gap(m, 2), seconds: 0.2)
        mouse.glide(gap(m, 2), edge, seconds: 0.6)
        mouse.hold(edge, seconds: 1.3)
        mouse.glide(edge, gap(m, 3), seconds: 0.5)
        mouse.send(.leftMouseUp, gap(m, 3))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }

    /// Clicks the first folder on its page (it grows open, 0.28 s), then the blank space around the panel (it
    /// shrinks back into its icon).
    private static func folder(_ model: LaunchpadModel, _ mouse: Mouse, runs: Int) {
        guard let (page, slot) = model.layout.pages.enumerated().lazy.compactMap({ p, entries in
            entries.firstIndex { $0.folderID != nil }.map { (p, $0) }
        }).first else { return print("fps bench: no folder, folder scenes skipped") }
        model.go(to: page)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let m = model.metrics
        for _ in 0..<runs {
            FrameLog.shared.begin("fopen", seconds: 0.5)
            mouse.click(m.iconCenter(slot))
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            FrameLog.shared.begin("fclose", seconds: 0.5)
            mouse.click(CGPoint(x: m.size.width / 2, y: m.size.height - 12))
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        }
        model.go(to: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    }

    private static func paging(_ model: LaunchpadModel) {
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        guard model.pageCount > 1 else { return print("fps bench: only one page, no paging measured") }
        // The first turns of this process: next, back, next again. If only the first stutters, the cost is
        // drawing the neighbouring page for the first time.
        let probeStart = FrameLog.shared.records.count
        var forward: CGFloat = -1
        swipe(model, dx: forward * 120)
        wait(0.9)
        if model.currentPage == 0 {
            forward = -forward
            swipe(model, dx: forward * 120)
            wait(0.9)
        }
        var cells: [Int] = []
        for dx in [-forward * 120, forward * 120] {
            let before = FrameLog.shared.cellBodies
            swipe(model, dx: dx)
            wait(0.9)
            cells.append(FrameLog.shared.cellBodies - before)
        }
        print("fps probe: icon cells drawn again per turn (turns 2 and 3): \(cells.map(String.init).joined(separator: ", ")); "
              + "\(model.placedEntries.count) cells")
        let probe = FrameLog.shared.records[probeStart...].filter { $0.label == "page" || $0.label == "track" }
        print("fps probe (track = fingers moving, page = settling), first turns in order:")
        for r in probe { print(String(format: "  probe %@: longest %.1f ms, dropped %d", r.label, r.maxGap * 1000, r.dropped)) }

        // Whichever way a synthetic swipe turns the page, turn back when it stops moving.
        var direction: CGFloat = -1
        for _ in 0..<10 {
            let before = model.currentPage
            swipe(model, dx: direction * 120)
            wait(0.9)
            if model.currentPage == before { direction = -direction }
        }
        var notch: CGFloat = -3
        for _ in 0..<6 {
            let before = model.currentPage
            wheel(model, dy: notch)
            wait(0.9)
            if model.currentPage == before { notch = -notch }
        }
        model.go(to: 0)
        wait(1.0)
    }

    /// A two-finger horizontal swipe: began, a few changed events, ended (no momentum).
    private static func swipe(_ model: LaunchpadModel, dx: CGFloat) {
        let steps = 8
        for i in 0...steps + 1 {
            let phase: Int64 = i == 0 ? 1 : (i == steps + 1 ? 4 : 2) // began, changed, ended
            let delta = i == 0 || i == steps + 1 ? 0 : dx / CGFloat(steps)
            if let e = scrollEvent(dx: delta, dy: 0, continuous: true, phase: phase) { model.handleScroll(e) }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
        }
    }

    private static func wheel(_ model: LaunchpadModel, dy: CGFloat) {
        if let e = scrollEvent(dx: 0, dy: dy, continuous: false, phase: 0) { model.handleScroll(e) }
    }

    private static func scrollEvent(dx: CGFloat, dy: CGFloat, continuous: Bool, phase: Int64) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        return NSEvent(cgEvent: cg)
    }
}
