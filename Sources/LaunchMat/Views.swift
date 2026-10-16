import AppKit
import SwiftUI
import LaunchMatCore

struct RootView: View {
    @ObservedObject var model: LaunchpadModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let m = GridMetrics(size: geo.size, cols: model.gridSize.cols, rows: model.gridSize.rows)
            ZStack(alignment: .topLeading) {
                // Everything not covered by an icon, the search field or the page dots is blank: empty slots, the
                // gaps between icons and the margins. One gesture reads a press there: dragging 4 pt sideways turns
                // pages (following the pointer like a swipe), a press that doesn't move closes the grid.
                BackgroundView(image: model.wallpaper)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { model.blankDragChanged($0.translation) }
                            .onEnded { model.blankDragEnded($0.translation) }
                    )

                ZStack(alignment: .topLeading) {
                    HStack(spacing: 8) {
                        SearchField(text: $model.query, focused: $searchFocused)
                            .frame(width: min(280, geo.size.width * 0.3))
                        // The main menu, the same as a right-click on blank space.
                        Button { model.showMainMenu?() } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 0.5))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.8))
                        .help(L("grid.menu", "Menu"))
                        .accessibilityLabel(L("grid.menu", "Menu"))
                    }
                    .padding(.leading, 38) // keeps the search field itself centred
                    .position(x: geo.size.width / 2, y: m.topInset * 0.5)

                    PagerSlide(pager: model.pager, width: geo.size.width) { PagerView(model: model, metrics: m) }

                    if model.isSearching && model.results.isEmpty {
                        Text(L("search.noResults", "No Results"))
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }

                    PageDots(pager: model.pager, count: model.pageCount) { model.go(to: $0) }
                        .position(x: geo.size.width / 2, y: geo.size.height - m.bottomInset * 0.5)
                }

                if let id = model.openFolder {
                    FolderOverlay(model: model, folderID: id)
                        .transition(.opacity)
                }

                if let card = model.whatsNew {
                    Color.black.opacity(0.35)
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .transition(.opacity)
                    WhatsNewCard(card: card, releaseNotes: {
                        model.dismissWhatsNew()
                        model.openReleaseNotes?()
                    }, dismiss: { model.dismissWhatsNew() })
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }

                if let d = model.drag, d.sourceFolder == nil || d.extracted {
                    EntryIcon(model: model, entry: d.entry, size: m.iconSize)
                        .overlay(alignment: .topTrailing) {
                            if !d.companions.isEmpty { CountBadge(count: d.companions.count + 1, size: m.iconSize) }
                        }
                        .scaleEffect(1.1)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                        .position(x: d.location.x - d.grab.width, y: d.location.y - d.grab.height)
                        .allowsHitTesting(false)
                } else if let d = model.drag, let id = d.sourceFolder {
                    EntryIcon(model: model, entry: d.entry, size: model.folderPanel(for: id).iconSize)
                        .scaleEffect(1.1)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                        .position(x: d.location.x - d.grab.width, y: d.location.y - d.grab.height)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "root")
            .alert(L("rename.alertTitle", "Rename"), isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
                RenameFields(model: model)
            } message: {
                Text(L("rename.alertBody", "Shown in the grid and found by search. Leave it empty for the app’s own name."))
            }
            .onAppear {
                model.metrics = m
                searchFocused = true
            }
            .onChange(of: m) { _, new in model.metrics = new }
            .modifier(FocusOnSignal(signal: model.focus, focused: $searchFocused))
        }
        .ignoresSafeArea()
    }
}

/// Puts the cursor in the search field when the signal fires. Only this modifier watches the signal.
struct FocusOnSignal: ViewModifier {
    @ObservedObject var signal: FocusSignal
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.onChange(of: signal.token) { _, _ in focused.wrappedValue = true }
    }
}

struct BackgroundView: View {
    let image: NSImage?

    var body: some View {
        // No live blur of the windows behind: a dark backdrop until the prepared wallpaper is there, then the
        // wallpaper fades in over it.
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
                    .id(ObjectIdentifier(image))
            }
            Color.black.opacity(0.2)
        }
    }
}

/// A system material, always in its dark form: the grid is white text on a picture, like Launchpad, whatever the
/// system's appearance. (In the light form the open folder turned the whole screen and its panel light grey.)
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.appearance = NSAppearance(named: .darkAqua)
        v.state = .active
        v.material = material
        v.blendingMode = blending
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.75))
            TextField("", text: $text, prompt: Text(L("search.prompt", "Search")).foregroundStyle(.white.opacity(0.6)))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .focused(focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay(Capsule().stroke(.white.opacity(0.28), lineWidth: 0.5))
    }
}

