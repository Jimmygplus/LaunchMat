import AppKit
import SwiftUI
import LaunchMatCore

struct RootView: View {
    @ObservedObject var model: LaunchpadModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let m = GridMetrics(size: geo.size, cols: model.gridSize.cols, rows: model.gridSize.rows)
            let folderOpen = model.openFolder != nil && model.drag?.extracted != true
            ZStack(alignment: .topLeading) {
                BackgroundView(image: model.wallpaper)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { model.backgroundTapped() }
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { model.swipeChanged($0.translation.width) }
                            .onEnded { model.swipeEnded($0.translation.width, predicted: $0.predictedEndTranslation.width) }
                    )

                ZStack(alignment: .topLeading) {
                    SearchField(text: $model.query, focused: $searchFocused)
                        .frame(width: min(280, geo.size.width * 0.3))
                        .position(x: geo.size.width / 2, y: m.topInset * 0.5)

                    PagerView(model: model, metrics: m)

                    if model.isSearching && model.results.isEmpty {
                        Text("No Results")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }

                    PageDots(count: model.pageCount, current: model.currentPage) { model.go(to: $0) }
                        .position(x: geo.size.width / 2, y: geo.size.height - m.bottomInset * 0.5)
                }
                .blur(radius: folderOpen ? 14 : 0)
                .scaleEffect(model.shown ? 1 : 1.07)
                .opacity(model.shown ? 1 : 0)

                if let id = model.openFolder {
                    FolderOverlay(model: model, folderID: id)
                        .transition(.opacity)
                }

                if let d = model.drag, d.sourceFolder == nil || d.extracted {
                    EntryIcon(model: model, entry: d.entry, size: m.iconSize)
                        .overlay(alignment: .topTrailing) {
                            if !d.companions.isEmpty { CountBadge(count: d.companions.count + 1, size: m.iconSize) }
                        }
                        .scaleEffect(1.1)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                        .position(d.location)
                        .allowsHitTesting(false)
                } else if let d = model.drag, let id = d.sourceFolder {
                    EntryIcon(model: model, entry: d.entry, size: model.folderPanel(for: id).iconSize)
                        .scaleEffect(1.1)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                        .position(d.location)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "root")
            .onAppear {
                model.metrics = m
                searchFocused = true
            }
            .onChange(of: m) { _, new in model.metrics = new }
            .onChange(of: model.focusToken) { _, _ in searchFocused = true }
        }
        .ignoresSafeArea()
    }
}

struct BackgroundView: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                VisualEffect(material: .fullScreenUI, blending: .behindWindow)
            }
            Color.black.opacity(0.2)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
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
            TextField("", text: $text, prompt: Text("Search").foregroundStyle(.white.opacity(0.6)))
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
        .background(Capsule().fill(.white.opacity(0.16)))
        .overlay(Capsule().stroke(.white.opacity(0.28), lineWidth: 0.5))
    }
}

struct PageDots: View {
    let count: Int
    let current: Int
    let onSelect: (Int) -> Void

    var body: some View {
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
                    EntryCell(model: model, entry: .app(app.id), metrics: metrics,
                              selected: page == model.currentPage && slot == model.selection)
                        .position(x: p.x + CGFloat(page) * w, y: p.y)
                }
            } else {
                ForEach(model.placedEntries) { item in
                    let p = metrics.cellCenter(item.slot)
                    EntryCell(model: model, entry: item.entry, metrics: metrics,
                              selected: item.page == model.currentPage && item.slot == model.selection)
                        .position(x: p.x + CGFloat(item.page) * w, y: p.y)
                }
            }
        }
        .frame(width: w, height: metrics.size.height, alignment: .topLeading)
        .offset(x: -CGFloat(model.currentPage) * w + model.scrollOffset)
    }
}

struct EntryCell: View {
    @ObservedObject var model: LaunchpadModel
    let entry: Entry
    let metrics: GridMetrics
    let selected: Bool

