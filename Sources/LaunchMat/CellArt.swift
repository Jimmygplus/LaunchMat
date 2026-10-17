import AppKit
import LaunchMatCore
import QuartzCore
import SwiftUI

/// The pictures a grid cell is made of, each drawn once into a bitmap (spec 7.1: the names are rasterized layers).
/// A name drawn as live text carries a live shadow, which the window server renders again, off screen, every frame
/// anything near it moves; a bitmap with the shadow in it is only composited. Folder icons, the ✕ badge and the
/// selection check are drawn the same way.
@MainActor
enum CellArt {
    /// Room around a name's text for its shadow (radius 2, 1 pt down).
    static let labelPad: CGFloat = 4
    /// Room around the ✕ badge and the selection check for their shadows (radius 2).
    static let badgePad: CGFloat = 4

    private static var labels: [String: LabelArt] = [:]
    private static var marks: [String: NSImage] = [:]
    private static var folders: [UUID: (key: FolderKey, image: NSImage)] = [:]

    /// A folder preview's inputs; the images are held, so one that's gone can't be mistaken for a new one.
    private struct FolderKey: Equatable {
        let icons: [NSImage?]
        let size: CGFloat
        let scale: CGFloat

        static func == (a: Self, b: Self) -> Bool {
            a.size == b.size && a.scale == b.scale && a.icons.count == b.icons.count
                && zip(a.icons, b.icons).allSatisfy { $0 === $1 }
        }
    }

    /// An app's or a folder's name as the grid shows it: white, Body size, one line ending in "…" past `width`, with
    /// the spec's soft shadow (black 0.26, blur 2, 1 pt down). The bitmap is as wide as the text, `labelPad` larger on
    /// every side.
    static func label(_ text: String, width: CGFloat, scale: CGFloat) -> LabelArt {
        let key = "\(scale)|\(width)|\(text)"
        if let hit = labels[key] { return hit }
        if labels.count > 4000 { labels.removeAll() } // names of old sizes and old names
        let font = NSFont.preferredFont(forTextStyle: .body)
        let natural = (text as NSString).size(withAttributes: [.font: font])
        let image = render(
            Text(text)
                .font(.body)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: width)
                .shadow(color: .black.opacity(0.26), radius: 2, y: 1)
                .padding(labelPad),
            scale: scale)
        let art = LabelArt(image: image, textWidth: min(natural.width, width), textHeight: image.size.height - labelPad * 2)
        labels[key] = art
        return art
    }

    /// The uninstall badge for an icon of `size`, `badgePad` larger on every side for its shadow.
    static func badge(size: CGFloat, scale: CGFloat) -> NSImage {
        mark("badge|\(scale)|\(size)", scale: scale) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: size * 0.24, weight: .bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color(white: 0.25).opacity(0.9))
                .shadow(radius: 2)
                .padding(badgePad)
        }
    }

    /// The check on a ⌘-selected icon of `size`, `badgePad` larger on every side.
    static func check(size: CGFloat, scale: CGFloat) -> NSImage {
        mark("check|\(scale)|\(size)", scale: scale) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size * 0.24, weight: .bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .shadow(radius: 2)
                .padding(badgePad)
        }
    }

    /// A folder's icon (FolderPreview), redrawn only when its apps' icons or its size change.
    static func folder(_ id: UUID, icons: [NSImage?], size: CGFloat, scale: CGFloat) -> NSImage {
        let key = FolderKey(icons: icons, size: size, scale: scale)
        if let hit = folders[id], hit.key == key { return hit.image }
        let image = render(FolderPreview(icons: icons, size: size).environment(\.displayScale, scale), scale: scale)
        folders[id] = (key, image)
        return image
    }

    private static func mark<V: View>(_ key: String, scale: CGFloat, _ view: () -> V) -> NSImage {
        if let hit = marks[key] { return hit }
        let image = render(view(), scale: scale)
        marks[key] = image
        return image
    }

    private static func render<V: View>(_ view: V, scale: CGFloat) -> NSImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return NSImage() }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }
}

