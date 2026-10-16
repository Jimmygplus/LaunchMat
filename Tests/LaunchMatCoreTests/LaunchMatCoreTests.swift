import XCTest
@testable import LaunchMatCore

final class LayoutTests: XCTestCase {
    func testInsertIntoFullPageCascadesOverflow() {
        var l = PadLayout(pages: [[.app("a"), .app("b")], [.app("c"), .app("d")]])
        l.insert(.app("x"), page: 0, index: 0, capacity: 2)
        XCTAssertEqual(l.pages, [[.app("x"), .app("a")], [.app("b"), .app("c")], [.app("d")]])
    }

    func testMoveWithinPage() {
        var l = PadLayout(pages: [[.app("a"), .app("b"), .app("c")]])
        l.move(.app("a"), page: 0, index: 2, capacity: 4)
        XCTAssertEqual(l.pages, [[.app("b"), .app("c"), .app("a")]])
    }

    func testMoveAcrossPagesLeavesHoleAndOverflows() {
        var l = PadLayout(pages: [[.app("a"), .app("b")], [.app("c"), .app("d")]])
        l.move(.app("a"), page: 1, index: 1, capacity: 2)
        XCTAssertEqual(l.pages, [[.app("b")], [.app("c"), .app("a")], [.app("d")]])
    }

    func testMergeTwoAppsCreatesFolderInTargetSlot() {
        var l = PadLayout(pages: [[.app("a"), .app("b"), .app("c")]])
        let id = l.merge(app: "c", onto: .app("a"), newFolderName: "Work")!
        XCTAssertEqual(l.pages, [[.folder(id), .app("b")]])
        XCTAssertEqual(l.folders[id]?.apps, ["a", "c"])
        XCTAssertEqual(l.folders[id]?.name, "Work")
    }

    func testMergeIntoExistingFolder() {
        var l = PadLayout(pages: [[.app("a"), .app("b"), .app("c")]])
        let id = l.merge(app: "b", onto: .app("a"), newFolderName: "F")!
        XCTAssertEqual(l.merge(app: "c", onto: .folder(id), newFolderName: "ignored"), id)
        XCTAssertEqual(l.pages, [[.folder(id)]])
        XCTAssertEqual(l.folders[id]?.apps, ["a", "b", "c"])
    }

    func testMergeOntoMissingTargetKeepsDraggedApp() {
        var l = PadLayout(pages: [[.app("a")]])
        XCTAssertNil(l.merge(app: "a", onto: .app("zzz"), newFolderName: "F"))
        XCTAssertEqual(l.pages, [[.app("a")]])
    }

    func testFolderDissolvesToLastApp() {
        var l = PadLayout(pages: [[.app("a"), .app("b")]])
        let id = l.merge(app: "b", onto: .app("a"), newFolderName: "F")!
        l.removeApp("b", fromFolder: id)
        XCTAssertEqual(l.pages, [[.app("a")]])
        XCTAssertNil(l.folders[id])
    }

    func testHideRemovesFromFolderAndGrid() {
        var l = PadLayout(pages: [[.app("a"), .app("b"), .app("c")]])
        let id = l.merge(app: "b", onto: .app("a"), newFolderName: "F")!
        l.hide("a")
        l.hide("c")
        XCTAssertEqual(l.pages, [[.app("b")]])
        XCTAssertNil(l.folders[id])
        XCTAssertEqual(l.hidden, ["a", "c"])
    }

    func testReconcileDropsMissingAppendsNewAndRepairsDuplicates() {
        var l = PadLayout(pages: [[.app("a"), .app("gone"), .app("b")]])
        let id = l.merge(app: "b", onto: .app("a"), newFolderName: "F")!
        l.pages[0].append(.app("a")) // duplicate of a folder member
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        l.reconcile(installed: ["a", "b", "new1", "new2"], capacity: 2, now: t0)
        XCTAssertNotNil(l.locate(.app("gone")), "missing app keeps its slot during the grace period")
        l.reconcile(installed: ["a", "b", "new1", "new2"], capacity: 2, now: t0 + PadLayout.missingGrace + 1)
        XCTAssertEqual(l.pages, [[.folder(id)], [.app("new1"), .app("new2")]], "pruned slot leaves a hole")
        XCTAssertEqual(l.folders[id]?.apps, ["a", "b"])
    }