    var body: some View {
        let d = model.drag
        let isDragged = d?.entry == entry && (d?.sourceFolder == nil || d?.extracted == true)
        let merging = model.mergeTarget == entry
        let picked = model.selected.contains(entry)
        VStack(spacing: metrics.labelSpacing) {
            EntryIcon(model: model, entry: entry, size: metrics.iconSize)
                .background(
                    RoundedRectangle(cornerRadius: metrics.iconSize * 0.28, style: .continuous)
                        .fill(.white.opacity(merging ? 0.3 : (picked ? 0.22 : 0)))
                        .frame(width: metrics.iconSize * 1.18, height: metrics.iconSize * 1.18)
                )
                .overlay(alignment: .topTrailing) {
                    if picked { SelectionCheck(size: metrics.iconSize) }
                }
                .overlay(alignment: .topLeading) {
                    if model.optionHeld, let path = entry.appPath, model.canUninstall(path) {
                        UninstallBadge(size: metrics.iconSize) { model.uninstall(path) }
                    }
                }
                .modifier(Jiggle(active: model.optionHeld))
                .scaleEffect(merging ? 1.12 : 1)
            Text(model.title(for: entry))
                .font(.system(size: metrics.labelFont, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: metrics.cell.width * 0.94)
        }
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(selected ? 0.2 : 0))
                .frame(width: metrics.iconSize * 1.45)
        )
        .opacity(isDragged ? 0 : (entry.appPath.map(model.isInstalled) == false ? 0.4 : 1))
        .contentShape(Rectangle())
        .onTapGesture { model.tap(entry) }
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("root"))
                .onChanged { model.dragChanged(entry, at: $0.location) }
                .onEnded { _ in model.dragEnded() }
        )
        .contextMenu { EntryMenu(model: model, entry: entry, folder: nil) }
    }
}

struct EntryMenu: View {
    @ObservedObject var model: LaunchpadModel
    let entry: Entry
    let folder: UUID?

    var body: some View {
        let multi = folder == nil && model.selected.count > 1 && model.selected.contains(entry)
        if multi {
            let apps = model.selectedApps.count
            Button("New Folder with \(apps) Apps") { model.groupSelected() }.disabled(apps < 2)
            Button("Hide \(apps) Apps") { model.hideSelected() }.disabled(apps == 0)
            Divider()
            Button("Deselect All") { model.selected.removeAll() }
        } else {
            switch entry {
            case .app(let path):
                Button("Open") { model.launch(path) }
                Button("Show in Finder") { model.showInFinder(path) }
                if let folder {
                    Button("Remove from Folder") { model.removeFromFolder(path, folder: folder) }
                }
                Divider()
                Button("Hide") { model.hide(path) }
                if model.canUninstall(path) {
                    Button("Move to Trash…") { model.uninstall(path) }
                }
            case .folder:
                Button("Open Folder") { model.activate(entry) }
            }
        }
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

    var body: some View {
        let panel = model.folderPanel(for: folderID)
        let apps = model.layout.folders[folderID]?.apps ?? []
        let extracting = model.drag?.extracted == true
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.15)
                .contentShape(Rectangle())
                .onTapGesture { model.closeFolder() }

            VisualEffect(material: .hudWindow, blending: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(.white.opacity(0.2), lineWidth: 0.6))
                .frame(width: panel.frame.width, height: panel.frame.height)
                .contentShape(Rectangle())
                .onTapGesture {}
                .position(x: panel.frame.midX, y: panel.frame.midY)

            TextField("Folder", text: model.folderNameBinding(folderID))
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .frame(width: max(120, panel.frame.width - 80))
                .position(x: panel.frame.midX, y: panel.frame.minY + panel.header * 0.55)

            ForEach(Array(apps.enumerated()), id: \.element) { i, path in
                FolderAppCell(model: model, path: path, folderID: folderID, panel: panel)
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

    var body: some View {
        let dragged = model.drag?.entry == .app(path) && model.drag?.sourceFolder == folderID
        VStack(spacing: 6) {
            AppIconImage(image: model.icons[path], size: panel.iconSize)
                .overlay(alignment: .topLeading) {
                    if model.optionHeld, model.canUninstall(path) {
                        UninstallBadge(size: panel.iconSize) { model.uninstall(path) }
                    }
                }
                .modifier(Jiggle(active: model.optionHeld))
            Text(model.title(for: .app(path)))
                .font(.system(size: max(11, min(14, panel.iconSize * 0.12)), weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: panel.cell.width * 0.94)
        }
        .opacity(dragged ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.tap(.app(path), inFolder: true) }
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("root"))
                .onChanged { model.folderDragChanged(path, folder: folderID, at: $0.location) }
                .onEnded { _ in model.dragEnded() }
        )
        .contextMenu { EntryMenu(model: model, entry: .app(path), folder: folderID) }
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
        .help("Move to Trash")
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