/// A name's bitmap, with the width of its text in it (at most the width it was given), to place the text where
/// SwiftUI placed it.
final class LabelArt {
    let image: NSImage
    let textWidth: CGFloat
    let textHeight: CGFloat

    init(image: NSImage, textWidth: CGFloat, textHeight: CGFloat) {
        self.image = image
        self.textWidth = textWidth
        self.textHeight = textHeight
    }
}

/// Everything a grid cell shows, worked out by PagerView. Pictures compare by identity (they come from caches).
struct CellLook: Equatable {
    var icon: NSImage?
    var label: LabelArt
    /// The ✕ badge if the app can be moved to the Trash.
    var badge: NSImage?
    /// The check, when ⌘-selected.
    var check: NSImage?
    /// Being dragged, or just dropped into a folder while its cell goes (it would show for a moment).
    var hidden: Bool
    /// Not installed any more.
    var dimmed: Bool
    var merging: Bool

    var picked: Bool { check != nil }

    static func == (a: Self, b: Self) -> Bool {
        a.icon === b.icon && a.label === b.label && a.badge === b.badge && a.check === b.check && a.hidden == b.hidden
            && a.dimmed == b.dimmed && a.merging == b.merging
    }
}

/// One cell of the grid as GridLayers draws it.
struct GridCell: Equatable {
    let id: String
    let entry: Entry
    let page: Int
    let slot: Int
    let look: CellLook
}

/// The grid's icons and names as Core Animation layers in one view (spec 7.1, 13.2–13.4):
/// - turning a page, or the grid shrinking behind an open folder, moves this one view;
/// - icons making room move their layers, over 0.36 s easing in and out, on the render server;
/// - wiggle mode rocks and bobs each icon with its own layer animation (spec 13.3), the ✕ badges and the merge plate
///   pop (spec 13.2), and a pressed icon is shaded (spec 13.4);
/// - a new picture under an animated change (an app becoming the folder it was dropped on, C8) fades over the old one.
/// None of it re-evaluates SwiftUI or needs the main thread per frame. GridInput, over it, takes the clicks and drags.
struct GridLayers: NSViewRepresentable {
    let model: LaunchpadModel
    let items: [GridCell]
    let metrics: GridMetrics
    /// The keyboard selection's cell, if it is on the showing page.
    let selected: Int?
    let page: Int
    let wiggling: Bool

    func makeNSView(context: Context) -> GridLayerView {
        let view = GridLayerView()
        model.gridLayers = view
        return view
    }

    func updateNSView(_ view: GridLayerView, context: Context) {
        model.gridLayers = view
        let animated = context.transaction.animation != nil && !context.transaction.disablesAnimations
        view.apply(items, metrics: metrics, selected: selected.map { (page, $0) }, wiggling: wiggling, animated: animated)
    }
}

/// Watches the keyboard selection, the showing page and wiggle mode for GridLayers, so that they don't re-evaluate the
/// grid.
struct GridLayersHost: View {
    let model: LaunchpadModel
    let items: [GridCell]
    let metrics: GridMetrics
    @ObservedObject var selection: SelectionState
    @ObservedObject var pager: PagerState
    @ObservedObject var wiggle: WiggleState

    var body: some View {
        GridLayers(model: model, items: items, metrics: metrics, selected: selection.index, page: pager.page, wiggling: wiggle.on)
    }
}