struct PageDots: View {
    @ObservedObject var pager: PagerState
    let count: Int
    let onSelect: (Int) -> Void

    var body: some View {
        let current = pager.page
        if count > 1 {
            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .fill(.white.opacity(i == current ? 0.95 : 0.35))
                        .frame(width: 8, height: 8)
                        .padding(5)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(i) }
                }
            }
        }
    }
}

/// All pages live in one positioned layer so an icon keeps its identity (and its drag gesture)
/// when it moves to another page.
struct PagerView: View {
    @ObservedObject var model: LaunchpadModel
    let metrics: GridMetrics

    var body: some View {
        let w = metrics.size.width
        ZStack(alignment: .topLeading) {
            if model.isSearching {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { i, app in
                    let page = i / model.capacity, slot = i % model.capacity
                    let p = metrics.cellCenter(slot)
                    EntryCell(model: model, entry: .app(app.id), metrics: metrics, center: p, page: page, slot: slot)
                        .position(x: p.x + CGFloat(page) * w, y: p.y)
                }
            } else {
                ForEach(model.placedEntries) { item in
                    let p = metrics.cellCenter(item.slot)
                    EntryCell(model: model, entry: item.entry, metrics: metrics, center: p, page: item.page, slot: item.slot)
                        .position(x: p.x + CGFloat(item.page) * w, y: p.y)
                }
            }
        }
        .frame(width: w, height: metrics.size.height, alignment: .topLeading)
    }
}

/// The plate under an icon while a dragged app is held over it, ready to make a folder: it grows from 72% on a
/// spring (stiffness 520, damping 32) while fading in over 0.16 s, and shrinks back (420, 36) while fading out over
/// 0.12 s when the app moves away.
struct MergePlate: View {
    let active: Bool
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(.white.opacity(0.3))
            .frame(width: size * 1.18, height: size * 1.18)
            .scaleEffect(active ? 1 : 0.72)
            .animation(active ? .interpolatingSpring(mass: 1, stiffness: 520, damping: 32)
                              : .interpolatingSpring(mass: 1, stiffness: 420, damping: 36), value: active)
            .opacity(active ? 1 : 0)
            .animation(active ? .easeOut(duration: 0.16) : .easeIn(duration: 0.12), value: active)
    }
}

/// The Rename… sheet's field and buttons.
struct RenameFields: View {
    @ObservedObject var model: LaunchpadModel
    @State private var name = ""

    var body: some View {
        TextField(L("rename.field", "Name"), text: $name)
            .onAppear { name = model.renaming.map { model.title(for: .app($0)) } ?? "" }
        Button(L("rename.button", "Rename")) {
            if let path = model.renaming { model.rename(path, to: name) }
            model.renaming = nil
        }
        Button(L("common.cancel", "Cancel"), role: .cancel) { model.renaming = nil }
    }
}

/// A shape covering a centred column of the view, for hit-testing only the icon's column of a cell.
struct CenteredColumn: Shape {
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = min(width, rect.width)
        return Path(CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: rect.height))
    }
}

/// Moves the pages by a swipe in progress. Only this view watches the swipe offset, so the icons themselves are not
/// re-evaluated while the fingers move.
struct PagerSlide<Content: View>: View {
    @ObservedObject var pager: PagerState
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content.offset(x: -CGFloat(pager.page) * width + pager.x)
    }
}

/// The keyboard selection's highlight behind one cell. Only these small views watch the selection and the page,
/// so moving the selection or turning a page doesn't re-evaluate the cells themselves.
struct SelectionHighlight: View {
    @ObservedObject var selection: SelectionState
    @ObservedObject var pager: PagerState
    let page: Int
    let slot: Int
    let width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.white.opacity(pager.page == page && selection.index == slot ? 0.2 : 0))
            .frame(width: width)
    }
}

/// How a press on an icon is read: moving 4 pt from the press (any direction) drags it; releasing without having
/// dragged, within the icon's frame widened by 6 pt left and right and 2 pt up and down, is a click.
enum IconPress {
    static let dragStart: CGFloat = 4

