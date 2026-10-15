import AppKit
import Carbon.HIToolbox
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
        model.dismissHandler = { [weak self] in self?.hide() }

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

    func show() {
        // Never cover an open dialog (e.g. the uninstall confirmation).
        guard !isVisible, NSApp.modalWindow == nil else { return }
        isVisible = true
        FrameLog.shared.begin("open", seconds: 0.45)
        generation += 1
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        window.setFrame(screen.frame, display: false)
        model.willShow(on: screen)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        FrameLog.shared.begin("close", seconds: 0.4)
        let gen = generation
        model.willHide()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.window.orderOut(nil)
                self.model.didHide()
            }
        })
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
