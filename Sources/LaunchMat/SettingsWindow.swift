import AppKit
import LaunchMatCore
import SwiftUI

/// What the settings window can ask the app to do; the app delegate implements it (it owns the hotkey, the hot corner,
/// the pinch monitor and the alerts).
@MainActor
protocol AppActions: AnyObject {
    func setHotkey(_ choice: HotkeyChoice)
    func setHotCorner(_ corner: HotCorner)
    func setPinch(_ fingers: PinchFingers)
    func setLaunchAtLogin(_ on: Bool)
    func importLegacyLayout()
    func confirmResetLayout()
    func revealLayoutFile()
    func openAccessibilitySettings()
    func openURL(_ url: URL)
}

enum Links {
    static let repository = URL(string: "https://github.com/Jimmygplus/LaunchMat")!
    static let feedback = URL(string: "https://github.com/Jimmygplus/LaunchMat/issues")!
    static var releaseNotes: URL {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return URL(string: "https://github.com/Jimmygplus/LaunchMat/releases/tag/v\(version)")!
    }
}

/// The settings shown in the window, read from where they live (UserDefaults, the login item, the layout) each time
/// the window opens; changes go through `AppActions` so their side effects (registering a hotkey…) happen.
@MainActor
final class SettingsState: ObservableObject {
    @Published var hotkey = Settings.hotkey
    @Published var hotCorner = Settings.hotCorner
    @Published var pinch = Settings.pinch
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var accessibilityAllowed = PinchMonitor.isTrusted

    func reload() {
        hotkey = Settings.hotkey
        hotCorner = Settings.hotCorner
        pinch = Settings.pinch
        launchAtLogin = LoginItem.isEnabled
        accessibilityAllowed = PinchMonitor.isTrusted
    }
}

/// The settings window: five tabs in the toolbar, General, Interface, Apps, Advanced and About.
@MainActor
final class SettingsWindowController: NSWindowController {
    enum Tab: Int { case general, interface, apps, advanced, about }

    private let state = SettingsState()
    private let tabs = NSTabViewController()
    private var trustPoll: Timer?

    init(model: LaunchpadModel, actions: AppActions, showGuide: (() -> Void)?) {
        tabs.tabStyle = .toolbar
        let pages: [(String, String, AnyView)] = [
            ("General", "gearshape", AnyView(GeneralSettings(state: state, actions: actions))),
            ("Interface", "square.grid.3x3", AnyView(InterfaceSettings(model: model))),
            ("Apps", "square.stack.3d.up", AnyView(AppsSettings(model: model))),
            ("Advanced", "wrench.and.screwdriver", AnyView(AdvancedSettings(actions: actions))),
            ("About", "info.circle", AnyView(AboutSettings(actions: actions, showGuide: showGuide))),
        ]
        for (title, symbol, view) in pages {
            let host = NSHostingController(rootView: view.frame(width: 460).fixedSize(horizontal: false, vertical: true))
            host.sizingOptions = .preferredContentSize
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ tab: Tab = .general) {
        state.reload()
        tabs.selectedTabViewItemIndex = tab.rawValue
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Accessibility can be granted in System Settings while the window is open.
        trustPoll?.invalidate()
        trustPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return timer.invalidate() }
                self.state.accessibilityAllowed = PinchMonitor.isTrusted
            }
        }
    }
}

// MARK: - Tabs

