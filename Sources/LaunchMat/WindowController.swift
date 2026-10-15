import AppKit
import Carbon.HIToolbox
import LaunchMatCore
import SwiftUI

/// Borderless windows refuse key status by default; the search field needs it.
final class LaunchWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class LaunchWindowController: NSObject {
    let model: LaunchpadModel
    let window: LaunchWindow
    private(set) var isVisible = false
    private var generation = 0
    private var monitors: [Any] = []
    /// The app's main menu (the one under the menu bar icon), opened by a right-click on blank space.
    var mainMenu: (() -> NSMenu)?

    /// A screen as the grid uses it. `screen` is nil only for the self-test's made-up screens.
    struct Display {
        let id: CGDirectDisplayID
        let frame: CGRect
        let visibleFrame: CGRect
        let screen: NSScreen?

        init(_ screen: NSScreen) {
            self.init(id: screen.displayID, frame: screen.frame, visibleFrame: screen.visibleFrame, screen: screen)
        }

        init(id: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect, screen: NSScreen? = nil) {
            self.id = id
            self.frame = frame
            self.visibleFrame = visibleFrame
            self.screen = screen
        }
    }

    /// The screens (the primary one first), the active window's screen and the pointer. The self-test replaces them.
    var displays: () -> [Display] = { NSScreen.screens.map(Display.init) }
    var activeDisplay: () -> CGDirectDisplayID? = { NSScreen.main?.displayID }
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }
    var showOn: () -> ShowOn = { Settings.showOn }
    /// Off in the self-test, so it never takes the focus from the app in front.
    var activatesApp = true
    /// How many screens there were when the grid opened, or at the last change since: a different count closes an
    /// open grid (spec 12, M2).
    private var screenCount = 0
    /// The screen the grid is open on.
    private(set) var shownOn: CGDirectDisplayID?

    init(model: LaunchpadModel) {
        self.model = model
        window = LaunchWindow(contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        // Above the Dock and the menu bar, on every Space, next to full-screen apps.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: RootView(model: model))
        FrameLog.shared.view = window.contentView
        FrameRateBoost.view = window.contentView
        model.dismissHandler = { [weak self] in self?.hide() }
        model.showMainMenu = { [weak self] in
            guard let self, let view = self.window.contentView, let menu = self.mainMenu?() else { return }
            let p = view.convert(self.window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            menu.popUp(positioning: nil, at: p, in: view)
        }

        // A new Space can have another desktop picture; screens can be added or rearranged.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.prepareWallpapers() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensChanged()
                self?.model.prepareWallpapers()
                self?.model.refreshIconSize()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        // Local monitors run on the main thread; NSEvent just isn't marked Sendable.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let e = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isVisible else { return false }
                return self.model.handleKey(e)
            }
            return handled ? nil : event
        } as Any)
        // Right-click, or Control-click, opens a menu: the icon's own, or on blank space the main menu.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            if event.type == .leftMouseDown && !event.modifierFlags.contains(.control) { return event }
            nonisolated(unsafe) let e = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isVisible, e.window === self.window, self.model.drag == nil,
                      let view = self.window.contentView else { return false }
                let p = view.convert(e.locationInWindow, from: nil)
                let root = CGPoint(x: p.x, y: view.isFlipped ? p.y : view.bounds.height - p.y)
                // An icon: its own menu, built now. Blank space: the main menu (not over an open folder).
                if let hit = self.model.entry(at: root) {
                    EntryMenu.make(model: self.model, entry: hit.entry, folder: hit.folder).popUp(positioning: nil, at: p, in: view)
                    return true
                }
                guard self.model.openFolder == nil, self.model.isBlank(at: root), let menu = self.mainMenu?() else { return false }
                menu.popUp(positioning: nil, at: p, in: view)
                return true
            }
            return handled ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            nonisolated(unsafe) let e = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isVisible else { return false }
                self.model.handleScroll(e)
                return true
            }
            return handled ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let option = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated {
                guard let self, self.isVisible, self.model.optionHeld != option else { return }
                self.model.optionHeld = option
            }
            return event
        } as Any)
    }

    func toggle() { isVisible ? hide() : show() }

    /// Opens on the screen Settings › Show on picks, worked out now, or on `preferred` (the film's takes).
    func show(on preferred: NSScreen? = nil) {
        // Never cover an open dialog (e.g. the uninstall confirmation).
        guard !isVisible, NSApp.modalWindow == nil, let display = preferred.map(Display.init) ?? pickDisplay() else { return }
        isVisible = true
        FrameLog.shared.begin("open", seconds: 0.45)
        generation += 1
        let gen = generation
        window.setFrame(display.frame, display: false)
        shownOn = display.id
        screenCount = displays().count
        model.screenShown = display.screen
        model.willShow(on: display.screen)
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        if activatesApp { NSApp.activate() }
        animate(open: true) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.model.didShow()
        }
    }

    /// Settings › Show on, with its fallbacks: the active screen, then the primary one (spec 12, M4).
    func pickDisplay() -> Display? {
        let all = displays()
        let active = activeDisplay().flatMap { id in all.firstIndex { $0.id == id } }
        let edge = DockEdge(rawValue: UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "") ?? .bottom
        let i = ScreenChoice.pick(showOn(), screens: all.map { ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame) },
                                  active: active, cursor: pointer(), dock: edge)
        return i.map { all[$0] }
    }

    /// Screens were added, removed, resized, rescaled or rearranged (spec 12). A different number of screens, or the
    /// grid's own screen gone, closes an open grid the usual way; it isn't reopened, and the next open picks a screen
    /// afresh. Otherwise an open grid is fitted to its screen's new frame where it is, without animation, and the grid
    /// follows the window's size.
    func screensChanged() {
        let all = displays()
        let countChanged = all.count != screenCount
        screenCount = all.count
        guard isVisible else { return }
        guard !countChanged, let display = all.first(where: { $0.id == shownOn }) else {
            hide()
            return
        }
        model.screenShown = display.screen
        if window.frame != display.frame { window.setFrame(display.frame, display: true) }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        FrameLog.shared.begin("close", seconds: 0.4)
        generation += 1
        let gen = generation
        animate(open: false) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.window.orderOut(nil)
            self.model.didHide()
        }
    }

    /// Opening: the content fades in while it settles from 105% to 100%. Closing: the reverse. One Core Animation
    /// transaction on the content view's layer, 0.24 s ease-out, so SwiftUI redraws nothing while it runs. When it
    /// interrupts the other direction, it starts from what is on screen, for the remaining share of the time.
    private func animate(open: Bool, completion: @escaping @MainActor () -> Void) {
        guard let view = window.contentView else { return completion() }
        view.wantsLayer = true
        guard let layer = view.layer else { return completion() }
        let size = view.bounds.size
        func scaled(_ s: CGFloat) -> CATransform3D {
            // Scale about the centre (the backing layer's anchor point is its corner).
            var t = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
            t = CATransform3DScale(t, s, s, 1)
            return CATransform3DTranslate(t, -size.width / 2, -size.height / 2, 0)
        }
        let restScale: CGFloat = 1.05
        let shown = layer.presentation()
        let animating = layer.animation(forKey: "launchmat.opacity") != nil
        let fromOpacity = animating ? CGFloat(shown?.opacity ?? 0) : (open ? 0 : 1)
        let fromScale = animating ? (shown?.transform.m11 ?? restScale) : (open ? restScale : 1)
        let toOpacity: CGFloat = open ? 1 : 0
        let toScale: CGFloat = open ? 1 : restScale
        let duration = 0.24 * max(0.05, abs(toOpacity - fromOpacity))

        let fps = Float(max(60, window.screen?.maximumFramesPerSecond ?? 60))
        func basic(_ key: String, _ from: Any, _ to: Any) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            a.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, fps), maximum: fps, preferred: fps)
            return a
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        layer.removeAnimation(forKey: "launchmat.opacity")
        layer.removeAnimation(forKey: "launchmat.transform")
        layer.add(basic("opacity", fromOpacity, toOpacity), forKey: "launchmat.opacity")
        layer.add(basic("transform", NSValue(caTransform3D: scaled(fromScale)), NSValue(caTransform3D: scaled(toScale))),
                  forKey: "launchmat.transform")
        CATransaction.commit()
    }
}

