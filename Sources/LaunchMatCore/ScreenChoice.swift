import CoreGraphics

/// Which screen the grid opens on (Settings › General › Show on). Worked out on every open; the last screen used is
/// not remembered, so a screen that is gone simply falls through to the next choice.
public enum ShowOn: String, CaseIterable, Sendable {
    /// The primary screen, the one with the menu bar (`NSScreen.screens[0]`).
    case main
    /// The screen of the active window (`NSScreen.main`).
    case active
    /// The screen with the pointer.
    case cursor
    /// The screen the Dock is on.
    case dock
}

/// A screen's frame and visible frame, in AppKit screen coordinates (origin bottom left of the primary screen).
public struct ScreenGeometry: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public init(frame: CGRect, visibleFrame: CGRect) { self.frame = frame; self.visibleFrame = visibleFrame }
}

/// The edge of its screen the Dock sits on (`com.apple.dock` › orientation).
public enum DockEdge: String, Sendable { case bottom, left, right }

public enum ScreenChoice {
    /// The index of the screen to open on, or nil when there is none. `screens[0]` is the primary screen; `active` is
    /// the index of the active window's screen, if known. Whatever can't be found falls back to the active screen,
    /// then to the primary one.
    public static func pick(_ showOn: ShowOn, screens: [ScreenGeometry], active: Int?, cursor: CGPoint, dock: DockEdge) -> Int? {
        guard !screens.isEmpty else { return nil }
        let fallback = active.flatMap { screens.indices.contains($0) ? $0 : nil } ?? 0
        switch showOn {
        case .main: return 0
        case .active: return fallback
        case .cursor: return screens.firstIndex { contains($0.frame, cursor) } ?? fallback
        case .dock: return dockScreen(screens, edge: dock) ?? fallback
        }
    }

    /// The screen whose visible frame gives way to the Dock on its edge. Public API only: macOS takes the Dock's
    /// space out of that one screen's visible frame (a few points when the Dock hides itself). The menu bar's strip at
    /// the top is on every screen and is not counted.
    public static func dockScreen(_ screens: [ScreenGeometry], edge: DockEdge) -> Int? {
        let insets = screens.map { s -> CGFloat in
            switch edge {
            case .bottom: return s.visibleFrame.minY - s.frame.minY
            case .left: return s.visibleFrame.minX - s.frame.minX
            case .right: return s.frame.maxX - s.visibleFrame.maxX
            }
        }
        guard let best = insets.indices.max(by: { insets[$0] < insets[$1] }), insets[best] > 0 else { return nil }
        return best
    }

    /// The pointer on a screen's edge counts as on it (like NSMouseInRect for the top and right edges).
    static func contains(_ frame: CGRect, _ p: CGPoint) -> Bool {
        p.x >= frame.minX && p.x <= frame.maxX && p.y >= frame.minY && p.y <= frame.maxY
    }
}