    /// An icon's frame: the column of its icon and name, as wide as its highlight, centred on the cell. The rest of
    /// the cell is blank (it pages and closes like the margins).
    static func frame(center: CGPoint, iconSize: CGFloat, cellWidth: CGFloat, height: CGFloat) -> CGRect {
        let width = min(cellWidth, iconSize * 1.45)
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    static func isDrag(_ v: DragGesture.Value) -> Bool {
        hypot(v.translation.width, v.translation.height) >= dragStart
    }

    static func isClick(_ v: DragGesture.Value, frame: CGRect) -> Bool {
        frame.insetBy(dx: -6, dy: -2).contains(v.location)
    }
}

struct EntryCell: View {
    @ObservedObject var model: LaunchpadModel
    let entry: Entry
    let metrics: GridMetrics
    /// The cell's centre in the root coordinate space while its page is showing.
    let center: CGPoint
    let page: Int
    let slot: Int

    var body: some View {
        let d = model.drag
        let isDragged = d?.entry == entry && (d?.sourceFolder == nil || d?.extracted == true)
        let merging = model.mergeTarget == entry
        let picked = model.selected.contains(entry)
        let _ = FrameLog.shared.countCell()
        let frame = IconPress.frame(center: center, iconSize: metrics.iconSize, cellWidth: metrics.cell.width * 0.94,
                                    height: metrics.contentHeight + 12)
        VStack(spacing: metrics.labelSpacing) {
            EntryIcon(model: model, entry: entry, size: metrics.iconSize)
                .background(
                    RoundedRectangle(cornerRadius: metrics.iconSize * 0.28, style: .continuous)
                        .fill(.white.opacity(picked ? 0.22 : 0))
                        .frame(width: metrics.iconSize * 1.18, height: metrics.iconSize * 1.18)
                )
                .background(MergePlate(active: merging, size: metrics.iconSize))
                .overlay(alignment: .topTrailing) {
                    if picked { SelectionCheck(size: metrics.iconSize) }
                }
                .overlay(alignment: .topLeading) {
                    if model.optionHeld, let path = entry.appPath, model.canUninstall(path) {
                        UninstallBadge(size: metrics.iconSize) { model.uninstall(path) }
                    }
                }
                .modifier(Jiggle(active: model.optionHeld))
            Text(model.title(for: entry))
                .font(.system(size: metrics.labelFont, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: metrics.cell.width * 0.94)
        }
        .padding(.vertical, 6)
        .background(SelectionHighlight(selection: model.selectionState, pager: model.pager, page: page, slot: slot,
                                        width: metrics.iconSize * 1.45))
        .opacity(isDragged ? 0 : (entry.appPath.map(model.isInstalled) == false ? 0.4 : 1))
        .contentShape(CenteredColumn(width: frame.width))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("root"))
                .onChanged { v in
                    guard model.drag != nil || IconPress.isDrag(v) else { return }
                    let icon = CGPoint(x: center.x, y: center.y - (metrics.contentHeight - metrics.iconSize) / 2)
                    model.dragChanged(entry, at: v.location, grabbedAt: v.startLocation, iconCenter: icon, iconSize: metrics.iconSize)
                }
                .onEnded { v in
                    if model.drag != nil {
                        model.dragEnded()
                    } else if IconPress.isClick(v, frame: frame) {
                        model.tap(entry)
                    }
                }
        )
    }
}

struct EntryIcon: View {
    @ObservedObject var model: LaunchpadModel
    let entry: Entry
    let size: CGFloat

    var body: some View {
        switch entry {
        case .app(let path):
            AppIconImage(image: model.icons[path], size: size)
        case .folder(let id):
            FolderPreview(icons: model.previewIcons(id), size: size)
        }
    }
}

struct AppIconImage: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(.white.opacity(0.15))
                .frame(width: size * 0.82, height: size * 0.82)
                .frame(width: size, height: size)
        }
    }
}

/// Launchpad folder tile: frosted rounded square with a 3×3 preview of its apps.
struct FolderPreview: View {
    let icons: [NSImage?]
    let size: CGFloat

    var body: some View {
        let box = size * 0.82
        let inner = box * 0.27
        let gap = box * 0.05
        ZStack {
            RoundedRectangle(cornerRadius: box * 0.24, style: .continuous)
                .fill(.white.opacity(0.24))
                .overlay(
                    RoundedRectangle(cornerRadius: box * 0.24, style: .continuous)
                        .stroke(.white.opacity(0.3), lineWidth: 0.6)
                )
            VStack(spacing: gap) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<3, id: \.self) { c in
                            let i = r * 3 + c
                            if i < icons.count, let img = icons[i] {
                                Image(nsImage: img).resizable().interpolation(.high).frame(width: inner, height: inner)
                            } else {
                                Color.clear.frame(width: inner, height: inner)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: box, height: box)
        .frame(width: size, height: size)
    }
}

struct FolderOverlay: View {
    @ObservedObject var model: LaunchpadModel
    let folderID: UUID
    @FocusState private var naming: Bool

