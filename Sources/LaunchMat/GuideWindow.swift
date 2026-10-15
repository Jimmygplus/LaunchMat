import AppKit
import LaunchMatCore
import SwiftUI

/// The welcome guide: a 440 × 580 pt window with four pages (welcome, keep your habits, how it opens, done), shown
/// on the first launch of a fresh install and again from Settings › About. Its own frame (no title bar, a single red
/// close dot), its own gradient; the Continue button stays in one place on every page.
@MainActor
final class GuideWindowController: NSWindowController, NSWindowDelegate {
    static let seenKey = "welcomeGuideSeen"
    private let state: GuideState
    var onFinish: (() -> Void)?

    private final class GuideWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override func cancelOperation(_ sender: Any?) { close() }
    }

    init(model: LaunchpadModel, actions: GuideActions) {
        state = GuideState(actions: actions, gridSize: model.gridSize)
        let window = GuideWindow(contentRect: NSRect(x: 0, y: 0, width: GuideMetrics.size.width, height: GuideMetrics.size.height),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        let view = GuideView(state: state, close: { [weak self] in self?.close() },
                             finish: { [weak self] in self?.finish() })
        window.contentView = NSHostingView(rootView: view)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        state.page = 0
        state.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        state.startPolling()
    }

    private func finish() {
        close()
        onFinish?()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        state.stopPolling()
    }
}

/// What the guide asks the app to do.
@MainActor
protocol GuideActions: AnyObject {
    func setHotkey(_ choice: HotkeyChoice)
    func setHotCorner(_ corner: HotCorner)
    func setPinch(_ fingers: PinchFingers)
    func setLaunchAtLogin(_ on: Bool)
    func setGridSize(_ size: GridSize)
    /// Returns true when a layout was imported.
    func importLegacyLayout() -> Bool
}

/// Measurements of the guide, in points from the window's top-left corner.
enum GuideMetrics {
    static let size = CGSize(width: 440, height: 580)
    static let frameWidth: CGFloat = 8          // the dark frame around the panel
    static let outerRadius: CGFloat = 39
    static let innerRadius: CGFloat = 31
    static let textLeft: CGFloat = 41
    static let cardWidth: CGFloat = 360
    static let rowHeight: CGFloat = 40
    static let button = CGSize(width: 110, height: 40)
    static let buttonInset: CGFloat = 24
    static let close = (center: CGPoint(x: 25.5, y: 25.5), diameter: CGFloat(12.5))
    static let frameColor = Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1D / 255)
    static let title = Color(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xE5 / 255)
    static let subtitle = Color(white: 0.62)
    static let buttonBackground = Color(red: 0x2F / 255, green: 0x30 / 255, blue: 0x30 / 255)
    static let buttonText = Color(red: 0xDF / 255, green: 0xDF / 255, blue: 0xDF / 255)
    static let smallButton = Color(red: 0x30 / 255, green: 0x33 / 255, blue: 0x3A / 255)
    static let card = Color.white.opacity(0.06)
}

@MainActor
final class GuideState: ObservableObject {
    @Published var page = 0
    @Published var hotkey = Settings.hotkey
    @Published var hotCorner = Settings.hotCorner
    @Published var pinchOn = Settings.pinch != .off
    @Published var trusted = PinchMonitor.isTrusted
    @Published var inDock = Dock.contains(Bundle.main.bundleURL)
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var imported = false
    @Published var gridSize: GridSize
    /// An old Launchpad database is on this Mac (offered for import on page 2).
    let legacyFound = LegacyLaunchpad.defaultPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
    let actions: GuideActions
    private var poll: Timer?

    init(actions: GuideActions, gridSize: GridSize) {
        self.actions = actions
        self.gridSize = gridSize
    }

    func reload() {
        hotkey = Settings.hotkey
        hotCorner = Settings.hotCorner
        pinchOn = Settings.pinch != .off
        trusted = PinchMonitor.isTrusted
        inDock = Dock.contains(Bundle.main.bundleURL)
        launchAtLogin = LoginItem.isEnabled
    }

    /// Permissions and the Dock can change in System Settings while the guide is open.
    func startPolling() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.trusted = PinchMonitor.isTrusted
                self?.inDock = Dock.contains(Bundle.main.bundleURL)
            }
        }
    }

    func stopPolling() {
        poll?.invalidate()
        poll = nil
    }
}

// MARK: - Views

