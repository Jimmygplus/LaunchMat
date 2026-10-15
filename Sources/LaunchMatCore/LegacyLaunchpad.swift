import Foundation
import SQLite3

/// Reads the pre-macOS-26 Launchpad database (`$DARWIN_USER_DIR/com.apple.dock.launchpad/db/db`).
///
/// Schema: `items(rowid, uuid, flags, type, parent_id, ordering)` forms a tree:
/// ROOTPAGE (type 1) -> pages (type 3) -> apps (type 4) | folders (type 2) -> folder pages (type 3) -> apps.
/// `apps(item_id, title, bundleid, …)` and `groups(item_id, category_id, title)` hold the payload.
public enum LegacyLaunchpad {
    public struct App: Equatable, Sendable {
        public let bundleID: String
        public let title: String
        public init(bundleID: String, title: String) { self.bundleID = bundleID; self.title = title }
    }

    public enum Item: Equatable, Sendable {
        case app(App)
        case folder(title: String, apps: [App])
    }

    public enum ReadError: Error, CustomStringConvertible {
        case notFound(String)
        case sqlite(String)

        public var description: String {
            switch self {
            case .notFound(let path): return "Launchpad database not found at \(path)"
            case .sqlite(let message): return "Could not read the Launchpad database: \(message)"
            }
        }
    }

    public static var defaultPath: String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buf, buf.count) > 0 else { return nil }
        return String(cString: buf) + "com.apple.dock.launchpad/db/db"
    }

    /// Pages of items in display order. The database (and its WAL) is copied first so Dock's file is never touched.
    public static func read(path: String) throws -> [[Item]] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw ReadError.notFound(path) }
        let tmp = fm.temporaryDirectory.appendingPathComponent("launchmat-import-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("db")
        try fm.copyItem(atPath: path, toPath: copy.path)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try? fm.copyItem(atPath: path + suffix, toPath: copy.path + suffix)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw ReadError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        struct Row { let id: Int64; let uuid: String; let type: Int; let parent: Int64; let ordering: Int }
        var rows: [Row] = []
        var apps: [Int64: App] = [:]
        var groups: [Int64: String] = [:]

        try query(db, "SELECT rowid, IFNULL(uuid,''), type, parent_id, ordering FROM items") { s in
            rows.append(Row(id: sqlite3_column_int64(s, 0), uuid: text(s, 1), type: Int(sqlite3_column_int(s, 2)),
                            parent: sqlite3_column_int64(s, 3), ordering: Int(sqlite3_column_int(s, 4))))
        }
        try query(db, "SELECT item_id, IFNULL(title,''), IFNULL(bundleid,'') FROM apps") { s in
            let bundle = text(s, 2)
            if !bundle.isEmpty { apps[sqlite3_column_int64(s, 0)] = App(bundleID: bundle, title: text(s, 1)) }
        }
        try query(db, "SELECT item_id, IFNULL(title,'') FROM groups") { s in
            groups[sqlite3_column_int64(s, 0)] = text(s, 1)
        }

        var children: [Int64: [Row]] = [:]
        for r in rows { children[r.parent, default: []].append(r) }
        for k in children.keys { children[k]!.sort { $0.ordering < $1.ordering } }
        let root = rows.first { $0.uuid == "ROOTPAGE" }?.id ?? 1

        func appsIn(folder: Int64) -> [App] {
            (children[folder] ?? []).filter { $0.type == 3 }.flatMap { page in
                (children[page.id] ?? []).filter { $0.type == 4 }.compactMap { apps[$0.id] }
            }
        }

        // HOLDINGPAGE* rows are pages too but hold apps that are not placed yet.
        return (children[root] ?? []).filter { $0.type == 3 && !$0.uuid.hasPrefix("HOLDINGPAGE") }.map { page in
            (children[page.id] ?? []).compactMap { child -> Item? in
                switch child.type {
                case 4: return apps[child.id].map(Item.app)
                case 2: return .folder(title: groups[child.id] ?? "", apps: appsIn(folder: child.id))
                default: return nil
                }
            }
        }
    }

    /// Converts legacy pages into a layout. `resolve` maps a bundle ID to an installed app path (nil = skip).
    public static func layout(from pages: [[Item]], resolve: (String) -> String?, capacity: Int) -> PadLayout {
        var layout = PadLayout(pages: [])
        var used = Set<String>()
        func take(_ app: App) -> String? {
            guard let path = resolve(app.bundleID), used.insert(path).inserted else { return nil }
            return path
        }
        for page in pages {
            var entries: [Entry] = []
            for item in page {
                switch item {
                case .app(let app):
                    if let path = take(app) { entries.append(.app(path)) }
                case .folder(let title, let apps):
                    let paths = apps.compactMap(take)
                    if paths.count == 1 {
                        entries.append(.app(paths[0]))
                    } else if paths.count > 1 {
                        let folder = Folder(name: title.isEmpty ? "Folder" : title, apps: paths)
                        layout.folders[folder.id] = folder
                        entries.append(.folder(folder.id))
                    }
                }
            }
            if !entries.isEmpty { layout.pages.append(entries) }
        }
        layout.fit(capacity: capacity)
        layout.compact()
        return layout
    }

    private static func text(_ s: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(s, col) else { return "" }
        return String(cString: c)
    }

    private static func query(_ db: OpaquePointer?, _ sql: String, _ row: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ReadError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }
}
