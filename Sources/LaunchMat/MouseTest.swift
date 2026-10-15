import AppKit
import LaunchMatCore
import SwiftUI

/// `LaunchMat --mouse-test`: hands synthetic mouse events straight to the grid window (nothing is posted to the
/// system, no permission needed) and checks how presses on icons and on blank space are read. Uses a fresh layout,
/// saves nothing and opens no apps (launches are recorded instead). Prints PASS/FAIL per check.
@MainActor
enum MouseTest {
    private static var failures = 0

    static func run(model: LaunchpadModel) -> Never {
        model.persistenceEnabled = false
        var launched: [String] = []
        model.launchHandler = { launched.append($0) }
        model.load(fresh: true, sync: true)
        let controller = LaunchWindowController(model: model)
        let window = controller.window
        // Started from a script, the app can't become active, and an inactive window would spend every press on
        // activating itself. For the test only, the content takes clicks without being active.
        window.contentView = FirstClickHostingView(rootView: RootView(model: model))
        controller.show()
        wait(1.0)
        let m = model.metrics
        guard model.pageCount >= 2 else {
            print("mouse test: needs at least two pages")
            exit(1)
        }

        func send(_ type: NSEvent.EventType, _ p: CGPoint) {
            // SwiftUI's root space has its origin top left; window coordinates bottom left.
            let location = NSPoint(x: p.x, y: window.frame.height - p.y)
            if let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1,
                                          pressure: type == .leftMouseUp ? 0 : 1) {
                window.sendEvent(e)
            }
            wait(1.0 / 60)
        }
        /// Press at `start`, move by `by` in a few steps, check something mid-press, release.
        func press(_ start: CGPoint, by: CGSize, steps: Int = 8, during: (() -> Void)? = nil) {
            send(.leftMouseDown, start)
            for i in 1...steps {
                let f = CGFloat(i) / CGFloat(steps)
                send(.leftMouseDragged, CGPoint(x: start.x + by.width * f, y: start.y + by.height * f))
            }
            during?()
            send(.leftMouseUp, CGPoint(x: start.x + by.width, y: start.y + by.height))
            wait(0.9)
        }

        // Blank space: the left margin, a gap between two icons, an empty slot.
        let margin = CGPoint(x: m.gridRect.minX / 2, y: m.gridRect.midY)
        press(margin, by: CGSize(width: -120, height: 0))
        check("margin: drag left 120 pt turns to page 2", model.currentPage == 1)

        let gap = CGPoint(x: m.cellCenter(0).x + m.cell.width / 2, y: m.iconCenter(0).y)
        press(gap, by: CGSize(width: 120, height: 0))
        check("gap between icons: drag right 120 pt turns back to page 1", model.currentPage == 0)

        let last = model.layout.pages.count - 1
        model.go(to: last)
        wait(0.9)
        if model.layout.pages[last].count < model.capacity {
            let empty = m.iconCenter(model.layout.pages[last].count)
            press(empty, by: CGSize(width: 120, height: 0))
            check("empty slot: drag right 120 pt turns to the previous page", model.currentPage == last - 1)
        } else {
            print("SKIP  empty slot: the last page is full")
        }
        model.go(to: 0)
        wait(0.9)

        press(margin, by: CGSize(width: -30, height: 0))
        check("margin: drag 30 pt springs back (under 50 pt)", model.currentPage == 0 && controller.isVisible)
        press(margin, by: CGSize(width: 0, height: 60))
        check("margin: vertical drag neither turns nor closes", model.currentPage == 0 && controller.isVisible)

        // Icons.
        let entry0 = model.layout.pages[0][0]
        var dragDuring3pt = true
        press(m.iconCenter(0), by: CGSize(width: 3, height: 0), steps: 3) { dragDuring3pt = model.drag != nil }
        check("icon: moving 3 pt does not start a drag", !dragDuring3pt)
        let clicked = entry0.appPath.map { launched.contains($0) } ?? (model.openFolder != nil)
        check("icon: releasing after 3 pt is a click (opens it)", clicked)
        if model.openFolder != nil { model.closeFolder(); wait(0.5) }

        var grab = CGSize.zero, dragging = false
        let grabbed = CGPoint(x: m.iconCenter(1).x + 15, y: m.iconCenter(1).y + 10)
        launched.removeAll()
        press(grabbed, by: CGSize(width: 0, height: 4), steps: 2) { dragging = model.drag != nil }
        check("icon: moving 4 pt starts a drag", dragging)
        press(grabbed, by: CGSize(width: 40, height: 0)) {
            grab = model.drag?.grab ?? .zero
        }
        check("icon: the dragged icon keeps the grab point (15, 10) from its centre",
              abs(grab.width - 15) < 0.5 && abs(grab.height - 10) < 0.5)
        check("icon: a drag doesn't open anything", launched.isEmpty)

        let blankClickVisible = controller.isVisible
        press(margin, by: .zero, steps: 1)
        check("margin: a click on blank space closes the grid", blankClickVisible && !controller.isVisible)

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private final class FirstClickHostingView: NSHostingView<RootView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private static func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private static func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL")  \(name)")
        if !ok { failures += 1 }
    }
}
