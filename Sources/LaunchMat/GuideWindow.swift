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
        state = GuideState(actions: actions)
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
    @Published var importNote: String?
    let actions: GuideActions
    private var poll: Timer?

    init(actions: GuideActions) { self.actions = actions }

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
                case 2: DisplayPage(state: state)
                default: DonePage()
                }
            }
            .frame(width: M.size.width, height: M.size.height, alignment: .topLeading)
            .transition(.opacity)
            .id(state.page)

            CloseDot(action: close)
                .position(M.close.center)

            Button(state.page == Self.pages - 1 ? "Get Started" : "Continue") {
                if state.page == Self.pages - 1 {
                    finish()
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) { state.page += 1 }
                }
            }
            .buttonStyle(GuideButtonStyle())
            .keyboardShortcut(.defaultAction)
            .position(x: M.size.width - M.buttonInset - M.button.width / 2, y: M.size.height - M.buttonInset - M.button.height / 2)
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
        .accessibilityLabel("Close")
    }
}

private struct GuideButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(GuideMetrics.buttonText)
            .frame(width: GuideMetrics.button.width, height: GuideMetrics.button.height)
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
            Heading(title: "Welcome to LaunchMat",
                    subtitle: "Every app on one full-screen grid again, just like the Launchpad you knew.",
                    titleSize: 25)
                .offset(x: GuideMetrics.textLeft, y: 376)
        }
    }
}

private struct HabitsPage: View {
    @ObservedObject var state: GuideState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading(title: "Keep Your Habits",
                    subtitle: "Open LaunchMat the way your hands already know.")
                .padding(.leading, GuideMetrics.textLeft)
                .padding(.top, 72)
            VStack(spacing: 10) {
                CardGroup {
                    CardRow(title: "Keep LaunchMat in the Dock") {
                        if state.inDock {
                            Done(text: "In the Dock")
                        } else {
                            Button("Add to Dock") {
                                Dock.add(Bundle.main.bundleURL)
                                state.inDock = Dock.contains(Bundle.main.bundleURL)
                            }
                            .buttonStyle(SmallButtonStyle())
                        }
                    }
                }
                CardGroup {
                    CardRow(title: "Pinch on the trackpad") {
                        if state.pinchOn && state.trusted {
                            Done(text: "On")
                        } else {
                            Button(state.pinchOn ? "Grant Access" : "Turn On") {
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
                    RowDivider()
                    CardRow(title: "Hot corner") {
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
                }
                CardGroup {
                    CardRow(title: "Hotkey") {
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
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
        }
    }
}

private struct DisplayPage: View {
    @ObservedObject var state: GuideState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading(title: "How It Opens",
                    subtitle: "LaunchMat fills the screen, over your windows, like Launchpad did.")
                .padding(.leading, GuideMetrics.textLeft)
                .padding(.top, 72)
            HStack(spacing: 28) {
                ModeCard(title: "Full Screen", selected: true, window: false)
                ModeCard(title: "Window", selected: false, window: true, note: "Coming soon")
                    .opacity(0.45)
                    .accessibilityLabel("Window, coming soon")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 34)
            Text("The grid takes the whole screen, over a blurred wallpaper.")
                .font(.system(size: 13))
                .foregroundStyle(GuideMetrics.title)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
            CardGroup {
                CardRow(title: "Bring my old Launchpad layout", height: 38) {
                    Toggle("", isOn: Binding(get: { state.imported }, set: { on in
                        guard on, !state.imported else { return }
                        state.imported = state.actions.importLegacyLayout()
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(state.imported)
                }
                RowDivider()
                CardRow(title: "Open at login", height: 38) {
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
            .padding(.top, 28)
        }
    }
}

/// A small drawing of how the grid shows: our own, not a screenshot.
private struct ModeCard: View {
    let title: String
    let selected: Bool
    let window: Bool
    var note: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                LinearGradient(colors: [Color(red: 0.25, green: 0.2, blue: 0.45), Color(red: 0.1, green: 0.14, blue: 0.3)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black.opacity(window ? 0.35 : 0))
                    .frame(width: window ? 70 : 108, height: window ? 46 : 72)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(window ? 6 : 8), spacing: window ? 5 : 7), count: 5),
                          spacing: window ? 5 : 7) {
                    ForEach(0..<(window ? 13 : 15), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.7))
                            .frame(width: window ? 6 : 8, height: window ? 6 : 8)
                    }
                }
            }
            .frame(width: 110, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2).padding(-2))
            Text(note.map { "\(title) · \($0)" } ?? title)
                .font(.system(size: 13))
                .foregroundStyle(GuideMetrics.title)
        }
    }
}

private struct DonePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuideSparkles()
                .frame(width: 96, height: 96)
                .frame(maxWidth: .infinity)
                .padding(.top, 70)
            Heading(title: "You’re All Set",
                    subtitle: "LaunchMat is ready. Two things worth knowing:")
                .padding(.leading, GuideMetrics.textLeft)
                .padding(.top, 30)
            VStack(alignment: .leading, spacing: 14) {
                Tip(symbol: "ellipsis.circle",
                    text: "Click ⋯ next to the search field, or right-click any empty spot, for the main menu.")
                Tip(symbol: "command",
                    text: "Hold ⌘ and click apps to pick several, then drag them together or make a folder.")
            }
            .frame(width: GuideMetrics.cardWidth - 20, alignment: .leading)
            .padding(.leading, GuideMetrics.textLeft)
            .padding(.top, 24)
        }
    }
}

private struct Tip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(GuideMetrics.title)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(GuideMetrics.subtitle)
                .fixedSize(horizontal: false, vertical: true)
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
        func importLegacyLayout() -> Bool { false }
    }

    static func run(dir: String) -> Never {
        let state = GuideState(actions: NoActions())
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