    var body: some View {
        let panel = model.folderPanel(for: folderID)
        let apps = model.layout.folders[folderID]?.apps ?? []
        let extracting = model.drag?.extracted == true
        ZStack(alignment: .topLeading) {
            // The grid behind an open folder is blurred by this layer, which exists only while the folder is open.
            ZStack {
                VisualEffect(material: .fullScreenUI, blending: .withinWindow)
                Color.black.opacity(0.15)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.closeFolder() }

            VisualEffect(material: .hudWindow, blending: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(.white.opacity(0.2), lineWidth: 0.6))
                .frame(width: panel.frame.width, height: panel.frame.height)
                .contentShape(Rectangle())
                .onTapGesture {}
                .position(x: panel.frame.midX, y: panel.frame.midY)

            TextField(L("folder.namePlaceholder", "Folder"), text: model.folderNameBinding(folderID))
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .frame(width: max(120, panel.frame.width - 80))
                // Return keeps the name and ends the editing; otherwise the field selects its text again and looks
                // as if it were still being edited.
                .focused($naming)
                .onSubmit { naming = false }
                .position(x: panel.frame.midX, y: panel.frame.minY + panel.header * 0.55)

            ForEach(Array(apps.enumerated()), id: \.element) { i, path in
                FolderAppCell(model: model, path: path, folderID: folderID, panel: panel, center: panel.center(i))
                    .position(panel.center(i))
            }
        }
        .opacity(extracting ? 0 : 1)
    }
}

struct FolderAppCell: View {
    @ObservedObject var model: LaunchpadModel
    let path: String
    let folderID: UUID
    let panel: FolderPanel
    let center: CGPoint

    var body: some View {
        let dragged = model.drag?.entry == .app(path) && model.drag?.sourceFolder == folderID
        let font = max(11, min(14, panel.iconSize * 0.12))
        let height = panel.iconSize + 6 + font * 1.3
        let frame = IconPress.frame(center: center, iconSize: panel.iconSize, cellWidth: panel.cell.width * 0.94, height: height)
        VStack(spacing: 6) {
            AppIconImage(image: model.icons[path], size: panel.iconSize)
                .overlay(alignment: .topLeading) {
                    if model.optionHeld, model.canUninstall(path) {
                        UninstallBadge(size: panel.iconSize) { model.uninstall(path) }
                    }
                }
                .modifier(Jiggle(active: model.optionHeld))
            Text(model.title(for: .app(path)))
                .font(.system(size: font, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: panel.cell.width * 0.94)
        }
        .opacity(dragged ? 0 : 1)
        .contentShape(CenteredColumn(width: frame.width))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("root"))
                .onChanged { v in
                    guard model.drag != nil || IconPress.isDrag(v) else { return }
                    let icon = CGPoint(x: center.x, y: center.y - (height - panel.iconSize) / 2)
                    model.folderDragChanged(path, folder: folderID, at: v.location, grabbedAt: v.startLocation,
                                            iconCenter: icon, iconSize: panel.iconSize)
                }
                .onEnded { v in
                    if model.drag != nil {
                        model.dragEnded()
                    } else if IconPress.isClick(v, frame: frame) {
                        model.tap(.app(path), inFolder: true)
                    }
                }
        )
    }
}

struct SelectionCheck: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size * 0.24, weight: .bold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.accentColor)
            .shadow(radius: 2)
            .offset(x: size * 0.04, y: -size * 0.04)
    }
}

struct UninstallBadge: View {
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: size * 0.24, weight: .bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color(white: 0.25).opacity(0.9))
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .offset(x: -size * 0.02, y: -size * 0.02)
        .help(L("grid.trashBadge", "Move to Trash"))
    }
}

struct CountBadge: View {
    let count: Int
    let size: CGFloat

    var body: some View {
        Text("\(count)")
            .font(.system(size: size * 0.16, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, size * 0.07)
            .frame(minWidth: size * 0.26, minHeight: size * 0.26)
            .background(Capsule().fill(Color.red))
            .offset(x: size * 0.06, y: -size * 0.06)
    }
}

/// Launchpad-style wobble while Option is held.
struct Jiggle: ViewModifier {
    let active: Bool
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active ? (phase ? 1.6 : -1.6) : 0))
            .animation(active ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true) : .default, value: phase)
            .onChange(of: active) { _, on in phase = on }
            .onAppear { if active { phase = true } }
    }
}
