import AppKit
import QuartzCore

/// Frame-interval log for animations, a debugging aid: `LAUNCHMAT_FPS_LOG=1` (or `--fps-bench`) records every display
/// frame while an open, close or page animation runs, then prints the frame count, the longest gap and the frames
/// that took more than 1.5 refresh intervals ("dropped"). The display link fires on the main run loop, so a busy main
/// thread shows up as a long gap.
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
    }

    var enabled = ProcessInfo.processInfo.environment["LAUNCHMAT_FPS_LOG"] == "1"
    weak var view: NSView?
    private(set) var records: [Record] = []
    private var link: CADisplayLink?
    private var label = ""
    private var stamps: [CFTimeInterval] = []
    private var until: CFTimeInterval = 0

    func begin(_ label: String, seconds: Double) {
        guard enabled, let view else { return }
        finish()
        self.label = label
        stamps = [CACurrentMediaTime()]
        until = stamps[0] + seconds
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        if link.timestamp >= until { finish() }
    }

    private func finish() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        let fps = max(60, view?.window?.screen?.maximumFramesPerSecond ?? 60)
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let interval = 1 / Double(fps)
        let late = gaps.filter { $0 > 1.5 * interval }
        let record = Record(label: label, frames: gaps.count, maxGap: gaps.max() ?? 0, dropped: late.count, maxFPS: fps,
                            hitch: late.reduce(0) { $0 + $1 - interval }, duration: gaps.reduce(0, +))
        records.append(record)
        print(String(format: "fps %@: %d frames, longest %.1f ms, dropped %d (%d Hz)",
                     record.label, record.frames, record.maxGap * 1000, record.dropped, record.maxFPS))
    }
}

/// `LaunchMat --fps-bench`: opens and closes the grid 10 times and flips pages with synthetic trackpad swipes and
/// mouse-wheel notches through the real event handlers, logging every animation with FrameLog, then prints medians
/// and quits. Reads the saved layout but never writes it.
@MainActor
enum FrameBench {
    static func run(model: LaunchpadModel) -> Never {
        model.persistenceEnabled = false
        model.load(sync: true)
        model.prepareWallpapers()
        let controller = LaunchWindowController(model: model)
        FrameLog.shared.enabled = true
        FrameLog.shared.view = controller.window.contentView
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        wait(1.0)
        for _ in 0..<10 {
            controller.show()
            wait(0.7)
            controller.hide()
            wait(0.7)
        }
        controller.show()
        wait(1.0)
        if model.pageCount > 1 {
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
            swipe(model, dx: -forward * 120)
            wait(0.9)
            swipe(model, dx: forward * 120)
            wait(0.9)
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
        } else {
            print("fps bench: only one page, no paging measured")
        }
        controller.hide()
        wait(0.7)

        print("fps summary (median of runs; dropped = frames over 1.5 refresh intervals; hitch ratio = ms late per s):")
        let byLabel = Dictionary(grouping: FrameLog.shared.records, by: \.label)
        for label in ["open", "close", "track", "page"] {
            guard let runs = byLabel[label], !runs.isEmpty else { continue }
            func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
            let ratio = runs.map(\.hitch).reduce(0, +) / max(0.001, runs.map(\.duration).reduce(0, +)) * 1000
            print(String(format: "  %@: n=%d, dropped median %.0f (max %d), longest gap median %.1f ms (worst %.1f ms), hitch ratio %.0f ms/s",
                         label, runs.count, median(runs.map { Double($0.dropped) }), runs.map(\.dropped).max()!,
                         median(runs.map(\.maxGap)) * 1000, runs.map(\.maxGap).max()! * 1000, ratio))
        }
        exit(0)
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
