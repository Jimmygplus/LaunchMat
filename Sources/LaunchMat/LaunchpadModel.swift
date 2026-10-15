import AppKit
import SwiftUI
import LaunchMatCore

struct DragState: Equatable {
    var entry: Entry
    var location: CGPoint
    /// Set when the drag started inside an open folder.
    var sourceFolder: UUID?
    /// The app left the folder panel and now has a slot in the main grid.
    var extracted = false
    /// Other selected items carried along in a multi-drag (removed from the grid while dragging).
    var companions: [Entry] = []
    /// Where the icon was grabbed, from its centre: the floating icon keeps this offset from the pointer.
    var grab: CGSize = .zero

    /// The grab point relative to the icon's centre, kept within the icon.
    static func grab(at start: CGPoint, iconCenter: CGPoint, iconSize: CGFloat) -> CGSize {
        let half = iconSize / 2
        return CGSize(width: min(half, max(-half, start.x - iconCenter.x)),
                      height: min(half, max(-half, start.y - iconCenter.y)))
    }
}

/// NSImage is not Sendable; icons are created off the main thread and only read afterwards.
struct IconBatch: @unchecked Sendable {
    let images: [String: NSImage]
}

struct PlacedEntry: Identifiable {
    let entry: Entry
    let page: Int
    let slot: Int
    var id: String { entry.key }
}

/// See LaunchpadModel.focus.
@MainActor
final class FocusSignal: ObservableObject {
    @Published var token = 0
}

/// Which page shows, and how far a swipe in progress pushes it (see LaunchpadModel.pager).
@MainActor
final class PagerState: ObservableObject {
    @Published var page = 0
    @Published var x: CGFloat = 0
}

/// The keyboard selection on the showing page (see LaunchpadModel.selection).
@MainActor
final class SelectionState: ObservableObject {
    @Published var index: Int?
}

@MainActor
final class LaunchpadModel: ObservableObject {
    @Published var layout = PadLayout()
    @Published private(set) var apps: [String: AppRecord] = [:]
    @Published private(set) var icons: [String: NSImage] = [:]
    /// The showing page. Kept in `pager`, not in the model's published state: turning a page moves the pages and
    /// the page dots without re-evaluating every icon.
    var currentPage: Int {
        get { pager.page }
        set { pager.page = newValue }
    }
    @Published var query = "" {
        didSet { if oldValue != query { updateSearch() } }
    }
    @Published private(set) var results: [AppRecord] = []
    @Published var openFolder: UUID?
    @Published private(set) var drag: DragState?
    @Published private(set) var mergeTarget: Entry?
    /// The keyboard selection (a slot on the showing page). Kept in `selectionState`, watched only by the highlights.
    var selection: Int? {
        get { selectionState.index }
        set { selectionState.index = newValue }
    }
    let selectionState = SelectionState()
    /// ⌘-click multi-selection.
    @Published var selected: Set<Entry> = []
    /// Option held: show uninstall badges (Launchpad's "jiggle" mode).
    @Published var optionHeld = false
    @Published private(set) var gridSize = GridSize.load()
    @Published var wallpaper: NSImage?
    /// The screen the grid was last opened on, for a wallpaper that arrives late.
    weak var screenShown: NSScreen?
    /// Bumped to put the cursor in the search field; watched only by the field, not by the grid.
    let focus = FocusSignal()

    /// Kept in sync by the view; drag hit-testing uses it.
    var metrics = GridMetrics(size: CGSize(width: 1440, height: 900), cols: 7, rows: 5)
    var dismissHandler: (() -> Void)?
    var persistenceEnabled = true

    private var searching = false
    private var pageBeforeSearch = 0
    private var pendingMerge: Entry?
    private var mergeTask: Task<Void, Never>?
    private var flipDirection = 0
    private var flipTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var suppressTapUntil = Date.distantPast
    private var swipeAccum: CGFloat = 0
    private var blankPaging = false
    /// Locked when a trackpad swipe starts: true = vertical, false = horizontal, nil = not decided yet.
    private var swipeVertical: Bool?
    private var lastWheelFlip: TimeInterval = -.infinity
    private var pageSettlingUntil = Date.distantPast
    private var scanning = false
    private var pendingScan: [AppRecord]?
    private var iconStamps: [String: Date?] = [:]

    /// Overdamped: the page glides to rest without bouncing, settling in about 0.7 s.
    private static let pageSpring = Animation.interpolatingSpring(mass: 0.02, stiffness: 4, damping: 1)
    private static let pageSettle: TimeInterval = 0.7
    /// Mouse wheel: smallest delta that counts, and the shortest time between two page turns.
    private static let wheelThreshold: CGFloat = 1.0
    private static let wheelInterval: TimeInterval = 0.5
    /// Icons making room, and other layout changes, move over 0.36 s, easing in and out.
    private static let reflow = Animation.easeInOut(duration: 0.36)