final class GridLayerView: NSView {
    private var cells: [String: CellLayers] = [:]
    private var leaving: [String: CellLayers] = [:]
    private var metrics: GridMetrics?
    private var selected: (page: Int, slot: Int)?
    private var pressed: String?
    static let reflow: Double = 0.36

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for c in cells.values { c.setScale(s) }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // A new size: every cell placed again, at once (y runs up here, down in the grid's metrics).
        guard let metrics else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for c in cells.values { c.place(metrics: metrics, height: bounds.height, scale: scale, animated: false) }
        CATransaction.commit()
    }

    /// For the self-test: the cells drawn, the one shaded as pressed, how many rock and bob, and how many show their
    /// ✕ badge.
    var cellCount: Int { cells.count }
    var pressedCell: String? { pressed }
    var wigglingCount: Int { cells.values.filter(\.isWiggling).count }
    var restingCount: Int { cells.values.filter(\.isAtRest).count }
    var badgeCount: Int { cells.values.filter(\.showsBadge).count }

    /// The pressed cell is shaded (spec 13.4) until it is released.
    func press(_ id: String, _ on: Bool) {
        if on { pressed = id } else if pressed == id { pressed = nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cells[id]?.setPressed(on)
        CATransaction.commit()
    }

    func apply(_ items: [GridCell], metrics: GridMetrics, selected: (page: Int, slot: Int)?, wiggling: Bool, animated: Bool) {
        let resized = metrics != self.metrics
        self.metrics = metrics
        let height = bounds.height > 0 ? bounds.height : metrics.size.height
        let s = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<String>()
        for item in items {
            seen.insert(item.id)
            if let cell = cells[item.id] {
                guard resized || cell.item != item else { continue }
                cell.update(item, metrics: metrics, height: height, scale: s, animated: animated && !resized)
            } else if let cell = leaving.removeValue(forKey: item.id) {
                // Back before it had gone (a folder dissolving into its last app, say).
                cells[item.id] = cell
                cell.update(item, metrics: metrics, height: height, scale: s, animated: animated)
                cell.fade(to: cell.restingOpacity, animated: animated)
            } else {
                let cell = CellLayers(item: item)
                cells[item.id] = cell
                layer?.addSublayer(cell.root)
                cell.setScale(s)
                cell.update(item, metrics: metrics, height: height, scale: s, animated: false, initial: true)
                if animated {
                    // Comes in as a SwiftUI view would: fading in.
                    cell.root.opacity = 0
                    cell.fade(to: cell.restingOpacity, animated: true)
                }
                if pressed == item.id { cell.setPressed(true) }
            }
        }
        for (id, cell) in cells where !seen.contains(id) {
            cells[id] = nil
            if animated {
                leaving[id] = cell
                cell.fade(to: 0, animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.reflow + 0.05) { [weak self] in
                    guard let self, let gone = self.leaving[id], gone === cell else { return }
                    self.leaving[id] = nil
                    gone.root.removeFromSuperlayer()
                }
            } else {
                cell.root.removeFromSuperlayer()
            }
        }
        for c in cells.values { c.setWiggling(wiggling) }
        if resized || selected?.page != self.selected?.page || selected?.slot != self.selected?.slot {
            self.selected = selected
            for c in cells.values { c.setHighlighted(selected.map { c.item.page == $0.page && c.item.slot == $0.slot } ?? false) }
        }
        CATransaction.commit()
    }
}

/// One cell's layers. `root` sits on the cell's centre; inside it, y runs up.
@MainActor
final class CellLayers {
    let root = CALayer()
    private let highlight = CAShapeLayer()
    private let bob = CALayer()
    private let rock = CALayer()
    private let mergePlate = CAShapeLayer()
    private let plate = CAShapeLayer()
    private let picture = CALayer()
    private let shade = CALayer()
    private let shadeMask = CALayer()
    private let check = CALayer()
    private let badge = CALayer()
    private let label = CALayer()
    private(set) var item: GridCell
    private let wiggle: WiggleMotion
    private var wiggling = false
    private var badgeShown = false
    private var merging = false
    private var size: CGFloat = 0

