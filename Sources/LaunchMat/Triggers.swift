import AppKit
import Carbon.HIToolbox
import ApplicationServices
import LaunchMatCore
import ServiceManagement

enum Settings {
    static var hotCorner: HotCorner {
        get { HotCorner(rawValue: UserDefaults.standard.string(forKey: "hotCorner") ?? "") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotCorner") }
    }

    static var hotkey: HotkeyChoice {
        get { HotkeyChoice(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .shiftCommandSpace }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkey") }
    }

    static var pinch: PinchFingers {
        get { PinchFingers(rawValue: UserDefaults.standard.string(forKey: "pinch") ?? "") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pinch") }
    }
}

/// Polls the cursor (no permission needed) and fires when it rests in the chosen screen corner.
@MainActor
final class HotCornerMonitor {
    private var trigger = HotCornerTrigger(corner: .off)
    private var timer: Timer?
    private let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    var corner: HotCorner {
        get { trigger.corner }
        set {
            trigger = HotCornerTrigger(corner: newValue)
            timer?.invalidate()
            timer = nil
            guard newValue != .off else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons == 0 else { return } // not while dragging toward the edge
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return }
        if trigger.update(point: p, screen: screen.frame, time: ProcessInfo.processInfo.systemUptime) { action() }
    }
}

/// System-wide trackpad pinch via a listen-only event tap on gesture events (needs Accessibility).
/// Finger positions come from the gesture event's touches; `PinchDetector` decides.
final class PinchMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = PinchDetector(fingers: 4...5)
    var onPinchIn: () -> Void = {}
    var onPinchOut: () -> Void = {}

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt once.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// True if the macOS "Launchpad/Apps" four-finger pinch is on (it would fire together with ours).
    static var systemFourFingerPinchEnabled: Bool {
        // Built-in trackpad and Magic Trackpad keep separate settings.
        ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"].contains { domain in
            (UserDefaults(suiteName: domain)?.object(forKey: "TrackpadFourFingerPinchGesture") as? Int ?? 2) != 0
        }
    }

    @discardableResult
    func start(fingers: PinchFingers) -> Bool {
        stop()
        guard let range = fingers.range else { return true }
        guard Self.isTrusted else { return false }
        detector = PinchDetector(fingers: range)
        let gestureType: UInt64 = 29 // NSEvent.EventType.gesture
        let mask = CGEventMask(1 << gestureType)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<PinchMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .gesture else { return }
        let points = ns.touches(matching: .touching, in: nil).map(\.normalizedPosition)
        switch detector.update(points) {
        case .pinchIn?: DispatchQueue.main.async { self.onPinchIn() }
        case .pinchOut?: DispatchQueue.main.async { self.onPinchOut() }
        case nil: break
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message, or nil on success.
    static func set(_ on: Bool) -> String? {
        if on, !Bundle.main.bundlePath.hasPrefix("/Applications/") {
            return "Move LaunchMat to the Applications folder first, then turn this on (it currently runs from "
                + "\(Bundle.main.bundlePath))."
        }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum HotkeyChoice: String, CaseIterable {
    case shiftCommandSpace, optionSpace, controlOptionSpace, f4, off

    var title: String {
        switch self {
        case .shiftCommandSpace: return "⇧⌘Space"
        case .optionSpace: return "⌥Space"
        case .controlOptionSpace: return "⌃⌥Space"
        case .f4: return "F4"
        case .off: return "Off"
        }
    }

    /// (virtual key code, Carbon modifiers)
    var key: (code: Int, modifiers: Int)? {
        switch self {
        case .shiftCommandSpace: return (kVK_Space, shiftKey | cmdKey)
        case .optionSpace: return (kVK_Space, optionKey)
        case .controlOptionSpace: return (kVK_Space, controlKey | optionKey)
        case .f4: return (kVK_F4, 0)
        case .off: return nil
        }
    }
}
