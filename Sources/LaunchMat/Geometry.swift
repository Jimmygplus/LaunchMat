import CoreGraphics
import Foundation

struct GridSize: Hashable {
    var cols: Int
    var rows: Int

    var label: String { "\(cols) × \(rows)" }

    /// 7–10 columns × 5–6 rows.
    static let presets = [5, 6].flatMap { r in (7...10).map { GridSize(cols: $0, rows: r) } }

    static func load() -> GridSize {
        let d = UserDefaults.standard
        let c = d.integer(forKey: "gridCols"), r = d.integer(forKey: "gridRows")
        return (3...12).contains(c) && (2...8).contains(r) ? GridSize(cols: c, rows: r) : GridSize(cols: 7, rows: 5)
    }

    func save() {
        UserDefaults.standard.set(cols, forKey: "gridCols")
        UserDefaults.standard.set(rows, forKey: "gridRows")
    }
}

/// Pure screen geometry for the main grid. Everything is in the window's top-left coordinate space.
struct GridMetrics: Equatable {
    var size: CGSize
    var cols: Int
    var rows: Int

    var topInset: CGFloat { max(96, size.height * 0.12) }
    var bottomInset: CGFloat { max(70, size.height * 0.095) }
    var sideInset: CGFloat { max(40, size.width * 0.085) }

    var gridRect: CGRect {
        CGRect(x: sideInset, y: topInset,
               width: max(1, size.width - sideInset * 2),
               height: max(1, size.height - topInset - bottomInset))
    }

    var cell: CGSize { CGSize(width: gridRect.width / CGFloat(cols), height: gridRect.height / CGFloat(rows)) }
    var iconSize: CGFloat { floor(min(cell.width * 0.6, cell.height * 0.64, 132)) }
    var labelFont: CGFloat { max(11, min(14, iconSize * 0.12)) }
    var labelSpacing: CGFloat { 6 }
    /// Height of icon + gap + one text line; the cell's content is centered on the cell.
    var contentHeight: CGFloat { iconSize + labelSpacing + labelFont * 1.3 }

    func cellCenter(_ slot: Int) -> CGPoint {
        let c = slot % cols, r = slot / cols
        return CGPoint(x: gridRect.minX + (CGFloat(c) + 0.5) * cell.width,
                       y: gridRect.minY + (CGFloat(r) + 0.5) * cell.height)
    }

    func iconCenter(_ slot: Int) -> CGPoint {
        var p = cellCenter(slot)
        p.y -= (contentHeight - iconSize) / 2
        return p
    }

    /// Slot under a point on the visible page, nil when well outside the grid.
    func slot(at p: CGPoint) -> Int? {
        guard gridRect.insetBy(dx: -cell.width * 0.2, dy: -cell.height * 0.2).contains(p) else { return nil }
        let c = min(cols - 1, max(0, Int((p.x - gridRect.minX) / cell.width)))
        let r = min(rows - 1, max(0, Int((p.y - gridRect.minY) / cell.height)))
        return r * cols + c
    }
}

/// Geometry of an opened folder panel.
struct FolderPanel {
    var frame: CGRect
    var cols: Int
    var cell: CGSize
    var iconSize: CGFloat
    var header: CGFloat
    var pad: CGFloat

    func center(_ i: Int) -> CGPoint {
        let c = i % cols, r = i / cols
        return CGPoint(x: frame.minX + pad + (CGFloat(c) + 0.5) * cell.width,
                       y: frame.minY + header + (CGFloat(r) + 0.5) * cell.height)
    }

    func slot(at p: CGPoint) -> Int? {
        guard frame.contains(p) else { return nil }
        let c = min(cols - 1, max(0, Int((p.x - frame.minX - pad) / cell.width)))
        let r = max(0, Int((p.y - frame.minY - header) / cell.height))
        return r * cols + c
    }
}