    init(item: GridCell) {
        self.item = item
        wiggle = WiggleMotion(seed: item.entry.key.hashValue)
        root.addSublayer(highlight)
        root.addSublayer(bob)
        root.addSublayer(label)
        bob.addSublayer(rock)
        for l in [mergePlate, plate, picture, shade, check, badge] { rock.addSublayer(l) }
        for l in [picture, shadeMask, check, badge, label] {
            l.contentsGravity = .resize
            l.minificationFilter = .trilinear
        }
        highlight.fillColor = NSColor.white.withAlphaComponent(0.2).cgColor
        highlight.opacity = 0
        mergePlate.fillColor = NSColor.white.withAlphaComponent(0.3).cgColor
        mergePlate.opacity = 0
        mergePlate.transform = CATransform3DMakeScale(0.72, 0.72, 1)
        plate.fillColor = NSColor.white.withAlphaComponent(0.22).cgColor
        shade.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        shade.mask = shadeMask
        shade.isHidden = true
        badge.opacity = 0
        badge.transform = CATransform3DMakeScale(0.72, 0.72, 1)
    }

    var restingOpacity: Float { item.look.hidden ? 0 : (item.look.dimmed ? 0.4 : 1) }

    func setScale(_ s: CGFloat) {
        for l in [root, highlight, bob, rock, mergePlate, plate, picture, shade, shadeMask, check, badge, label] { l.contentsScale = s }
    }