struct GuideView: View {
    @ObservedObject var state: GuideState
    let close: () -> Void
    let finish: () -> Void
    private typealias M = GuideMetrics
    static let pages = 4

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: M.outerRadius, style: .continuous).fill(M.frameColor)
            GuideBackground()
                .clipShape(RoundedRectangle(cornerRadius: M.innerRadius, style: .continuous))
                .padding(M.frameWidth)

            Group {
                switch state.page {
                case 0: WelcomePage()
                case 1: HabitsPage(state: state)
                case 2: GridPage(state: state)
                default: DonePage()
                }
            }
            .frame(width: M.size.width, height: M.size.height, alignment: .topLeading)
            .transition(.opacity)
            .id(state.page)

            CloseDot(action: close)
                .position(M.close.center)

            Button(state.page == Self.pages - 1 ? L("guide.done.button", "Open LaunchMat") : L("guide.continue", "Continue")) {
                if state.page == Self.pages - 1 {
                    finish()
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) { state.page += 1 }
                }
            }
            .buttonStyle(GuideButtonStyle())
            .keyboardShortcut(.defaultAction)
            // Right edge and bottom at the inset, so a wider button grows to the left.
            .padding([.trailing, .bottom], M.buttonInset)
            .frame(width: M.size.width, height: M.size.height, alignment: .bottomTrailing)
        }
        .frame(width: M.size.width, height: M.size.height)
        .environment(\.colorScheme, .dark)
    }
}

/// Our own backdrop: graphite like the app icon, lit by a soft violet glow at the top left and a deep blue one at the
/// top right, settling to near black at the bottom.
struct GuideBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.086, green: 0.086, blue: 0.094)
            RadialGradient(colors: [Color(red: 0.24, green: 0.17, blue: 0.38).opacity(0.9), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Color(red: 0.08, green: 0.12, blue: 0.24).opacity(0.85), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 320)
            LinearGradient(colors: [.clear, Color(red: 0.07, green: 0.07, blue: 0.075)], startPoint: .center, endPoint: .bottom)
        }
    }
}

private struct CloseDot: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(red: 1, green: 0x54 / 255, blue: 0x4F / 255))
                .overlay(Image(systemName: "xmark").font(.system(size: 7, weight: .black)).foregroundStyle(.black.opacity(0.55))
                    .opacity(hovering ? 1 : 0))
                .frame(width: GuideMetrics.close.diameter, height: GuideMetrics.close.diameter)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(L("guide.close", "Close"))
    }
}

private struct GuideButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(GuideMetrics.buttonText)
            // The spec's size; a longer label (another language, "Open LaunchMat") widens it.
            .padding(.horizontal, 16)
            .frame(minWidth: GuideMetrics.button.width, minHeight: GuideMetrics.button.height, maxHeight: GuideMetrics.button.height)
            .fixedSize()
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(GuideMetrics.buttonBackground.opacity(configuration.isPressed ? 0.7 : 1)))
            .contentShape(Rectangle())
    }
}

private struct SmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(GuideMetrics.buttonText)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(GuideMetrics.smallButton.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}

/// A heading and a two-line subtitle at the guide's text margin, the heading's top at `top`.
private struct Heading: View {
    let title: String
    let subtitle: String
    var titleSize: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(GuideMetrics.title)
            Text(subtitle)
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(GuideMetrics.subtitle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: GuideMetrics.size.width - GuideMetrics.textLeft * 2, alignment: .leading)
    }
}

/// A rounded group of rows, 360 pt wide (rows are 40 pt high; RowDivider between them).
private struct CardGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(width: GuideMetrics.cardWidth)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(GuideMetrics.card))
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 10)
    }
}

private struct CardRow<Trailing: View>: View {
    let title: String
    var height: CGFloat = GuideMetrics.rowHeight
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(GuideMetrics.title)
            Spacer()
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: height)
    }
}

private struct Done: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.green)
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 120, height: 120)
                .position(x: GuideMetrics.size.width / 2, y: 131 + 60)
            Heading(title: L("guide.welcome.title", "Welcome to LaunchMat."),
                    subtitle: L("guide.welcome.body", "Every app you have, on one full-screen grid. Pages, folders and search, the way Launchpad used to work."),
                    titleSize: 25)
                .offset(x: GuideMetrics.textLeft, y: 376)
        }
    }
}