    /// The showing page and the swipe offset. Kept out of the model's published state, so turning pages and
    /// following the fingers move the pager without re-evaluating every icon.
    let pager = PagerState()

    var capacity: Int { gridSize.cols * gridSize.rows }
    var isSearching: Bool { !Search.normalizedQuery(query).isEmpty }
    var pageCount: Int {
        isSearching ? max(1, (results.count + capacity - 1) / capacity) : max(1, layout.pages.count)
    }

    var placedEntries: [PlacedEntry] {
        layout.pages.enumerated().flatMap { p, page in
            page.enumerated().map { PlacedEntry(entry: $0.element, page: p, slot: $0.offset) }
        }
    }

    // MARK: - Loading

    static var layoutURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchMat", isDirectory: true)
        return dir.appendingPathComponent("layout.json")
    }

    func load(fresh: Bool = false, sync: Bool = false) {
        if !fresh, let data = try? Data(contentsOf: Self.layoutURL) {
            if let saved = try? JSONDecoder().decode(PadLayout.self, from: data) {
                layout = saved
            } else if persistenceEnabled {
                // Never overwrite a file we couldn't read: keep it next to the fresh layout.
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let backup = Self.layoutURL.deletingLastPathComponent().appendingPathComponent("layout.corrupt-\(stamp).json")
                try? FileManager.default.moveItem(at: Self.layoutURL, to: backup)
                NSLog("LaunchMat: unreadable layout moved to \(backup.path)")
            }
        }
        refreshApps(sync: sync)
    }

    func refreshApps(sync: Bool = false) {
        if sync {
            apply(AppScanner.scan())
            let missing = Array(apps.keys)
            icons.merge(Self.loadIcons(missing, pixels: iconPixels)) { $1 }
            renderedIconPixels = iconPixels
            if persistenceEnabled { pruneIconCache() }
            return
        }
        guard !scanning else { return }
        scanning = true
        let model = self
        let pixels = iconPixels
        Task.detached(priority: .userInitiated) {
            let records = AppScanner.scan()
            let missing = await model.applyScan(records)
            let loaded = IconBatch(images: missing.isEmpty ? [:] : Self.loadIcons(missing, pixels: pixels))
            await model.finishScan(loaded)
        }
    }

    /// Returns the paths that need a (new) icon. During a drag the result waits until the drop.
    private func applyScan(_ records: [AppRecord]) -> [String] {
        if drag != nil {
            pendingScan = records
            return []
        }
        apply(records)
        return iconsToLoad()
    }

    /// Missing icons, plus apps whose bundle changed since its icon was loaded (updates).
    private func iconsToLoad() -> [String] {
        apps.keys.filter { path in
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            if icons[path] == nil || iconStamps[path] != modified {
                iconStamps[path] = modified
                return true
            }
            return false
        }
    }

    private func finishScan(_ batch: IconBatch) {
        if !batch.images.isEmpty { icons.merge(batch.images) { $1 } }
        if renderedIconPixels == 0 {
            renderedIconPixels = iconPixels
            pruneIconCache()
        }
        scanning = false
    }

    /// The icon bitmaps' side in pixels: the grid's icon size (the dragged icon is drawn 10% larger) times the main
    /// screen's scale, at most 512.
    private var iconPixels: Int {
        let screen = NSScreen.main
        let size = screen?.frame.size ?? CGSize(width: 1440, height: 900)
        let points = GridMetrics(size: size, cols: gridSize.cols, rows: gridSize.rows).iconSize * 1.1
        return min(512, Int((points * (screen?.backingScaleFactor ?? 2)).rounded(.up)))
    }
    private var renderedIconPixels = 0

    /// Redraws every icon in the background when the size they appear at has changed (grid size, screens).
    func refreshIconSize() {
        let pixels = iconPixels
        guard pixels != renderedIconPixels, !icons.isEmpty else { return }
        renderedIconPixels = pixels
        let paths = Array(icons.keys)
        let model = self
        Task.detached(priority: .utility) {
            let batch = IconBatch(images: Self.loadIcons(paths, pixels: pixels))
            await model.replaceIcons(batch)
        }
    }

    private func replaceIcons(_ batch: IconBatch) {
        icons.merge(batch.images) { $1 }
        pruneIconCache()
    }

    /// Each icon is drawn once, off the main thread, into a bitmap exactly as large as it appears, so showing a page
    /// only copies pixels: nothing is rendered on demand when a page first scrolls into view.
    /// Bitmaps already drawn at this size come from the disk cache (IconCache).
    nonisolated private static func loadIcons(_ paths: [String], pixels: Int) -> [String: NSImage] {
        var out: [String: NSImage] = [:]
        for path in paths {
            let key = IconCache.key(path: path, pixels: pixels)
            if let cached = IconCache.load(key) {
                out[path] = NSImage(cgImage: cached, size: NSSize(width: pixels, height: pixels))
                continue
            }
            let source = NSWorkspace.shared.icon(forFile: path)
            if let bitmap = render(source, pixels: pixels) {
                IconCache.store(bitmap, as: key)
                out[path] = NSImage(cgImage: bitmap, size: NSSize(width: pixels, height: pixels))
            } else {
                source.size = NSSize(width: 256, height: 256)
                out[path] = source
            }
        }
        return out
    }

    /// After a full load: drop cached icons of apps that are gone or changed, and of other sizes.
    private func pruneIconCache() {
        let keep = Set(apps.keys.map { IconCache.key(path: $0, pixels: renderedIconPixels) })
        Task.detached(priority: .background) { IconCache.prune(keeping: keep) }
    }

    nonisolated private static func render(_ image: NSImage, pixels: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private func apply(_ records: [AppRecord]) {
        var dict: [String: AppRecord] = [:]
        for r in records { dict[r.id] = r }
        apps = dict
        var l = layout
        if l.isEmpty && l.folders.isEmpty {
            l = initialLayout(records)
        } else {
            let sorted = records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            l.reconcile(installed: sorted.map(\.id), capacity: capacity)
        }
        if l != layout {
            layout = l
            scheduleSave()
        }
        if let id = openFolder, layout.folders[id] == nil { openFolder = nil }
        currentPage = min(currentPage, pageCount - 1)
        updateSearch(keepPage: true)
    }

    /// Installed now (false for apps kept in place while missing, e.g. mid-update).
    func isInstalled(_ path: String) -> Bool { apps[path] != nil }

    /// First run: Apple apps, then a Utilities folder, then everything else by name (classic Launchpad order).
    private func initialLayout(_ records: [AppRecord]) -> PadLayout {
        let byName = records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var l = PadLayout(pages: [[]])
        for r in byName where r.isApple && !r.isUtility { l.append(.app(r.id), capacity: capacity) }
        let utilities = byName.filter(\.isUtility)
        if utilities.count > 1 {
            let name = FileManager.default.displayName(atPath: "/System/Applications/Utilities")
            let folder = Folder(name: name, apps: utilities.map(\.id))
            l.folders[folder.id] = folder
            l.append(.folder(folder.id), capacity: capacity)
        } else {
            utilities.forEach { l.append(.app($0.id), capacity: capacity) }
        }
        for r in byName where !r.isApple && !r.isUtility { l.append(.app(r.id), capacity: capacity) }
        return l
    }

    func scheduleSave() {
        guard persistenceEnabled else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        guard persistenceEnabled else { return }
        let url = Self.layoutURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(layout) { try? data.write(to: url, options: .atomic) }
    }

    func resetLayout() {
        layout = PadLayout()
        currentPage = 0
        refreshApps()
    }

    func unhide(_ path: String) {
        layout.hidden.remove(path)
        refreshApps()
    }

    /// An app's name as the grid shows it, also for apps that are hidden or missing.
    func displayName(_ path: String) -> String {
        apps[path]?.name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    func unhideAll() {
        layout.hidden.removeAll()
        refreshApps()
    }

    func setGrid(_ size: GridSize) {
        gridSize = size
        size.save()
        refreshIconSize()
        layout.fit(capacity: capacity)
        layout.compact()
        currentPage = min(currentPage, pageCount - 1)
        scheduleSave()
    }

    // MARK: - Lookup

    func title(for entry: Entry) -> String {
        switch entry {
        case .app(let path): return apps[path]?.name ?? (path as NSString).lastPathComponent
        case .folder(let id): return layout.folders[id]?.name ?? ""
        }
    }

    func previewIcons(_ id: UUID) -> [NSImage?] {
        let dragged = drag?.extracted == true ? drag?.entry.appPath : nil
        let apps = (layout.folders[id]?.apps ?? []).filter { $0 != dragged }
        return apps.prefix(9).map { icons[$0] }
    }

    var firstFolderID: UUID? { layout.pages.flatMap { $0 }.compactMap(\.folderID).first }

    func folderNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.layout.folders[id]?.name ?? "" },
            set: { [weak self] in
                self?.layout.folders[id]?.name = $0
                self?.scheduleSave()
            }
        )
    }

    private func suggestedFolderName(target: Entry, adding app: String) -> String {
        if let path = target.appPath, let c = apps[path]?.category, c == apps[app]?.category { return c }
        return apps[app]?.category ?? apps[target.appPath ?? ""]?.category ?? "Untitled"
    }

    // MARK: - Search

    private func updateSearch(keepPage: Bool = false) {
        let q = Search.normalizedQuery(query)
        guard !q.isEmpty else {
            results = []
            if searching {
                searching = false
                currentPage = min(pageBeforeSearch, pageCount - 1)
            }
            selection = nil
            return
        }
        if !searching {
            searching = true
            pageBeforeSearch = currentPage
            openFolder = nil
        }
        var order: [String: Int] = [:]
        for (i, path) in layout.orderedApps.enumerated() { order[path] = i }
        let pool = apps.values.filter { !layout.hidden.contains($0.id) }
        results = Search.rank(pool, query: q, keys: \.keys, order: { order[$0.id] ?? Int.max })
        if keepPage {
            currentPage = min(currentPage, pageCount - 1)
            return
        }
        currentPage = 0
        pager.x = 0
        selection = results.isEmpty ? nil : 0
    }

    // MARK: - Activation

    func tap(_ entry: Entry, inFolder: Bool = false) {
        guard Date() > suppressTapUntil, drag == nil else { return }
        if !inFolder, !isSearching, NSEvent.modifierFlags.contains(.command) {
            if selected.contains(entry) { selected.remove(entry) } else { selected.insert(entry) }
            return
        }
        selected.removeAll()
        activate(entry)
    }

    /// Apps among the selection, in grid order (folders contribute nothing).
    var selectedApps: [String] {
        layout.pages.flatMap { $0 }.filter { selected.contains($0) }.compactMap(\.appPath)
    }

    func hideSelected() {
        withAnimation(Self.reflow) {
            for path in selectedApps { layout.hide(path) }
            layout.compact()
            selected.removeAll()
            currentPage = min(currentPage, pageCount - 1)
        }
        scheduleSave()
    }

    func groupSelected() {
        let apps = selectedApps
        guard apps.count >= 2 else { return }
        let name = apps.compactMap { self.apps[$0]?.category }.first ?? "Untitled"
        var id: UUID?
        withAnimation(Self.reflow) {
            id = layout.group(apps: apps, name: name, capacity: capacity)
            layout.compact()
            selected.removeAll()
        }
        if let id { withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { openFolder = id } }
        scheduleSave()
    }

    func canUninstall(_ path: String) -> Bool { apps[path].map(Uninstaller.canUninstall) ?? false }

    /// The grid hides first so the confirmation dialog isn't covered by the overlay window.
    func uninstall(_ path: String) {
        guard let app = apps[path], Uninstaller.canUninstall(app) else { return }
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            Uninstaller.confirmAndUninstall(app, installed: Array(self.apps.values)) { [weak self] removed in
                if removed { self?.refreshApps() }
            }
        }
    }

    /// Replaces the layout with the old system Launchpad's pages and folders; apps it didn't know are appended.
    func applyImported(_ pages: [[LegacyLaunchpad.Item]]) -> Int {
        var byBundle: [String: String] = [:]
        for app in apps.values.sorted(by: { $0.id < $1.id }) {
            if let id = app.bundleID, byBundle[id] == nil || app.id.hasPrefix("/Applications/") { byBundle[id] = app.id }
        }
        var imported = LegacyLaunchpad.layout(from: pages, resolve: { byBundle[$0] }, capacity: capacity)
        let placed = imported.orderedApps.count
        imported.hidden = layout.hidden
        let sorted = apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        imported.reconcile(installed: sorted.map(\.id), capacity: capacity)
        withAnimation(Self.reflow) {
            layout = imported
            currentPage = 0
            selected.removeAll()
        }
        saveNow()
        return placed
    }

    func activate(_ entry: Entry) {
        switch entry {
        case .app(let path): launch(path)
        case .folder(let id):
            selection = nil
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { openFolder = id }
        }
    }

    /// Opens the main menu at the pointer (the ⋯ button next to the search field). Set by the window controller.
    var showMainMenu: (() -> Void)?

    /// Replaces opening apps, for --mouse-test.
    var launchHandler: ((String) -> Void)?

    func launch(_ path: String) {
        if let launchHandler { return launchHandler(path) }
        guard isInstalled(path) else { return } // kept in place while missing (updating / reinstalling)
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                           configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("LaunchMat: could not open \(path): \(error.localizedDescription)") }
        }
        dismiss()
    }

    func dismiss() { dismissHandler?() }

    func backgroundTapped() {
        guard Date() > suppressTapUntil else { return }
        if openFolder != nil { closeFolder() } else { dismiss() }
    }

    func closeFolder() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { openFolder = nil }
        focus.token += 1
    }

    func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        dismiss()
    }

    func hide(_ path: String) {
        withAnimation(Self.reflow) {
            layout.hide(path)
            layout.compact()
            currentPage = min(currentPage, pageCount - 1)
            if let id = openFolder, layout.folders[id] == nil { openFolder = nil }
        }
        updateSearch()
        scheduleSave()
    }

    func removeFromFolder(_ path: String, folder id: UUID) {
        withAnimation(Self.reflow) {
            layout.folders[id]?.apps.removeAll { $0 == path }
            layout.insert(.app(path), page: currentPage, index: layout.pages[currentPage].count, capacity: capacity)
            if (layout.folders[id]?.apps.count ?? 0) < 2 { openFolder = nil }
            layout.dissolveIfNeeded(id)
        }
        scheduleSave()
    }

    func willShow(on screen: NSScreen) {
        // Only the prepared image; if it isn't ready (a new desktop picture), it fades in when it is.
        if let image = Wallpaper.cached(for: screen), image !== wallpaper { wallpaper = image }
        prepareWallpapers()
        focus.token += 1
    }

    /// Blurs every screen's desktop picture in the background. Called at launch, when the Space or the screens
    /// change, and on each open (a no-op when nothing changed).
    func prepareWallpapers() {
        Wallpaper.prepare(for: NSScreen.screens) { [weak self] in
            guard let self, let screen = self.screenShown, let image = Wallpaper.cached(for: screen),
                  image !== self.wallpaper else { return }
            withAnimation(.easeOut(duration: 0.36)) { self.wallpaper = image }
        }
    }

    /// After the opening animation: catch up with apps installed or removed meanwhile. Nothing in the grid changes
    /// while it animates.
    func didShow() {
        refreshApps()
    }

    func didHide() {
        if drag != nil {
            cancelPendingMerge()
            dragEnded()
        }
        query = ""
        openFolder = nil
        selection = nil
        selected.removeAll()
        optionHeld = false
        pager.x = 0
        saveNow()
    }

    // MARK: - Paging

    func go(to page: Int) {
        let target = max(0, min(pageCount - 1, page))
        if target != currentPage {
            FrameLog.shared.begin("page", seconds: 0.8)
            pageSettlingUntil = Date().addingTimeInterval(Self.pageSettle)
            FrameRateBoost.hold(for: Self.pageSettle)
        }
        withAnimation(Self.pageSpring) {
            currentPage = target
            pager.x = 0
        }
    }

    private func track(_ d: CGFloat) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { pager.x = Paging.follow(d, width: metrics.size.width) }
    }

    /// True when a point (root coordinates) is on blank space of the showing page: not on an icon's column and not
    /// on the search field. Right-clicking there opens the main menu.
    func isBlank(at p: CGPoint) -> Bool {
        let m = metrics
        let searchWidth = min(280, m.size.width * 0.3)
        let search = CGRect(x: (m.size.width - searchWidth) / 2, y: m.topInset * 0.5 - 15, width: searchWidth, height: 30)
        if search.contains(p) { return false }
        let count = isSearching ? max(0, min(capacity, results.count - currentPage * capacity))
            : (currentPage < layout.pages.count ? layout.pages[currentPage].count : 0)
        for slot in 0..<count {
            let frame = IconPress.frame(center: m.cellCenter(slot), iconSize: m.iconSize, cellWidth: m.cell.width * 0.94,
                                        height: m.contentHeight + 12)
            if frame.contains(p) { return false }
        }
        return true
    }

    /// A press on a blank part of the grid. It turns into a page drag once it has moved 4 pt sideways (up and down
    /// don't count); from then on the pages follow the pointer like a swipe.
    func blankDragChanged(_ t: CGSize) {
        guard openFolder == nil, drag == nil else { return }
        if !blankPaging, abs(t.width) >= IconPress.dragStart {
            blankPaging = true
            FrameLog.shared.begin("track", seconds: 1.0)
        }
        if blankPaging { track(t.width) }
    }

    /// Releasing a page drag turns the page past 50 pt (or springs back); a press that didn't move 4 pt is a click
    /// on blank space, which closes the grid (or an open folder).
    func blankDragEnded(_ t: CGSize) {
        defer { blankPaging = false }
        if blankPaging {
            guard openFolder == nil, drag == nil else { return }
            settlePage(t.width, threshold: Paging.threshold)
        } else if hypot(t.width, t.height) < IconPress.dragStart {
            backgroundTapped()
        }
    }

    /// Turns the page, or springs back when the swipe was too short (see Paging.turn).
    private func settlePage(_ offset: CGFloat, threshold: Double) {
        let target = currentPage + Paging.turn(offset: offset, threshold: threshold, settling: Date() < pageSettlingUntil)
        if target != currentPage { selection = nil }
        go(to: target)
    }

    /// Trackpad: follow the fingers, then turn the page or spring back. Mouse wheel: one notch = one page.
    func handleScroll(_ e: NSEvent) {
        guard openFolder == nil, drag == nil else { return }
        if e.hasPreciseScrollingDeltas {
            if !e.momentumPhase.isEmpty { return }
            if e.phase.contains(.began) {
                swipeAccum = 0
                swipeVertical = nil
                FrameLog.shared.begin("track", seconds: 1.0)
            }
            if e.phase.contains(.began) || e.phase.contains(.changed) {
                // The pages move with the fingers whether or not natural scrolling is on.
                let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
                let dx = e.scrollingDeltaX * sign, dy = e.scrollingDeltaY * sign
                guard abs(dx) >= 0.001 || abs(dy) >= 0.001 else { return }
                if swipeVertical == nil { swipeVertical = abs(dy) > abs(dx) }
                if swipeVertical == true {
                    swipeAccum += dy
                } else {
                    swipeAccum += dx
                    track(swipeAccum)
                }
            }
            if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
                let threshold = swipeVertical == true ? Paging.verticalThreshold : Paging.threshold
                settlePage(swipeAccum, threshold: threshold)
                swipeAccum = 0
                swipeVertical = nil
            }
        } else {
            let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
            guard abs(d) >= Self.wheelThreshold, e.timestamp - lastWheelFlip >= Self.wheelInterval else { return }
            lastWheelFlip = e.timestamp
            selection = nil
            go(to: currentPage + (d < 0 ? 1 : -1))
        }
    }

    // MARK: - Keyboard

    private var visibleCount: Int {
        if isSearching { return max(0, min(capacity, results.count - currentPage * capacity)) }
        return currentPage < layout.pages.count ? layout.pages[currentPage].count : 0
    }

    /// Returns true when the key was handled.
    func handleKey(_ e: NSEvent) -> Bool {
        if drag != nil {
            // Keys can't change the view under an active drag; Esc drops it in place.
            if e.keyCode == 53 {
                cancelPendingMerge()
                dragEnded()
            }
            return true
        }
        let typing = !query.isEmpty
        switch e.keyCode {
        case 53: // esc
            if openFolder != nil {
                closeFolder()
            } else if !selected.isEmpty {
                selected.removeAll()
            } else if !query.isEmpty {
                query = ""
            } else {
                dismiss()
            }
            return true
        case 36, 76: // return
            guard openFolder == nil else { return false }
            activateVisible(selection ?? 0)
            return true
        case 123, 124 where typing: return false // move the caret in the search text
        case 123: moveSelection(-1); return openFolder == nil
        case 124: moveSelection(1); return openFolder == nil
        case 125: moveSelection(gridSize.cols); return openFolder == nil
        case 126: moveSelection(-gridSize.cols); return openFolder == nil
        default:
            return false
        }
    }

    private func activateVisible(_ i: Int) {
        if isSearching {
            let idx = currentPage * capacity + i
            if results.indices.contains(idx) { launch(results[idx].id) }
        } else if currentPage < layout.pages.count, layout.pages[currentPage].indices.contains(i) {
            activate(layout.pages[currentPage][i])
        }
    }

    private func moveSelection(_ delta: Int) {
        guard openFolder == nil else { return }
        guard let s = selection else {
            selection = visibleCount > 0 ? 0 : nil
            return
        }
        let next = s + delta
        if next >= visibleCount {
            if delta == 1, currentPage + 1 < pageCount {
                go(to: currentPage + 1)
                selection = 0
            }
            return
        }
        if next < 0 {
            if delta == -1, currentPage > 0 {
                go(to: currentPage - 1)
                selection = max(0, visibleCount - 1)
            }
            return
        }
        selection = next
    }

    // MARK: - Drag & drop (main grid)

    func dragChanged(_ entry: Entry, at loc: CGPoint, grabbedAt start: CGPoint? = nil,
                     iconCenter: CGPoint? = nil, iconSize: CGFloat = 0) {
        guard !isSearching else { return }
        if drag == nil {
            var state = DragState(entry: entry, location: loc)
            if let start, let iconCenter { state.grab = DragState.grab(at: start, iconCenter: iconCenter, iconSize: iconSize) }
            if selected.contains(entry), selected.count > 1 {
                // The other selected items ride along: lift them out of the grid now, put them back on drop.
                let order = layout.pages.flatMap { $0 }
                state.companions = order.filter { selected.contains($0) && $0 != entry }
                withAnimation(Self.reflow) {
                    for c in state.companions { layout.remove(c) }
                }
            }
            drag = state
            selection = nil
            lastSortPoint = nil
        }
        drag?.location = loc
        guard let dragged = drag?.entry else { return }
        handleEdge(loc)
        guard let idx = metrics.slot(at: loc) else {
            cancelMerge()
            return
        }
        let page = currentPage < layout.pages.count ? layout.pages[currentPage] : []
        if idx < page.count, page[idx] != dragged {
            let target = page[idx]
            let mergeable = dragged.appPath != nil && (drag?.companions.allSatisfy { $0.appPath != nil } ?? true)
            if mergeable, mergeZone(idx).contains(loc) {
                beginMerge(target) // over the middle of an icon (app or folder): make a folder or join it
                return
            }
            cancelMerge()
            // Elsewhere in the cell (its edges, the gap, the name) the pointer only decides before or after the
            // target, so approaching a neighbour doesn't push it away before the merge zone is reached.
            guard sortPointMoved(loc) else { return }
            let from = page.firstIndex(of: dragged)
            let targetIndex = from.map { $0 < idx ? idx - 1 : idx } ?? idx // counted without the dragged item
            let index = targetIndex + (loc.x >= metrics.cellCenter(idx).x ? 1 : 0)
            if index != from { place(dragged, at: index) }
        } else if idx >= page.count {
            cancelMerge()
            guard sortPointMoved(loc) else { return }
            place(dragged, at: page.count)
        } else {
            cancelMerge()
        }
    }

    /// The part of an icon that makes a folder when an app is held over it: the icon image inset by
    /// `mergeZoneInset` of its size on each side.
    private func mergeZone(_ slot: Int) -> CGRect {
        let c = metrics.iconCenter(slot), s = metrics.iconSize
        return CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s).insetBy(dx: s * Self.mergeZoneInset, dy: s * Self.mergeZoneInset)
    }

    /// Provisional, to be calibrated against the original (recording S06): 20% in from each side of the icon.
    private static let mergeZoneInset: CGFloat = 0.2
    /// Reordering is recalculated only after the pointer has moved 4 pt from where it was last done.
    private var lastSortPoint: CGPoint?

    private func sortPointMoved(_ loc: CGPoint) -> Bool {
        if let last = lastSortPoint, hypot(loc.x - last.x, loc.y - last.y) < 4 { return false }
        lastSortPoint = loc
        return true
    }

    private func place(_ entry: Entry, at idx: Int) {
        if let loc = layout.locate(entry), loc.page == currentPage {
            let last = layout.pages[currentPage].count - 1
            if loc.index == min(idx, last) { return }
        }
        withAnimation(Self.reflow) {
            layout.move(entry, page: currentPage, index: idx, capacity: capacity)
        }
    }

    private func beginMerge(_ target: Entry) {
        if pendingMerge == target { return }
        cancelMerge()
        pendingMerge = target
        // After 0.1 s over the merge zone the target shows its merge plate (see MergePlate); dropping then merges.
        mergeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, let self, self.pendingMerge == target else { return }
            self.mergeTarget = target
        }
    }

    private func cancelMerge() {
        mergeTask?.cancel()
        mergeTask = nil
        pendingMerge = nil
        if mergeTarget != nil { mergeTarget = nil }
    }

    /// Holding the dragged icon near the left/right edge flips the page (and can open a new last page).
    /// Dragging an icon to the screen edge and holding it there for 0.6 s turns the page.
    private func handleEdge(_ loc: CGPoint) {
        let edge = max(36, metrics.sideInset * 0.6)
        let dir = loc.x < edge ? -1 : (loc.x > metrics.size.width - edge ? 1 : 0)
        if dir == flipDirection { return }
        flipTask?.cancel()
        flipDirection = dir
        guard dir != 0 else { return }
        flipTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.flip(dir)
        }
    }

    private func flip(_ dir: Int) {
        flipDirection = 0
        guard let d = drag else { return }
        var target = currentPage + dir
        guard target >= 0 else { return }
        if target >= layout.pages.count {
            if let loc = layout.locate(d.entry), loc.page == layout.pages.count - 1, layout.pages[loc.page].count == 1 {
                return // already alone on the last page
            }
            layout.pages.append([])
            target = layout.pages.count - 1
        }
        cancelMerge()
        withAnimation(Self.pageSpring) { currentPage = target }
        place(d.entry, at: min(layout.pages[target].count, capacity - 1))
    }

    func dragEnded() {
        guard let d = drag else { return }
        flipTask?.cancel()
        flipDirection = 0
        mergeTask?.cancel()
        let target = mergeTarget
        pendingMerge = nil

        var l = layout
        var newFolder: UUID?
        var closeOpenFolder = false
        if let src = d.sourceFolder, d.extracted, let path = d.entry.appPath {
            if target == .folder(src) {
                l.remove(d.entry) // dropped back on its own folder
            } else {
                l.folders[src]?.apps.removeAll { $0 == path }
                if let t = target { l.merge(app: path, onto: t, newFolderName: suggestedFolderName(target: t, adding: path)) }
                l.dissolveIfNeeded(src)
            }
            closeOpenFolder = true
        } else if d.sourceFolder == nil, let t = target, let path = d.entry.appPath {
            let id = l.merge(app: path, onto: t, newFolderName: suggestedFolderName(target: t, adding: path))
            if case .app = t, d.companions.isEmpty { newFolder = id }
            if let id {
                // Multi-drag onto a folder target: apps join it, folders land right after it.
                for c in d.companions {
                    if let app = c.appPath { l.merge(app: app, onto: .folder(id), newFolderName: "") }
                }
                l.insert(d.companions.filter { $0.folderID != nil }, after: .folder(id), capacity: capacity)
            } else {
                l.insert(d.companions, after: d.entry, capacity: capacity)
            }
        } else if !d.companions.isEmpty {
            l.insert(d.companions, after: d.entry, capacity: capacity)
        }
        l.compact()
        if !d.companions.isEmpty { selected.removeAll() }

        suppressTapUntil = Date().addingTimeInterval(0.25)
        withAnimation(Self.reflow) {
            layout = l
            drag = nil
            mergeTarget = nil
            if closeOpenFolder { openFolder = nil }
            if let newFolder { openFolder = newFolder }
            currentPage = min(currentPage, max(0, l.pages.count - 1))
        }
        focus.token += 1
        scheduleSave()
        if let records = pendingScan {
            pendingScan = nil
            apply(records)
            let missing = iconsToLoad()
            if !missing.isEmpty { icons.merge(Self.loadIcons(missing, pixels: iconPixels)) { $1 } }
        }
    }

    /// Hiding mid-drag drops the item where it is; a hover that hasn't been released doesn't make a folder.
    func cancelPendingMerge() {
        mergeTask?.cancel()
        pendingMerge = nil
        mergeTarget = nil
    }

    // MARK: - Drag & drop (inside an open folder)

    func folderPanel(for id: UUID) -> FolderPanel {
        let n = max(1, layout.folders[id]?.apps.count ?? 1)
        let cols = max(3, min(gridSize.cols - 1, n))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let header: CGFloat = 70
        let pad = metrics.cell.width * 0.3
        let maxGridHeight = metrics.size.height * 0.75 - header - pad
        let scale = min(1, maxGridHeight / (CGFloat(rows) * metrics.cell.height))
        let cell = CGSize(width: metrics.cell.width * scale, height: metrics.cell.height * scale)
        let w = CGFloat(cols) * cell.width + pad * 2
        let h = header + CGFloat(rows) * cell.height + pad * 0.6
        let frame = CGRect(x: (metrics.size.width - w) / 2, y: (metrics.size.height - h) / 2, width: w, height: h)
        return FolderPanel(frame: frame, cols: cols, cell: cell, iconSize: metrics.iconSize * scale, header: header, pad: pad)
    }

    func folderDragChanged(_ path: String, folder: UUID, at loc: CGPoint, grabbedAt start: CGPoint? = nil,
                           iconCenter: CGPoint? = nil, iconSize: CGFloat = 0) {
        if let d = drag, d.extracted {
            dragChanged(d.entry, at: loc)
            return
        }
        if drag == nil {
            var state = DragState(entry: .app(path), location: loc, sourceFolder: folder)
            if let start, let iconCenter { state.grab = DragState.grab(at: start, iconCenter: iconCenter, iconSize: iconSize) }
            drag = state
        }
        drag?.location = loc
        let panel = folderPanel(for: folder)
        if !panel.frame.insetBy(dx: -20, dy: -20).contains(loc) {
            // Pulled out of the folder: it gets a live slot in the main grid from now on.
            drag?.extracted = true
            let pageCount = currentPage < layout.pages.count ? layout.pages[currentPage].count : 0
            let slot = min(metrics.slot(at: loc) ?? pageCount, pageCount)
            withAnimation(Self.reflow) {
                layout.insert(.app(path), page: currentPage, index: slot, capacity: capacity)
            }
            return
        }
        guard let idx = panel.slot(at: loc), var f = layout.folders[folder],
              let from = f.apps.firstIndex(of: path) else { return }
        let to = min(idx, f.apps.count - 1)
        guard from != to else { return }
        f.apps.remove(at: from)
        f.apps.insert(path, at: to)
        withAnimation(Self.reflow) { layout.folders[folder] = f }
    }
}