    func update(_ new: GridCell, metrics m: GridMetrics, height: CGFloat, scale: CGFloat, animated: Bool, initial: Bool = false) {
        FrameLog.shared.countCell()
        let old = item
        item = new
        let look = new.look
        if initial || look.icon !== old.look.icon {
            let image = look.icon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            if animated, picture.contents != nil, image != nil {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = GridLayerView.reflow
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                picture.add(fade, forKey: "contents")
            }
            picture.contents = image
            shadeMask.contents = image
        }
        if initial || look.label !== old.look.label { label.contents = look.label.image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        if initial || look.badge !== old.look.badge { badge.contents = look.badge?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        if initial || look.check !== old.look.check {
            check.contents = look.check?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            check.isHidden = look.check == nil
            plate.isHidden = look.check == nil
        }
        place(metrics: m, height: height, scale: scale, animated: animated && !initial)
        if !initial, look.hidden != old.look.hidden || look.dimmed != old.look.dimmed {
            fade(to: restingOpacity, animated: animated)
        } else if initial {
            root.opacity = restingOpacity
        }
        if look.merging != merging {
            merging = look.merging
            pop(mergePlate, shown: merging)
        }
        setWiggling(wiggling)
    }

    /// Wiggle mode: the icon rocks and bobs, and the ✕ badge, if it has one, pops in.
    func setWiggling(_ on: Bool) {
        if on != wiggling {
            wiggling = on
            on ? startWiggle() : stopWiggle()
        }
        let showBadge = on && item.look.badge != nil
        if showBadge != badgeShown {
            badgeShown = showBadge
            pop(badge, shown: showBadge)
        }
    }

    /// Lays the cell out as the SwiftUI cell did, rounding to pixels where SwiftUI did: a column of the icon, 6 pt,
    /// then the name (as wide as 94% of the cell), centred on the cell, with the selection highlight 6 pt beyond it
    /// above and below. Moves it there over 0.36 s when animated, adding to any move still running (as SwiftUI does),
    /// so a cell that is pushed again carries on smoothly.
    func place(metrics m: GridMetrics, height: CGFloat, scale: CGFloat, animated: Bool) {
        func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let s = m.iconSize
        size = s
        let name = item.look.label
        let labelWidth = m.cell.width * 0.94
        let labelHeight = name.textHeight
        let column = s + m.labelSpacing + labelHeight
        let c = m.cellCenter(item.slot)
        let center = CGPoint(x: c.x + CGFloat(item.page) * m.size.width, y: c.y)
        // In the grid's space (y down), as SwiftUI placed them.
        let width = max(labelWidth, s)
        let padded = CGRect(x: px(center.x - width / 2), y: px(center.y - (column + 12) / 2), width: width, height: column + 12)
        let stack = CGPoint(x: padded.minX, y: padded.minY + 6)
        let iconRect = CGRect(x: px(center.x - s / 2), y: stack.y, width: s, height: s)
        // The text centred under the icon as SwiftUI put it: its width rounded up to whole pixels, its origin on one.
        let labelRect = CGRect(x: px(center.x - (name.textWidth * scale).rounded(.up) / scale / 2) - CellArt.labelPad,
                               y: stack.y + s + m.labelSpacing - CellArt.labelPad,
                               width: name.image.size.width, height: name.image.size.height)
        let hlRect = CGRect(x: padded.minX + px((width - s * 1.45) / 2), y: padded.minY, width: s * 1.45, height: padded.height)

        // The root covers the padded column; inside it y runs up from its bottom.
        let box = padded.union(hlRect)
        func local(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX - box.minX, y: box.maxY - r.maxY, width: r.width, height: r.height)
        }
        root.anchorPoint = .zero
        root.bounds = CGRect(origin: .zero, size: box.size)
        highlight.frame = local(hlRect)
        highlight.path = Self.rounded(CGRect(origin: .zero, size: hlRect.size), radius: 16)
        bob.frame = local(iconRect)
        rock.frame = bob.bounds
        let icon = CGRect(origin: .zero, size: iconRect.size)
        picture.frame = icon
        shade.frame = icon
        shadeMask.frame = shade.bounds
        let plateRect = icon.insetBy(dx: -s * 0.09, dy: -s * 0.09)
        for p in [mergePlate, plate] {
            p.frame = plateRect
            p.path = Self.rounded(CGRect(origin: .zero, size: plateRect.size), radius: s * 0.28)
        }
        // The badge over the icon's top-left corner and the check over its top-right, 2% and 4% of the icon out.
        if let b = item.look.badge?.size {
            badge.frame = CGRect(x: -s * 0.02 - CellArt.badgePad, y: s + s * 0.02 + CellArt.badgePad - b.height, width: b.width, height: b.height)
        }
        if let k = item.look.check?.size {
            check.frame = CGRect(x: s + s * 0.04 + CellArt.badgePad - k.width, y: s + s * 0.04 + CellArt.badgePad - k.height,
                                 width: k.width, height: k.height)
        }
        // The picture's content starts at its top-left; any extra pixel of its rounded-up size falls right and below.
        let l = local(labelRect)
        label.frame = CGRect(x: l.minX, y: l.minY, width: l.width, height: l.height)

        let target = CGPoint(x: box.minX, y: height - box.maxY)
        let from = root.position
        root.position = target
        if animated, from != target {
            let move = CABasicAnimation(keyPath: "position")
            move.isAdditive = true
            move.fromValue = NSValue(point: CGPoint(x: from.x - target.x, y: from.y - target.y))
            move.toValue = NSValue(point: .zero)
            move.duration = GridLayerView.reflow
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            root.add(move, forKey: nil)
        }
    }

    func fade(to opacity: Float, animated: Bool) {
        let from = (root.presentation() ?? root).opacity
        root.opacity = opacity
        guard animated, from != opacity else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = opacity
        a.duration = GridLayerView.reflow
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        root.add(a, forKey: "fade")
    }

    func setPressed(_ on: Bool) { shade.isHidden = !on }

    var isWiggling: Bool { rock.animation(forKey: "wiggle") != nil && bob.animation(forKey: "wiggle") != nil }
    /// No animation of any kind on the rocking and bobbing layers, and both back at 0° and 0 pt.
    var isAtRest: Bool {
        (rock.animationKeys() ?? []).isEmpty && (bob.animationKeys() ?? []).isEmpty
            && CATransform3DIsIdentity(rock.transform) && CATransform3DIsIdentity(bob.transform)
    }
    var showsBadge: Bool { badge.opacity == 1 && badge.contents != nil }

    func setHighlighted(_ on: Bool) { highlight.opacity = on ? 1 : 0 }

    private static func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
        RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
    }