    func testCompactKeepsOnePage() {
        var l = PadLayout(pages: [[], [.app("a")], []])
        l.compact()
        XCTAssertEqual(l.pages, [[.app("a")]])
        var empty = PadLayout(pages: [[], []])
        empty.compact()
        XCTAssertEqual(empty.pages, [[]])
    }

    func testCodableRoundTrip() throws {
        var l = PadLayout(pages: [[.app("/Applications/A.app"), .app("/Applications/B.app")]])
        l.merge(app: "/Applications/B.app", onto: .app("/Applications/A.app"), newFolderName: "F")
        l.hidden = ["/Applications/C.app"]
        let data = try JSONEncoder().encode(l)
        XCTAssertEqual(try JSONDecoder().decode(PadLayout.self, from: data), l)
    }
}

final class SearchTests: XCTestCase {
    func testLatinFullAndAbbr() {
        let r = Search.fullAndAbbr("Visual Studio Code")
        XCTAssertEqual(r.full, "visualstudiocode")
        XCTAssertEqual(r.abbr, "vsc")
    }

    func testChineseBecomesPinyin() {
        let r = Search.fullAndAbbr("微信")
        XCTAssertEqual(r.full, "weixin")
        XCTAssertEqual(r.abbr, "wx")
    }

    func testMixedScript() {
        let r = Search.fullAndAbbr("QQ邮箱")
        XCTAssertEqual(r.full, "qqyouxiang")
        XCTAssertEqual(r.abbr, "qyx")
    }

    func testDiacriticsFold() {
        XCTAssertEqual(Search.fullAndAbbr("Café Über").full, "cafeuber")
        XCTAssertEqual(Search.normalizedQuery("  CAFÉ "), "cafe")
    }

    struct App { let name: String; let alt: String; let order: Int }

    private func ranked(_ apps: [App], _ q: String) -> [String] {
        Search.rank(apps, query: q, keys: { Search.keys(name: $0.name, altName: $0.alt) }, order: { $0.order }).map(\.name)
    }

    func testPrefixBeatsSubstringAndTiesKeepOrder() {
        let apps = [
            App(name: "Visual Studio Code", alt: "Code", order: 0),
            App(name: "Xcode", alt: "Xcode", order: 1),
            App(name: "Code Runner", alt: "Code Runner", order: 2),
        ]
        // "Code Runner" name prefix (0) < VS Code alt-name prefix (1) < Xcode substring (20)
        XCTAssertEqual(ranked(apps, "code"), ["Code Runner", "Visual Studio Code", "Xcode"])
    }

    func testAbbreviationAndPinyinQueries() {
        let apps = [
            App(name: "Visual Studio Code", alt: "Code", order: 0),
            App(name: "微信", alt: "WeChat", order: 1),
            App(name: "日历", alt: "Calendar", order: 2),
        ]
        XCTAssertEqual(ranked(apps, "vsc"), ["Visual Studio Code"])
        XCTAssertEqual(ranked(apps, "wx"), ["微信"])
        XCTAssertEqual(ranked(apps, "wechat"), ["微信"])
        XCTAssertEqual(ranked(apps, "rili"), ["日历"])
        XCTAssertEqual(ranked(apps, "cal"), ["日历"])
        XCTAssertEqual(ranked(apps, "zzz"), [])
    }

    /// On an English Mac apps are named in English; their Chinese names come from the bundle's localizations.
    func testChineseNamesFoundOnEnglishSystem() {
        let apps: [(name: String, other: [String])] = [("WeChat", ["微信"]), ("Notes", ["备忘录"]), ("Weather", [])]
        let rank = { (q: String) in
            Search.rank(apps, query: q, keys: { Search.keys(name: $0.name, altName: $0.name, otherNames: $0.other) },
                        order: { a in apps.firstIndex { $0.name == a.name }! }).map(\.name)
        }
        XCTAssertEqual(rank("wx"), ["WeChat"])
        XCTAssertEqual(rank("weixin"), ["WeChat"])
        XCTAssertEqual(rank("微信"), ["WeChat"])
        XCTAssertEqual(rank("bwl"), ["Notes"])
        XCTAssertEqual(rank("we"), ["WeChat", "Weather"]) // English names still come first
    }