private struct GeneralSettings: View {
    @ObservedObject var state: SettingsState
    let actions: AppActions

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: { on in
                    actions.setLaunchAtLogin(on)
                    state.launchAtLogin = LoginItem.isEnabled
                }))
            }
            Section("Open LaunchMat with") {
                Picker("Hotkey", selection: Binding(get: { state.hotkey }, set: { k in
                    state.hotkey = k
                    actions.setHotkey(k)
                })) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Hot corner", selection: Binding(get: { state.hotCorner }, set: { c in
                    state.hotCorner = c
                    actions.setHotCorner(c)
                })) {
                    ForEach(HotCorner.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Trackpad pinch", selection: Binding(get: { state.pinch }, set: { f in
                    state.pinch = f
                    actions.setPinch(f)
                })) {
                    ForEach(PinchFingers.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if state.pinch != .off {
                    LabeledContent("Accessibility") {
                        if state.accessibilityAllowed {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Open System Settings…") { actions.openAccessibilitySettings() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct InterfaceSettings: View {
    @ObservedObject var model: LaunchpadModel

    var body: some View {
        Form {
            Picker("Grid size", selection: Binding(get: { model.gridSize }, set: { model.setGrid($0) })) {
                ForEach(GridSize.presets, id: \.self) { Text($0.label).tag($0) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppsSettings: View {
    @ObservedObject var model: LaunchpadModel

    var body: some View {
        let hidden = model.layout.hidden.sorted { model.displayName($0).localizedStandardCompare(model.displayName($1)) == .orderedAscending }
        Form {
            Section {
                if hidden.isEmpty {
                    Text("No hidden apps. Right-click an app in the grid to hide it.").foregroundStyle(.secondary)
                } else {
                    ForEach(hidden, id: \.self) { path in
                        HStack {
                            if let icon = model.icons[path] {
                                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            }
                            Text(model.displayName(path))
                            Spacer()
                            Button("Unhide") { model.unhide(path) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Hidden apps")
                    Spacer()
                    if !hidden.isEmpty { Button("Unhide All") { model.unhideAll() }.controlSize(.small) }
                }
            }
            Section {
                LabeledContent("Applications") {
                    Button("Rescan") { model.refreshApps() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    let actions: AppActions

    var body: some View {
        Form {
            Section("Layout") {
                LabeledContent("Launchpad layout from before macOS 26") {
                    Button("Import…") { actions.importLegacyLayout() }
                }
                LabeledContent("Layout file") {
                    Button("Show in Finder") { actions.revealLayoutFile() }
                }
                LabeledContent("Start over with the default arrangement") {
                    Button("Reset…") { actions.confirmResetLayout() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    let actions: AppActions
    let showGuide: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("LaunchMat").font(.title2.weight(.semibold))
            Text("Version \(AppDelegate.versionLine)").foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("What’s New") { actions.openURL(Links.releaseNotes) }
                Button("Send Feedback") { actions.openURL(Links.feedback) }
                Button("Source Code") { actions.openURL(Links.repository) }
            }
            .padding(.top, 6)
            if let showGuide {
                Button("Show the Welcome Guide Again") { showGuide() }
                    .buttonStyle(.link)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Off-screen pictures for review

/// `LaunchMat --snapshot-settings <dir>` renders each settings tab off-screen to <dir>/settings-<tab>.png and exits.
/// Reads the saved layout but changes nothing.
@MainActor
enum SettingsSnapshot {
    private final class NoActions: AppActions {
        func setHotkey(_ choice: HotkeyChoice) {}
        func setHotCorner(_ corner: HotCorner) {}
        func setPinch(_ fingers: PinchFingers) {}
        func setLaunchAtLogin(_ on: Bool) {}
        func importLegacyLayout() {}
        func confirmResetLayout() {}
        func revealLayoutFile() {}
        func openAccessibilitySettings() {}
        func openURL(_ url: URL) {}
    }

    static func run(model: LaunchpadModel, dir: String) -> Never {
        model.persistenceEnabled = false
        model.load(sync: true)
        let actions = NoActions()
        let state = SettingsState()
        let tabs: [(String, AnyView)] = [
            ("general", AnyView(GeneralSettings(state: state, actions: actions))),
            ("interface", AnyView(InterfaceSettings(model: model))),
            ("apps", AnyView(AppsSettings(model: model))),
            ("advanced", AnyView(AdvancedSettings(actions: actions))),
            ("about", AnyView(AboutSettings(actions: actions, showGuide: {}))),
        ]
        for (name, view) in tabs {
            let host = NSHostingView(rootView: view.frame(width: 460).fixedSize(horizontal: false, vertical: true))
            host.appearance = NSAppearance(named: .aqua)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/settings-\(name).png"))
        }
        exit(0)
    }
}
