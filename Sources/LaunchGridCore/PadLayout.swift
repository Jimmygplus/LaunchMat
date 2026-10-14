import Foundation

/// One slot on a page: an app (by bundle path) or a folder.
public enum Entry: Hashable, Codable, Sendable {
    case app(String)
    case folder(UUID)

    public var key: String {
        switch self {
        case .app(let path): return "app:" + path
        case .folder(let id): return "folder:" + id.uuidString
        }
    }

    public var appPath: String? {
        if case .app(let path) = self { return path }
        return nil
    }

    public var folderID: UUID? {
        if case .folder(let id) = self { return id }
        return nil
    }

    /// Stored as the readable string `"app:/Applications/X.app"` or `"folder:<UUID>"`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw.hasPrefix("app:") {
            self = .app(String(raw.dropFirst(4)))
        } else if raw.hasPrefix("folder:"), let id = UUID(uuidString: String(raw.dropFirst(7))) {
            self = .folder(id)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad entry \(raw)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }
}

public struct Folder: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var apps: [String]

    public init(id: UUID = UUID(), name: String, apps: [String]) {
        self.id = id
        self.name = name
        self.apps = apps
    }
}

/// Persistent grid: explicit pages (they may be partly filled, like Launchpad), folders, hidden apps.
public struct PadLayout: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Apps missing from scans are kept in place this long (updates, reinstalls, unmounted volumes).
    public static let missingGrace: TimeInterval = 3 * 24 * 3600

    public var pages: [[Entry]]
    public var folders: [UUID: Folder]
    public var hidden: Set<String>
    /// First time each currently-missing app was not found.
    public var missingSince: [String: Date]

    public init(pages: [[Entry]] = [[]], folders: [UUID: Folder] = [:], hidden: Set<String> = [],
                missingSince: [String: Date] = [:]) {
        self.pages = pages
        self.folders = folders
        self.hidden = hidden
        self.missingSince = missingSince
    }

    private enum CodingKeys: String, CodingKey { case version, pages, folders, hidden, missingSince }

    /// Tolerant: absent keys get defaults so hand edits and older/newer files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pages = try c.decodeIfPresent([[Entry]].self, forKey: .pages) ?? [[]]
        let list = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        folders = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        missingSince = try c.decodeIfPresent([String: Date].self, forKey: .missingSince) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(pages, forKey: .pages)
        try c.encode(folders.values.sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name },
                     forKey: .folders)
        try c.encode(hidden.sorted(), forKey: .hidden)
        try c.encode(missingSince, forKey: .missingSince)
    }

    public var isEmpty: Bool { pages.allSatisfy(\.isEmpty) }

    public func locate(_ entry: Entry) -> (page: Int, index: Int)? {
        for (p, page) in pages.enumerated() {
            if let i = page.firstIndex(of: entry) { return (p, i) }
        }
        return nil
    }

    public func folder(containing app: String) -> UUID? {
        folders.first { $0.value.apps.contains(app) }?.key
    }

    /// Every placed app in display order, folder contents expanded in place.
    public var orderedApps: [String] {
        pages.flatMap { $0 }.flatMap { entry -> [String] in
            switch entry {
            case .app(let path): return [path]
            case .folder(let id): return folders[id]?.apps ?? []
            }
        }
    }

    @discardableResult
    public mutating func remove(_ entry: Entry) -> Bool {
        guard let loc = locate(entry) else { return false }
        pages[loc.page].remove(at: loc.index)
        return true
    }

    /// Inserts and pushes the overflow of full pages onto the following pages.
    public mutating func insert(_ entry: Entry, page: Int, index: Int, capacity: Int) {
        let page = max(0, page)
        while pages.count <= page { pages.append([]) }
        pages[page].insert(entry, at: max(0, min(index, pages[page].count)))
        cascade(from: page, capacity: capacity)
    }

    /// Moves an entry so it ends up at `index` on `page`.
    public mutating func move(_ entry: Entry, page: Int, index: Int, capacity: Int) {
        remove(entry)
        insert(entry, page: page, index: index, capacity: capacity)
    }

    public mutating func append(_ entry: Entry, capacity: Int) {
        if pages.isEmpty { pages = [[]] }
        if pages[pages.count - 1].count >= capacity { pages.append([]) }
        pages[pages.count - 1].append(entry)
    }

    /// Re-flows pages after the grid size shrinks.
    public mutating func fit(capacity: Int) { cascade(from: 0, capacity: capacity) }

    private mutating func cascade(from start: Int, capacity: Int) {
        let capacity = max(1, capacity)
        var p = start
        while p < pages.count {
            while pages[p].count > capacity {
                let overflow = pages[p].removeLast()
                if p + 1 == pages.count { pages.append([]) }
                pages[p + 1].insert(overflow, at: 0)
            }
            p += 1
        }
    }

    public mutating func compact() {
        pages.removeAll { $0.isEmpty }
        if pages.isEmpty { pages = [[]] }
    }

    /// Drops `app` onto `target`: joins the folder, or turns the target app's slot into a new folder.
    @discardableResult
    public mutating func merge(app: String, onto target: Entry, newFolderName: String) -> UUID? {
        guard target != .app(app), locate(target) != nil else { return nil }
        switch target {
        case .folder(let id):
            guard folders[id] != nil else { return nil }
            remove(.app(app))
            if !folders[id]!.apps.contains(app) { folders[id]!.apps.append(app) }
            return id
        case .app(let other):
            remove(.app(app))
            guard let slot = locate(target) else { return nil }
            let folder = Folder(name: newFolderName, apps: [other, app])
            folders[folder.id] = folder
            pages[slot.page][slot.index] = .folder(folder.id)
            return folder.id
        }
    }

    /// Re-inserts `entries` right after `anchor`, keeping their order (used when a multi-selection is dropped).
    public mutating func insert(_ entries: [Entry], after anchor: Entry, capacity: Int) {
        var previous = anchor
        for entry in entries {
            if let loc = locate(previous) {
                insert(entry, page: loc.page, index: loc.index + 1, capacity: capacity)
            } else {
                append(entry, capacity: capacity)
            }
            previous = entry
        }
    }

    /// Moves `apps` (from pages or other folders) into one new folder placed where the first of them was.
    @discardableResult
    public mutating func group(apps: [String], name: String, capacity: Int) -> UUID? {
        var seen = Set<String>()
        let apps = apps.filter { seen.insert($0).inserted }
        guard apps.count >= 2 else { return nil }
        let folder = Folder(name: name, apps: apps)
        if let first = apps.first(where: { locate(.app($0)) != nil }), let slot = locate(.app(first)) {
            pages[slot.page][slot.index] = .folder(folder.id)
        } else if let source = apps.compactMap(folder(containing:)).first,
                  let slot = locate(.folder(source)) {
            pages[slot.page].insert(.folder(folder.id), at: slot.index + 1)
        } else {
            append(.folder(folder.id), capacity: capacity)
        }
        for app in apps {
            remove(.app(app))
            if let source = self.folder(containing: app) {
                folders[source]?.apps.removeAll { $0 == app }
                dissolveIfNeeded(source)
            }
        }
        folders[folder.id] = folder
        cascade(from: 0, capacity: capacity)
        return folder.id
    }

    public mutating func removeApp(_ app: String, fromFolder id: UUID) {
        folders[id]?.apps.removeAll { $0 == app }
        dissolveIfNeeded(id)
    }

    /// A folder with one app becomes that app; an empty folder disappears.
    public mutating func dissolveIfNeeded(_ id: UUID) {
        guard let folder = folders[id], folder.apps.count < 2 else { return }
        if let loc = locate(.folder(id)) {
            if let only = folder.apps.first, locate(.app(only)) == nil {
                pages[loc.page][loc.index] = .app(only)
            } else {
                pages[loc.page].remove(at: loc.index)
            }
        }
        folders[id] = nil
    }

    public mutating func hide(_ app: String) {
        remove(.app(app))
        if let id = folder(containing: app) { removeApp(app, fromFolder: id) }
        hidden.insert(app)
    }

    /// Syncs with what is installed. An app missing from a scan keeps its slot, folder and hidden state for
    /// `missingGrace` (so updates and reinstalls don't scramble the layout); after that it is pruned.
    /// Also repairs duplicates and appends newly installed apps at the end.
    public mutating func reconcile(installed: [String], capacity: Int, now: Date = Date(),
                                   grace: TimeInterval = PadLayout.missingGrace) {
        let installedSet = Set(installed)
        let known = Set(orderedApps).union(hidden).union(missingSince.keys)
        for app in installedSet { missingSince[app] = nil }
        for app in known where !installedSet.contains(app) && missingSince[app] == nil { missingSince[app] = now }
        let expired = Set(missingSince.filter { now.timeIntervalSince($0.value) > grace }.keys)
        for app in expired { missingSince[app] = nil }
        let keep = installedSet.union(missingSince.keys) // installed, or missing but still within grace

        hidden = hidden.intersection(keep)
        var seenInFolders = Set<String>()
        for id in folders.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            folders[id]!.apps = folders[id]!.apps.filter {
                keep.contains($0) && !hidden.contains($0) && seenInFolders.insert($0).inserted
            }
        }
        var seen = Set<String>()
        var seenFolders = Set<UUID>()
        for p in pages.indices {
            pages[p].removeAll { entry in
                switch entry {
                case .app(let app):
                    return !keep.contains(app) || hidden.contains(app) || seenInFolders.contains(app)
                        || !seen.insert(app).inserted
                case .folder(let id):
                    return folders[id] == nil || !seenFolders.insert(id).inserted
                }
            }
        }
        let referenced = Set(pages.flatMap { $0 }.compactMap(\.folderID))
        for id in Array(folders.keys) where !referenced.contains(id) { folders[id] = nil }
        for id in Array(folders.keys) { dissolveIfNeeded(id) }
        let placed = Set(orderedApps).union(hidden)
        for app in installed where !placed.contains(app) { append(.app(app), capacity: capacity) }
        fit(capacity: capacity)
        compact()
    }
}
