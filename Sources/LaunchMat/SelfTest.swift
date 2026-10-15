import AppKit
import LaunchMatCore

/// `LaunchMat --selftest`: drives the real drag/drop code paths with synthetic pointer positions
/// against the installed apps (fresh layout, nothing is saved) and prints PASS/FAIL per scenario.
@MainActor
enum SelfTest {
    private static var failures = 0

    static func run(model: LaunchpadModel) -> Never {
        model.persistenceEnabled = false
        model.load(fresh: true, sync: true)
        model.metrics = GridMetrics(size: CGSize(width: 1512, height: 982), cols: model.gridSize.cols, rows: model.gridSize.rows)
        let m = model.metrics
        func page0() -> [Entry] { model.layout.pages[0] }
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        /// A point inside the slot but away from the icon's center (reorder zone).
        func gap(_ slot: Int) -> CGPoint { let c = m.cellCenter(slot); return CGPoint(x: c.x, y: c.y + m.cell.height * 0.42) }
        /// The left half of a slot, away from the icon: dropping there puts the item before whatever is in the slot.
        func before(_ slot: Int) -> CGPoint { let g = gap(slot); return CGPoint(x: g.x - m.cell.width * 0.3, y: g.y) }

        // 1. Reorder: drag slot 0 into slot 3.
        let a = page0()[0], b = page0()[1]
        model.dragChanged(a, at: m.iconCenter(0))
        model.dragChanged(a, at: gap(3))
        model.dragEnded()
        check("reorder slot 0 -> 3", page0()[3] == a && page0()[0] == b)

        // 2. Hover on another icon's center for > 0.35 s creates a folder in the target's slot.
        let x = page0()[0], y = page0()[1]
        model.dragChanged(x, at: m.iconCenter(0))
        model.dragChanged(x, at: m.iconCenter(1))
        wait(0.5)
        check("merge target highlighted", model.mergeTarget == y)
        model.dragChanged(x, at: m.iconCenter(1))
        model.dragEnded()
        guard case .folder(let fid)? = page0().first, let folder = model.layout.folders[fid] else {
            check("folder created", false)
            exit(1)
        }
        check("folder created with both apps", folder.apps == [y.appPath!, x.appPath!])
        check("new folder opens", model.openFolder == fid)

        // 3. A quick pass over an icon (< 0.35 s) must not merge.
        let p = page0()[1], q = page0()[2]
        model.openFolder = nil
        model.dragChanged(p, at: m.iconCenter(1))
        model.dragChanged(p, at: m.iconCenter(2))
        model.dragChanged(p, at: gap(5))
        wait(0.5)
        model.dragEnded()
        check("fast pass does not merge", model.mergeTarget == nil && model.layout.locate(q) != nil && model.layout.folders.count == 2)

        // 4. Drag an app out of the open folder onto the grid: folder (2 apps) dissolves.
        model.openFolder = fid
        let panel = model.folderPanel(for: fid)
        let leaving = folder.apps[1]
        model.folderDragChanged(leaving, folder: fid, at: panel.center(1))
        model.folderDragChanged(leaving, folder: fid, at: gap(m.cols * (m.rows - 1)))
        model.folderDragChanged(leaving, folder: fid, at: gap(m.cols * (m.rows - 1) + 1))
        model.dragEnded()
        check("extracted app is on the grid", model.layout.locate(.app(leaving)) != nil)
        check("one-app folder dissolved", model.layout.folders[fid] == nil && model.layout.locate(.app(folder.apps[0])) != nil)
        check("folder closed", model.openFolder == nil)

        // 5. Holding a dragged icon at the right edge flips to the next page.
        let r = page0()[2]
        model.dragChanged(r, at: m.iconCenter(2))
        model.dragChanged(r, at: CGPoint(x: m.size.width - 10, y: m.size.height / 2))
        wait(0.8)
        check("edge flip to page 2", model.currentPage == 1)
        model.dragChanged(r, at: before(0))
        model.dragEnded()
        check("dropped on page 2 slot 0", model.layout.locate(r).map { $0.page == 1 && $0.index == 0 } == true)

        // 6. Search + keyboard: Return launches the top result (verified without launching).
        model.query = "safari"
        check("search finds Safari first", model.results.first?.name.lowercased().contains("safari") == true)
        model.query = ""
        check("clearing search restores pages", model.currentPage == 1 && !model.isSearching)

        // 7. Multi-select drag: three selected apps travel together and land in order after the drop slot.
        model.go(to: 0)
        let s1 = page0()[4], s2 = page0()[6], s3 = page0()[8]
        model.selected = [s1, s2, s3]
        model.dragChanged(s2, at: m.iconCenter(6))
        check("companions lifted out while dragging", model.layout.locate(s1) == nil && model.layout.locate(s3) == nil)
        model.dragChanged(s2, at: before(0))
        model.dragEnded()
        check("multi-drop keeps order at slot 0", Array(page0().prefix(3)) == [s2, s1, s3])
        check("selection cleared after multi-drop", model.selected.isEmpty)

        // 8. Multi-drag onto an app's center makes one folder with all of them.
        let t1 = page0()[10], t2 = page0()[11], t3 = page0()[12], target = page0()[14]
        if [t1, t2, t3, target].allSatisfy({ $0.appPath != nil }) {
            model.selected = [t1, t2, t3]
            model.dragChanged(t1, at: m.iconCenter(10))
            let targetSlot = model.layout.locate(target)!.index
            model.dragChanged(t1, at: m.iconCenter(targetSlot))
            wait(0.5)
            model.dragChanged(t1, at: m.iconCenter(targetSlot))
            model.dragEnded()
            let fid = model.layout.folder(containing: t1.appPath!)
            check("multi-merge builds one folder", fid != nil && model.layout.folders[fid!]?.apps.count == 4)
            model.openFolder = nil
        } else {
            check("multi-merge fixture (slots 10-14 are apps)", false)
        }

        // 9. Batch actions from the context menu.
        let g = page0().filter { $0.appPath != nil }.suffix(3)
        model.selected = Set(g)
        model.groupSelected()
        let gid = model.layout.folder(containing: g.first!.appPath!)
        check("New Folder with selected apps", gid != nil && model.layout.folders[gid!]?.apps.count == 3)
        model.openFolder = nil
        let h = page0().filter { $0.appPath != nil }.prefix(2)
        model.selected = Set(h)
        model.hideSelected()
        check("Hide selected apps", h.allSatisfy { model.layout.hidden.contains($0.appPath!) })

        // 10. Uninstall eligibility: system apps never, App Store / third-party apps yes.
        let safari = model.apps.values.first { $0.bundleID == "com.apple.Safari" }
        let notes = model.apps.values.first { $0.bundleID == "com.apple.Notes" }
        let thirdParty = model.apps.values.first { $0.id.hasPrefix("/Applications/") && !$0.isApple }
        check("Safari / Notes not uninstallable", safari.map(Uninstaller.canUninstall) == false && notes.map(Uninstaller.canUninstall) == false)
        check("third-party app uninstallable", thirdParty.map(Uninstaller.canUninstall) == true)
        if let tp = thirdParty {
            print("      related files for \(tp.name): \(Uninstaller.relatedFiles(for: tp, installed: Array(model.apps.values)).count)")
        }

        // 11. Import the real pre-macOS-26 Launchpad database if this Mac has one (read-only copy).
        if let path = LegacyLaunchpad.defaultPath, FileManager.default.fileExists(atPath: path) {
            do {
                let pages = try LegacyLaunchpad.read(path: path)
                let placed = model.applyImported(pages)
                let folders = model.layout.folders.values.map(\.name).sorted()
                print("      imported \(pages.count) legacy pages -> \(placed) apps placed, folders: \(folders)")
                check("legacy import placed apps", placed > 0 && !model.layout.isEmpty)
            } catch {
                check("legacy import (\(error))", false)
            }
        } else {
            print("      (no legacy Launchpad database on this Mac — import skipped)")
        }

        // 12. Every app is placed exactly once (hidden ones excluded).
        let placed = model.layout.orderedApps
        let visible = Set(model.apps.keys).subtracting(model.layout.hidden)
        check("no duplicates / nothing lost", Set(placed).count == placed.count && Set(placed) == visible)

        // 13. Screens change while the grid is open (spec 12).
        screenChanges(model: model)

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// Made-up screens far from any real one: the window is never seen and the app is never activated. The screens
    /// change by swapping the list the window controller reads, then posting the system's notification.
    private static func screenChanges(model: LaunchpadModel) {
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        let far: CGFloat = 40_000
        func screen(_ id: CGDirectDisplayID, x: CGFloat, _ w: CGFloat, _ h: CGFloat) -> LaunchWindowController.Display {
            let frame = CGRect(x: far + x, y: far, width: w, height: h)
            return .init(id: id, frame: frame, visibleFrame: CGRect(x: frame.minX, y: frame.minY, width: w, height: h - 25))
        }
        var screens = [screen(1, x: 0, 1512, 982), screen(2, x: 1512, 1920, 1080)]
        let controller = LaunchWindowController(model: model)
        controller.displays = { screens }
        controller.activeDisplay = { 2 }
        controller.pointer = { CGPoint(x: far + 2000, y: far + 500) } // on screen 2
        controller.showOn = { .cursor }
        controller.activatesApp = false
        func settle() {
            wait(0.5)
            controller.window.contentView?.layoutSubtreeIfNeeded()
            wait(0.2)
        }
        func changed() {
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
            settle()
        }
        func fits(_ d: LaunchWindowController.Display) -> Bool {
            controller.window.frame == d.frame && model.metrics.size == d.frame.size
        }

        controller.show()
        settle()
        check("screens: opens on the pointer's screen, grid sized to it", controller.isVisible && fits(screens[1]))

        screens[1] = screen(2, x: 1512, 2560, 1440)
        changed()
        check("screens: new resolution, same count: stays open, window and grid fit the new frame",
              controller.isVisible && fits(screens[1]))

        screens.append(screen(3, x: 4072, 1440, 900))
        changed()
        wait(0.5)
        check("screens: one screen more: the open grid closes and doesn't reopen", !controller.isVisible)

        controller.show()
        settle()
        screens.remove(at: 1)
        changed()
        check("screens: the grid's own screen removed: it closes", !controller.isVisible)

        controller.show() // the pointer is now on no screen, the active one is gone: the primary one
        settle()
        check("screens: the next open falls back to the primary screen", controller.isVisible && fits(screens[0]))
        controller.hide()
        wait(0.5)
    }

    private static func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)")
    }
}