    func testLocalizedNamesFromStringsAndLoctable() throws {
        let fm = FileManager.default
        let res = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: res) }
        try fm.createDirectory(at: res.appendingPathComponent("zh-Hans.lproj"), withIntermediateDirectories: true)
        try fm.createDirectory(at: res.appendingPathComponent("en.lproj"), withIntermediateDirectories: true)
        try "\"CFBundleDisplayName\" = \"微信\";\n\"CFBundleName\" = \"微信\";\n"
            .write(to: res.appendingPathComponent("zh-Hans.lproj/InfoPlist.strings"), atomically: true, encoding: .utf8)
        try "\"CFBundleDisplayName\" = \"WeChat\";\n"
            .write(to: res.appendingPathComponent("en.lproj/InfoPlist.strings"), atomically: true, encoding: .utf8)
        XCTAssertEqual(LocalizedNames.chinese(resources: res), ["微信"])

        let table: NSDictionary = ["zh_CN": ["CFBundleDisplayName": "备忘录"], "zh_TW": ["CFBundleName": "備忘錄"],
                                   "en": ["CFBundleDisplayName": "Notes"]]
        let other = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: other) }
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertTrue(table.write(to: other.appendingPathComponent("InfoPlist.loctable"), atomically: true))
        XCTAssertEqual(LocalizedNames.chinese(resources: other), ["备忘录", "備忘錄"])
        XCTAssertEqual(LocalizedNames.chinese(resources: fm.temporaryDirectory.appendingPathComponent("nope")), [])
    }
}

final class MultiSelectTests: XCTestCase {
    func testInsertAfterKeepsOrderAcrossPageBoundary() {
        var l = PadLayout(pages: [[.app("a"), .app("b")], [.app("c")]])
        l.insert([.app("x"), .app("y")], after: .app("b"), capacity: 2)
        XCTAssertEqual(l.pages.flatMap { $0 }, [.app("a"), .app("b"), .app("x"), .app("y"), .app("c")])
        XCTAssertTrue(l.pages.allSatisfy { $0.count <= 2 })
    }

    func testGroupFromGridAndFolder() {
        var l = PadLayout(pages: [[.app("a"), .app("b"), .app("c"), .app("d")]])
        let f1 = l.merge(app: "d", onto: .app("c"), newFolderName: "F1")!
        let g = l.group(apps: ["b", "a", "d"], name: "G", capacity: 10)!
        XCTAssertEqual(l.folders[g]?.apps, ["b", "a", "d"])
        XCTAssertNil(l.folders[f1], "F1 had c,d; losing d dissolves it to c")
        XCTAssertEqual(l.pages, [[.folder(g), .app("c")]])
    }
}