    // MARK: - Wiggle (spec 13.3)

    private func startWiggle() {
        let begin = CACurrentMediaTime() + wiggle.delay
        let rocking = CABasicAnimation(keyPath: "transform.rotation.z")
        rocking.fromValue = -wiggle.angle
        rocking.toValue = wiggle.angle
        rocking.duration = wiggle.swing
        rocking.beginTime = rock.convertTime(begin, from: nil)
        let bobbing = CABasicAnimation(keyPath: "transform.translation.y")
        bobbing.fromValue = 0
        bobbing.toValue = wiggle.lift // y up: lifts the icon
        bobbing.duration = wiggle.bounce
        bobbing.beginTime = bob.convertTime(begin, from: nil)
        for (layer, a) in [(rock, rocking), (bob, bobbing)] {
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.fillMode = .backwards
            layer.removeAnimation(forKey: "settle")
            layer.add(a, forKey: "wiggle")
        }
    }

    /// Back to rest from wherever the wiggle is, quickly.
    private func stopWiggle() {
        for (layer, key) in [(rock, "transform.rotation.z"), (bob, "transform.translation.y")] {
            let now = layer.presentation()?.value(forKeyPath: key) as? Double ?? 0
            layer.removeAnimation(forKey: "wiggle")
            let back = CABasicAnimation(keyPath: key)
            back.fromValue = now
            back.toValue = 0
            back.duration = 0.12
            back.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(back, forKey: "settle")
        }
    }

    // MARK: - Pop (spec 13.2)

    /// In: scale 0.72 → 1 on a spring (mass 1, stiffness 520, damping 32), opacity over 0.16 s ease-out. Out: back to
    /// 0.72 (stiffness 420, damping 36), opacity over 0.12 s ease-in. From wherever it is, if interrupted.
    private func pop(_ layer: CALayer, shown: Bool) {
        let now = layer.presentation() ?? layer
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.mass = 1
        scale.stiffness = shown ? 520 : 420
        scale.damping = shown ? 32 : 36
        scale.fromValue = now.value(forKeyPath: "transform.scale.x") as? Double ?? (shown ? 0.72 : 1)
        scale.toValue = shown ? 1 : 0.72
        scale.duration = scale.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = now.opacity
        fade.toValue = shown ? 1 : 0
        fade.duration = shown ? 0.16 : 0.12
        fade.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
        layer.transform = shown ? CATransform3DIdentity : CATransform3DMakeScale(0.72, 0.72, 1)
        layer.opacity = shown ? 1 : 0
        layer.add(scale, forKey: "pop.scale")
        layer.add(fade, forKey: "pop.opacity")
    }
}

/// One icon's wiggle (spec 13.3): it rocks between ±θ about its centre, θ at random 1.38°–1.72°, each way in
/// 0.105–0.125 s, and bobs 0.8–1.4 pt, each way in 0.12–0.145 s, starting 0–0.03 s late; all easing in and out. The
/// values are drawn per icon from `seed`, so no two move together.
struct WiggleMotion {
    /// In radians.
    let angle: Double
    let swing: Double
    let lift: Double
    let bounce: Double
    let delay: Double

    init(seed: Int) {
        var random = SplitMix(seed)
        angle = random.next(in: 1.38...1.72) * .pi / 180
        swing = random.next(in: 0.105...0.125)
        lift = random.next(in: 0.8...1.4)
        bounce = random.next(in: 0.12...0.145)
        delay = random.next(in: 0...0.03)
    }

    /// The rotation at time `t` (seconds), easing between −angle and +angle, one way per `swing`.
    func angle(at t: Double) -> Double { -angle * cos(.pi * (t - delay) / swing) }

    /// The lift at time `t`, easing between 0 and `lift`, one way per `bounce`.
    func lift(at t: Double) -> Double { lift * (1 - cos(.pi * (t - delay) / bounce)) / 2 }
}