private struct HabitsPage: View {
    @ObservedObject var state: GuideState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading(title: L("guide.habits.title", "Open it the way you’re used to."),
                    subtitle: L("guide.habits.body", "⇧⌘Space works from any app. You can also click the Dock icon, add a hot corner, or pinch with your fingers on the trackpad."))
                .padding(.leading, GuideMetrics.textLeft)
                .padding(.top, 72)
            VStack(spacing: 10) {
                CardGroup {
                    CardRow(title: L("guide.habits.dock", "Keep LaunchMat in the Dock")) {
                        if state.inDock {
                            Done(text: L("guide.habits.inDock", "In the Dock"))
                        } else {
                            Button(L("guide.habits.addToDock", "Add to Dock")) {
                                Dock.add(Bundle.main.bundleURL)
                                state.inDock = Dock.contains(Bundle.main.bundleURL)
                            }
                            .buttonStyle(SmallButtonStyle())
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    CardGroup {
                        CardRow(title: L("guide.habits.hotkey", "Hotkey")) {
                            Picker("", selection: Binding(get: { state.hotkey }, set: { k in
                                state.hotkey = k
                                state.actions.setHotkey(k)
                            })) {
                                ForEach(HotkeyChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .fixedSize()
                        }
                        RowDivider()
                        CardRow(title: L("guide.habits.hotCorner", "Hot corner")) {
                            Picker("", selection: Binding(get: { state.hotCorner }, set: { c in
                                state.hotCorner = c
                                state.actions.setHotCorner(c)
                            })) {
                                ForEach(HotCorner.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .fixedSize()
                        }
                        RowDivider()
                        CardRow(title: L("guide.habits.pinch", "Trackpad pinch")) {
                            if state.pinchOn && state.trusted {
                                Done(text: L("guide.habits.pinchOn", "On"))
                            } else {
                                Button(state.pinchOn ? L("guide.habits.grant", "Grant Access") : L("guide.habits.turnOn", "Turn On")) {
                                    if !state.pinchOn {
                                        state.actions.setPinch(.three)
                                        state.pinchOn = true
                                    } else {
                                        PinchMonitor.requestTrust()
                                    }
                                }
                                .buttonStyle(SmallButtonStyle())
                            }
                        }
                    }
                    Text(L("guide.habits.pinchNote", "The pinch needs Accessibility permission. LaunchMat asks only when you turn it on."))
                        .font(.system(size: 11))
                        .foregroundStyle(GuideMetrics.subtitle)
                        .padding(.leading, 10)
                        .frame(width: GuideMetrics.cardWidth, alignment: .leading)
                }
                if state.legacyFound {
                    CardGroup {
                        CardRow(title: L("guide.habits.legacy", "Your Launchpad layout from before macOS 26 is here.")) {
                            if state.imported {
                                Done(text: L("guide.habits.imported", "Imported"))
                            } else {
                                Button(L("guide.habits.import", "Import Layout")) {
                                    state.imported = state.actions.importLegacyLayout()
                                }
                                .buttonStyle(SmallButtonStyle())
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        }
    }
}

/// Page 3 sets the grid size, the one display choice the app has today.
private struct GridPage: View {
    @ObservedObject var state: GuideState
    private let columns = Array(repeating: GridItem(.fixed(80), spacing: 13), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading(title: L("guide.grid.title", "How many apps on a page?"),
                    subtitle: L("guide.grid.body", "A bigger grid fits more apps on each page. A smaller one gives every icon more room. You can change this later in Settings."))
                .padding(.leading, GuideMetrics.textLeft)
                .padding(.top, 72)
            LazyVGrid(columns: columns, spacing: 13) {
                ForEach(GridSize.presets, id: \.self) { size in
                    Button {
                        state.gridSize = size
                        state.actions.setGridSize(size)
                    } label: {
                        GridChoice(size: size, selected: size == state.gridSize)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: GuideMetrics.cardWidth)
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            CardGroup {
                CardRow(title: L("guide.grid.login", "Launch at login"), height: 38) {
                    Toggle("", isOn: Binding(get: { state.launchAtLogin }, set: { on in
                        state.actions.setLaunchAtLogin(on)
                        state.launchAtLogin = LoginItem.isEnabled
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        }
    }
}

/// A grid size as a small drawing of its columns and rows, with its label.
private struct GridChoice: View {
    let size: GridSize
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 2) {
                ForEach(0..<size.rows, id: \.self) { _ in
                    HStack(spacing: 2) {
                        ForEach(0..<size.cols, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1).fill(.white.opacity(selected ? 0.85 : 0.5)).frame(width: 4, height: 4)
                        }
                    }
                }
            }
            .frame(height: 30)
            Text(size.label).font(.system(size: 12, weight: .medium)).foregroundStyle(GuideMetrics.title)
        }
        .frame(width: 80, height: 58)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(GuideMetrics.card))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

private struct DonePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuideSparkles()
                .frame(width: 96, height: 96)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            Heading(title: L("guide.done.title", "You’re all set."),
                    subtitle: L("guide.done.body", "Press ⇧⌘Space to open LaunchMat. Start typing to search. Press Esc to close."))
                .padding(.leading, GuideMetrics.textLeft)
                .padding(.top, 40)
            Text(L("guide.done.again", "To see this guide again, open Settings › About."))
                .font(.system(size: 12))
                .foregroundStyle(GuideMetrics.subtitle.opacity(0.8))
                .padding(.leading, GuideMetrics.textLeft)
                .padding(.top, 18)
        }
    }
}

/// The done page's picture: the app icon's nine colours scattered around a check mark. Our own drawing.
private struct GuideSparkles: View {
    private let colors: [Color] = [
        Color(red: 0.25, green: 0.56, blue: 0.99), Color(red: 0.43, green: 0.79, blue: 0.44), Color(red: 0.96, green: 0.61, blue: 0.30),
        Color(red: 0.95, green: 0.31, blue: 0.40), Color(red: 0.76, green: 0.28, blue: 0.88), Color(red: 0.36, green: 0.78, blue: 0.83),
        Color(red: 0.95, green: 0.79, blue: 0.26), Color(red: 0.95, green: 0.33, blue: 0.32), Color(red: 0.42, green: 0.38, blue: 0.95),
    ]

    var body: some View {
        ZStack {
            ForEach(0..<9, id: \.self) { i in
                let angle = Double(i) / 9 * 2 * .pi
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(colors[i])
                    .frame(width: 10, height: 10)
                    .rotationEffect(.radians(angle))
                    .offset(x: cos(angle) * 40, y: sin(angle) * 40)
            }
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

// MARK: - Dock

/// Reads and adds to the Dock's list of kept apps (com.apple.dock persistent-apps). Adding happens only when the user
/// clicks "Add to Dock"; the Dock is restarted so it shows the new icon.
enum Dock {
    private static let domain = "com.apple.dock" as CFString
    private static let key = "persistent-apps" as CFString

    private static func items() -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] ?? []
    }

    private static func path(of item: [String: Any]) -> String? {
        let file = (item["tile-data"] as? [String: Any])?["file-data"] as? [String: Any]
        return (file?["_CFURLString"] as? String).flatMap { URL(string: $0)?.standardizedFileURL.path }
    }

    static func contains(_ app: URL) -> Bool {
        let target = app.standardizedFileURL.path
        return items().contains { path(of: $0)?.trimmingSuffix("/") == target.trimmingSuffix("/") }
    }

    static func add(_ app: URL) {
        guard !contains(app) else { return }
        let tile: [String: Any] = [
            "tile-type": "file-tile",
            "tile-data": ["file-data": ["_CFURLString": app.absoluteString, "_CFURLStringType": 15]],
        ]
        CFPreferencesSetAppValue(key, (items() + [tile]) as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        // The Dock reads its list when it starts; launchd starts it again right away.
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.terminate()
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}

// MARK: - Off-screen pictures for review

/// `LaunchMat --snapshot-guide <dir>` renders the four guide pages off-screen to <dir>/guide-<n>.png and exits.
/// Changes no setting.
@MainActor
enum GuideSnapshot {
    private final class NoActions: GuideActions {
        func setHotkey(_ choice: HotkeyChoice) {}
        func setHotCorner(_ corner: HotCorner) {}
        func setPinch(_ fingers: PinchFingers) {}
        func setLaunchAtLogin(_ on: Bool) {}
        func setGridSize(_ size: GridSize) {}
        func importLegacyLayout() -> Bool { false }
    }

    static func run(dir: String) -> Never {
        let state = GuideState(actions: NoActions(), gridSize: GridSize.load())
        for page in 0..<GuideView.pages {
            state.page = page
            let host = NSHostingView(rootView: GuideView(state: state, close: {}, finish: {}))
            host.frame = NSRect(origin: .zero, size: GuideMetrics.size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/guide-\(page + 1).png"))
        }
        exit(0)
    }
}
