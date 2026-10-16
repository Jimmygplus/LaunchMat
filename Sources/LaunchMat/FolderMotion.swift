import SwiftUI

/// How an opened folder moves and how a folder icon is drawn, from rea's measurements of LaunchOS (spec C7–C9,
/// "C7–C9 详解"). One place to change them.
enum FolderMotion {
    /// Opening and closing are the same animation in reverse: 0.28 s ease-in-ease-out, everything starting together
    /// (panel shape and corners, content, title, the grid behind). No springs. [measured]
    static let open = Animation.easeInOut(duration: 0.28)
    static let close = Animation.easeInOut(duration: 0.28)
    /// The grid behind an open folder shrinks to 94% and all but vanishes (opacity 0.001). [measured]
    static let baseScale: CGFloat = 0.94
    static let baseOpacity = 0.001
    /// A darkening over the wallpaper while a folder is open. [not measured yet (rea, from Jimmy's recording): kept as
    /// it was until then]
    static let backdropDim = 0.25

    /// The open panel's corner radius: max(16, 0.24 × its shorter side). [measured; LaunchOS uses a fixed 30 under
    /// a setting not identified yet]
    static func panelRadius(_ panel: CGSize) -> CGFloat { max(16, 0.24 * min(panel.width, panel.height)) }

    // The folder icon's preview (C7). [measured]
    /// The plate: 81% of the icon's shorter side, centred; corners max(4, 0.26 × side), rounded to whole points.
    static let previewPlate: CGFloat = 0.81
    static func previewRadius(_ side: CGFloat) -> CGFloat { max(4, (side * 0.26).rounded()) }
    /// Three columns, at most nine icons: cells 0.24 × side, 0.024 × side apart, 0.116 × side from the edges.
    static let previewCell: CGFloat = 0.24
    static let previewGap: CGFloat = 0.024
    static let previewMargin: CGFloat = 0.116

    /// The panel's content starts at the size of the icon's preview cells and grows to full size with the panel
    /// (the proxy icons fly from the preview cells to the panel; their opacity curve is not measured yet).
    static func contentScale(gridIcon: CGFloat, panelIcon: CGFloat) -> CGFloat {
        guard panelIcon > 0 else { return 0.2 }
        return (gridIcon * previewPlate).rounded() * previewCell / panelIcon
    }
}

/// An opened folder's state, watched only by the folder overlay and the grid's backdrop, so opening and closing
/// don't redraw every icon.
@MainActor
final class FolderPresentation: ObservableObject {
    /// True while the panel is (or is growing to be) open; false while it is at, or shrinking into, its icon.
    @Published var expanded = false
}