/// Asks the display for its highest refresh rate while a SwiftUI animation runs (page turns): Core Animation's own
/// animations carry their frame-rate range, SwiftUI's don't, so an idle display link holds the rate up.
@MainActor
enum FrameRateBoost {
    static weak var view: NSView?
    private static var link: CADisplayLink?
    private static var until: CFTimeInterval = 0
    private static let target = Target()

    static func hold(for seconds: Double) {
        guard let view else { return }
        until = max(until, CACurrentMediaTime() + seconds)
        guard link == nil else { return }
        let fps = Float(max(60, view.window?.screen?.maximumFramesPerSecond ?? 60))
        let link = view.displayLink(target: target, selector: #selector(Target.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, fps), maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate static func tick(_ link: CADisplayLink) {
        guard link.timestamp >= until else { return }
        link.invalidate()
        self.link = nil
    }

    private final class Target: NSObject {
        @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { FrameRateBoost.tick(link) } }
    }
}

/// Global hotkey via Carbon RegisterEventHotKey (no permission needed).
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, id: UInt32 = 1, handler: @escaping () -> Void) {
        HotKey.handlers[id] = handler
        HotKey.installIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C47_5244), id: id) // 'LGRD'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("LaunchMat: hotkey registration failed (\(status))") }
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
