import SwiftUI

/// How an opened folder moves (spec C8, C9). **The values are placeholders until rea's measured ones arrive; change
/// them here and nowhere else.** The structure is final: the panel grows out of the folder's icon and shrinks back
/// into it, the grid behind blurs and dims, and the overlay leaves only when the panel is back in the icon.
enum FolderMotion {
    /// The panel growing out of the folder's icon. [placeholder, waiting for rea]
    static let open = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// The panel shrinking back into the icon. [placeholder, waiting for rea]
    static let close = Animation.spring(response: 0.30, dampingFraction: 0.90)
    /// How much the grid behind an open folder is blurred (pt) and darkened. [placeholders, waiting for rea]
    static let backdropBlur: CGFloat = 22
    static let backdropDim = 0.25
    /// The panel's content starts this small, around the icon, and grows with the panel. [placeholder]
    static let contentScale: CGFloat = 0.3
    /// Corner radius of the open panel, and of the icon it comes from (as a share of the icon's size).
    static let panelRadius: CGFloat = 30
    static let iconRadius: CGFloat = 0.225
}

/// An opened folder's state, watched only by the folder overlay and the grid's backdrop, so opening and closing
/// don't redraw every icon.
@MainActor
final class FolderPresentation: ObservableObject {
    /// True while the panel is (or is growing to be) open; false while it is at, or shrinking into, its icon.
    @Published var expanded = false
}