final class LegacyLaunchpadTests: XCTestCase {
    func testReadsPagesFoldersAndSkipsHoldingPage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("db").path
        let sql = """
        CREATE TABLE items (rowid INTEGER PRIMARY KEY, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR);
        CREATE TABLE groups (item_id INTEGER PRIMARY KEY, category_id INTEGER, title VARCHAR);
        INSERT INTO items VALUES (1,'ROOTPAGE',0,1,0,0),(2,'HOLDINGPAGE',0,3,1,0),
          (10,'p1',0,3,1,1),(11,'p2',0,3,1,2),
          (20,'a',0,4,10,0),(21,'f',0,2,10,1),(22,'fp',0,3,21,0),(23,'b',0,4,22,0),(24,'c',0,4,22,1),
          (25,'d',0,4,11,0),(26,'held',0,4,2,0);
        INSERT INTO apps VALUES (20,'A','com.a',NULL),(23,'B','com.b',NULL),(24,'C','com.c',NULL),(25,'D','com.d',NULL),(26,'H','com.h',NULL);
        INSERT INTO groups VALUES (21,0,'Tools');
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [path, sql]
        try p.run()
        p.waitUntilExit()

        let pages = try LegacyLaunchpad.read(path: path)
        let a = LegacyLaunchpad.App.init(bundleID:title:)
        XCTAssertEqual(pages, [
            [.app(a("com.a", "A")), .folder(title: "Tools", apps: [a("com.b", "B"), a("com.c", "C")])],
            [.app(a("com.d", "D"))],
        ])

        // com.c is not installed: the folder collapses to its last app.
        let installed = ["com.a": "/A.app", "com.b": "/B.app", "com.d": "/D.app"]
        let layout = LegacyLaunchpad.layout(from: pages, resolve: { installed[$0] }, capacity: 35)
        XCTAssertEqual(layout.pages, [[.app("/A.app"), .app("/B.app")], [.app("/D.app")]])
        XCTAssertTrue(layout.folders.isEmpty)
    }
}

final class GestureTests: XCTestCase {
    func testScreenChoiceAndItsFallbacks() {
        // Primary 1440 × 900 with the menu bar; a 1920 × 1080 screen to its right with the Dock at the bottom.
        let primary = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let dell = ScreenGeometry(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 1440, y: 70, width: 1920, height: 985))
        let screens = [primary, dell]
        let onDell = CGPoint(x: 2000, y: 500), nowhere = CGPoint(x: -500, y: -500)
        XCTAssertEqual(ScreenChoice.pick(.main, screens: screens, active: 1, cursor: onDell, dock: .bottom), 0)
        XCTAssertEqual(ScreenChoice.pick(.active, screens: screens, active: 1, cursor: .zero, dock: .bottom), 1)
        XCTAssertEqual(ScreenChoice.pick(.active, screens: screens, active: nil, cursor: .zero, dock: .bottom), 0)
        XCTAssertEqual(ScreenChoice.pick(.cursor, screens: screens, active: 0, cursor: onDell, dock: .bottom), 1)
        XCTAssertEqual(ScreenChoice.pick(.cursor, screens: screens, active: 1, cursor: nowhere, dock: .bottom), 1, "no screen under the pointer: the active one")
        XCTAssertEqual(ScreenChoice.pick(.cursor, screens: screens, active: 7, cursor: nowhere, dock: .bottom), 0, "then the primary one")
        XCTAssertEqual(ScreenChoice.pick(.dock, screens: screens, active: 0, cursor: .zero, dock: .bottom), 1)
        XCTAssertEqual(ScreenChoice.pick(.dock, screens: screens, active: 1, cursor: .zero, dock: .left), 1, "Dock not found on the left: the active one")
        XCTAssertNil(ScreenChoice.pick(.cursor, screens: [], active: nil, cursor: .zero, dock: .bottom))
        // A Dock on the left of the primary screen; the menu bar strip alone doesn't count.
        let leftDock = ScreenGeometry(frame: primary.frame, visibleFrame: CGRect(x: 64, y: 0, width: 1376, height: 875))
        XCTAssertEqual(ScreenChoice.dockScreen([leftDock, dell], edge: .left), 0)
        XCTAssertNil(ScreenChoice.dockScreen([primary], edge: .bottom))
    }

    func testGuardedFoldersAreJudgedByPathAlone() {
        let home = "/Users/someone"
        for path in ["/Users/someone/Downloads/Some.app", "/Users/someone/Desktop/a.app",
                     "/Users/someone/Documents/apps/b.app", "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/c.app",
                     "/Users/someone/Library/CloudStorage/Dropbox/d.app", "/Users/someone/Library/Containers/x/e.app",
                     "/Volumes/USB/f.app", "/Users/someone/Applications/../Downloads/g.app"] {
            XCTAssertTrue(GuardedFolders.contains(path, home: home), path)
        }
        for path in ["/Applications/Safari.app", "/System/Cryptexes/App/System/Applications/Safari.app",
                     "/Users/someone/Applications/h.app", "/Users/someone/DownloadsArchive/i.app",
                     "/Users/other/opt/anaconda3/Anaconda-Navigator.app"] {
            XCTAssertFalse(GuardedFolders.contains(path, home: home), path)
        }
    }

    func testHotCornerDwellAndRearm() {
        var t = HotCornerTrigger(corner: .topLeft, dwell: 0.1)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let corner = CGPoint(x: 0, y: 799)
        XCTAssertFalse(t.update(point: corner, screen: screen, time: 0))
        XCTAssertFalse(t.update(point: corner, screen: screen, time: 0.05))
        XCTAssertTrue(t.update(point: corner, screen: screen, time: 0.12))
        XCTAssertFalse(t.update(point: corner, screen: screen, time: 0.5), "fires once per visit")
        XCTAssertFalse(t.update(point: CGPoint(x: 500, y: 400), screen: screen, time: 0.6))
        XCTAssertFalse(t.update(point: corner, screen: screen, time: 0.7))
        XCTAssertTrue(t.update(point: corner, screen: screen, time: 0.85))
        XCTAssertFalse(HotCorner.bottomRight.contains(corner, in: screen))
    }

    private func ring(_ r: CGFloat, n: Int) -> [CGPoint] {
        (0..<n).map { i in
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            return CGPoint(x: 0.5 + r * cos(a), y: 0.5 + r * sin(a))
        }
    }

    func testPinchInOnceWithFourFingers() {
        var d = PinchDetector(fingers: 4...5)
        XCTAssertNil(d.update(ring(0.3, n: 4)))
        XCTAssertNil(d.update(ring(0.25, n: 4)))
        XCTAssertEqual(d.update(ring(0.15, n: 4)), .pinchIn)
        XCTAssertNil(d.update(ring(0.1, n: 4)), "one gesture per touch sequence")
        XCTAssertNil(d.update([]))
        XCTAssertNil(d.update(ring(0.1, n: 4)))
        XCTAssertEqual(d.update(ring(0.2, n: 4)), .pinchOut)
    }

    func testWrongFingerCountIgnored() {
        var d = PinchDetector(fingers: 3...3)
        XCTAssertNil(d.update(ring(0.3, n: 2)))
        XCTAssertNil(d.update(ring(0.1, n: 2)))
        XCTAssertNil(d.update(ring(0.3, n: 4)))
        XCTAssertNil(d.update(ring(0.1, n: 4)))
    }
}

final class RelatedFilesTests: XCTestCase {
    func testFindsOnlyExistingExactMatches() throws {
        let lib = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        for p in ["Application Support/com.x.app", "Caches/com.x.app", "Application Support/XApp",
                  "Preferences/ByHost", "Caches/com.x.application.other", "Group Containers/TEAM.com.x.app"] {
            try fm.createDirectory(at: lib.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        fm.createFile(atPath: lib.appendingPathComponent("Preferences/com.x.app.plist").path, contents: Data())
        fm.createFile(atPath: lib.appendingPathComponent("Preferences/ByHost/com.x.app.ABC.plist").path, contents: Data())
        let found = Set(RelatedFiles.find(bundleID: "com.x.app", appName: "XApp", library: lib)
            .map { String($0.path.dropFirst(lib.path.count + 1)) })
        XCTAssertEqual(found, ["Application Support/com.x.app", "Caches/com.x.app", "Application Support/XApp",
                               "Preferences/com.x.app.plist", "Preferences/ByHost/com.x.app.ABC.plist",
                               "Group Containers/TEAM.com.x.app"])
    }
}


final class RobustnessTests: XCTestCase {
    func testBrieflyMissingAppKeepsFolderAndHiddenState() {
        var l = PadLayout(pages: [[.app("a"), .app("b"), .app("c")]])
        let id = l.merge(app: "b", onto: .app("a"), newFolderName: "Keep")!
        l.hide("c")
        let t = Date()
        l.reconcile(installed: ["a"], capacity: 10, now: t)            // b and c vanish (updating)
        l.reconcile(installed: ["a", "b", "c"], capacity: 10, now: t + 60) // and come back
        XCTAssertEqual(l.folders[id]?.apps, ["a", "b"])
        XCTAssertEqual(l.folders[id]?.name, "Keep")
        XCTAssertTrue(l.hidden.contains("c"))
        XCTAssertTrue(l.missingSince.isEmpty)
    }

    func testReconcileDropsRepeatedFolderEntries() {
        var l = PadLayout(pages: [[.app("a"), .app("b")]])
        let id = l.merge(app: "b", onto: .app("a"), newFolderName: "F")!
        l.pages[0].append(.folder(id))
        l.reconcile(installed: ["a", "b"], capacity: 10)
        XCTAssertEqual(l.pages, [[.folder(id)]])
    }

    func testFileFormatIsReadableAndTolerant() throws {
        var l = PadLayout(pages: [[.app("/Applications/A.app"), .app("/Applications/B.app")]])
        let id = l.merge(app: "/Applications/B.app", onto: .app("/Applications/A.app"), newFolderName: "F")!
        let json = String(data: try JSONEncoder().encode(l), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"folder:\(id.uuidString)\""), json)
        XCTAssertTrue(json.contains("\"version\":1"), json)
        // Hand-written file with only pages: other keys default.
        let minimal = #"{"pages":[["app:/Applications/A.app"]]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PadLayout.self, from: minimal)
        XCTAssertEqual(decoded.pages, [[.app("/Applications/A.app")]])
        XCTAssertTrue(decoded.hidden.isEmpty && decoded.folders.isEmpty)
    }

    func testRelatedFilesRejectsHostileBundleIDsAndSymlinks() throws {
        let fm = FileManager.default
        let lib = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for p in ["Application Support/com.x.app", "Caches", "Logs", "LaunchAgents"] {
            try fm.createDirectory(at: lib.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        fm.createFile(atPath: lib.appendingPathComponent("LaunchAgents/com.x.appmanager.helper.plist").path, contents: Data())
        fm.createFile(atPath: lib.appendingPathComponent("LaunchAgents/com.x.app.helper.plist").path, contents: Data())
        try fm.createSymbolicLink(at: lib.appendingPathComponent("Caches/com.x.app"),
                                  withDestinationURL: fm.homeDirectoryForCurrentUser)
        for bad in ["..", ".", "../../Documents", "com..x", ""] {
            XCTAssertEqual(RelatedFiles.find(bundleID: bad, appName: "..", library: lib), [], bad)
        }
        let found = RelatedFiles.find(bundleID: "com.x.app", appName: "X", library: lib).map(\.lastPathComponent)
        XCTAssertEqual(Set(found), ["com.x.app", "com.x.app.helper.plist"], "symlinked cache and look-alike agent excluded")
    }
}

final class RenameMigrationTests: XCTestCase {
    private let fm = FileManager.default
    private var support: URL!
    private var suites: [String] = []

    override func setUp() {
        support = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! fm.createDirectory(at: support.appendingPathComponent("LaunchGrid"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: support)
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
    }

    private func defaults() -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func write(_ text: String, _ path: String) {
        try! Data(text.utf8).write(to: support.appendingPathComponent(path))
    }

    func testCopiesLayoutAndKeepsTheOldOne() {
        write(#"{"pages":[]}"#, "LaunchGrid/layout.json")
        write("x", "LaunchGrid/layout.corrupt-1.json")
        XCTAssertTrue(RenameMigration.migrateFiles(from: support.appendingPathComponent("LaunchGrid"),
                                                   to: support.appendingPathComponent("LaunchMat")))
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("LaunchMat/layout.json"), encoding: .utf8), #"{"pages":[]}"#)
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("LaunchMat/layout.corrupt-1.json").path))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("LaunchGrid/layout.json").path))
    }

    func testNeverOverwritesAnExistingNewLayout() {
        write("old", "LaunchGrid/layout.json")
        try! fm.createDirectory(at: support.appendingPathComponent("LaunchMat"), withIntermediateDirectories: true)
        write("new", "LaunchMat/layout.json")
        XCTAssertFalse(RenameMigration.migrateFiles(from: support.appendingPathComponent("LaunchGrid"),
                                                    to: support.appendingPathComponent("LaunchMat")))
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("LaunchMat/layout.json"), encoding: .utf8), "new")
    }

    func testSkipsSymlinkedLayout() {
        write("secret", "elsewhere.json")
        try! fm.createSymbolicLink(at: support.appendingPathComponent("LaunchGrid/layout.json"),
                                   withDestinationURL: support.appendingPathComponent("elsewhere.json"))
        XCTAssertFalse(RenameMigration.migrateFiles(from: support.appendingPathComponent("LaunchGrid"),
                                                    to: support.appendingPathComponent("LaunchMat")))
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("LaunchMat/layout.json").path))
    }

    func testSettingsCopyOnlyMissingKeys() {
        let old = defaults(), new = defaults()
        old.set(8, forKey: "gridCols")
        old.set("topLeft", forKey: "hotCorner")
        old.set("unrelated", forKey: "somethingElse")
        new.set("off", forKey: "hotCorner")
        XCTAssertEqual(RenameMigration.migrateSettings(from: old, to: new), ["gridCols"])
        XCTAssertEqual(new.integer(forKey: "gridCols"), 8)
        XCTAssertEqual(new.string(forKey: "hotCorner"), "off")
        XCTAssertNil(new.object(forKey: "somethingElse"))
    }

    func testRunsOnlyOnce() {
        write("old", "LaunchGrid/layout.json")
        let new = defaults()
        XCTAssertTrue(RenameMigration.runOnce(supportDir: support, newName: "LaunchMat", defaults: new, oldDefaults: nil))
        try! fm.removeItem(at: support.appendingPathComponent("LaunchMat/layout.json"))
        XCTAssertFalse(RenameMigration.runOnce(supportDir: support, newName: "LaunchMat", defaults: new, oldDefaults: nil))
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("LaunchMat/layout.json").path))
    }
}

final class PagingTests: XCTestCase {
    func testFollowIsOneToOneThenResists() {
        // 1512 pt wide: the 1:1 part is clamped to 72 pt.
        XCTAssertEqual(Paging.follow(40, width: 1512), 40)
        XCTAssertEqual(Paging.follow(-72, width: 1512), -72)
        XCTAssertEqual(Paging.follow(252, width: 1512), 72 + 180 * 180 / 360, accuracy: 0.001)
        XCTAssertLessThan(Paging.follow(5000, width: 1512), 72 + 180)
        XCTAssertEqual(Paging.follow(-252, width: 1512), -Paging.follow(252, width: 1512))
        // Narrow screens keep at least 48 pt of 1:1 movement.
        XCTAssertEqual(Paging.follow(48, width: 400), 48)
    }

    func testTurnNeedsTheThresholdUnlessSettling() {
        XCTAssertEqual(Paging.turn(offset: -49, threshold: 50, settling: false), 0)
        XCTAssertEqual(Paging.turn(offset: -51, threshold: 50, settling: false), 1)
        XCTAssertEqual(Paging.turn(offset: 51, threshold: 50, settling: false), -1)
        XCTAssertEqual(Paging.turn(offset: -11, threshold: 10, settling: false), 1)
        XCTAssertEqual(Paging.turn(offset: -5, threshold: 50, settling: true), 1)
        XCTAssertEqual(Paging.turn(offset: 0, threshold: 50, settling: true), 0)
    }
}

final class MenuActionTests: XCTestCase {
    func testNamesSurviveCodingAndOldFilesLoad() throws {
        var l = PadLayout(pages: [[.app("/A.app")]])
        l.names["/A.app"] = "Mail (work)"
        let data = try JSONEncoder().encode(l)
        XCTAssertEqual(try JSONDecoder().decode(PadLayout.self, from: data).names, ["/A.app": "Mail (work)"])
        let old = Data(#"{"version":1,"pages":[["app:/A.app"]]}"#.utf8)
        XCTAssertEqual((try? JSONDecoder().decode(PadLayout.self, from: old))?.names ?? ["x": "y"], [:])
    }

    func testMoveToPageAppendsAndCascades() {
        var l = PadLayout(pages: [[.app("a"), .app("b")], [.app("c"), .app("d")]])
        l.moveToPage(.app("a"), page: 1, capacity: 2)
        XCTAssertEqual(l.pages, [[.app("b")], [.app("c"), .app("d")], [.app("a")]])
        l.moveToPage(.app("b"), page: 4, capacity: 2)
        XCTAssertEqual(l.locate(.app("b"))?.page, 4)
    }

    func testMoveAppIntoAndBetweenFolders() {
        var l = PadLayout(pages: [[.app("a"), .app("b"), .app("c"), .app("d")]])
        let f = l.merge(app: "b", onto: .app("a"), newFolderName: "F")!
        let g = l.merge(app: "d", onto: .app("c"), newFolderName: "G")!
        l.moveApp("c", toFolder: f)
        XCTAssertEqual(l.folders[f]?.apps, ["a", "b", "c"])
        XCTAssertNil(l.folders[g], "a folder left with one app dissolves")
        XCTAssertNotNil(l.locate(.app("d")))
    }
}
