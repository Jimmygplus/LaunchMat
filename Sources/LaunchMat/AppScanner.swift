import AppKit
import LaunchMatCore

struct AppRecord: Identifiable, Sendable {
    let id: String // bundle path (for a linked app, the link's)
    /// The app bundle itself: `id`, or where a link (symbolic link or Finder alias) leads. Icons, names and opening
    /// come from here, so a link never shows an arrow.
    let target: String
    var isLink: Bool { target != id }
    let name: String // localized display name
    let bundleName: String
    let bundleID: String?
    let category: String?
    let isApple: Bool
    let isUtility: Bool
    let keys: SearchKeys
}

/// Finds .app bundles the way Launchpad did: the Applications folders, one level of subfolders.
enum AppScanner {
    static var roots: [String] {
        ["/System/Applications", "/Applications", NSHomeDirectory() + "/Applications"]
    }

    /// One entry per app: the app itself when it is in these folders, otherwise the first link to it. Links
    /// (symbolic links, with or without .app, and Finder aliases, also chains of them) count when they lead to an app.
    static func scan() -> [AppRecord] {
        var found: [Found] = []
        for root in roots {
            collect(URL(fileURLWithPath: root), depth: 2, into: &found)
        }
        var byTarget: [String: Found] = [:]
        var order: [String] = []
        for f in found {
            let key = f.target.path
            if let kept = byTarget[key] {
                if kept.isLink && !f.isLink { byTarget[key] = f }
            } else {
                byTarget[key] = f
                order.append(key)
            }
        }
        return order.compactMap { byTarget[$0].flatMap { record(at: $0.url, target: $0.target) } }
    }

    private struct Found {
        let url: URL
        let target: URL
        var isLink: Bool { url != target }
    }

    private static func collect(_ dir: URL, depth: Int, into found: inout [Found]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])
        else { return }
        // Not .skipsHiddenFiles: /Applications/Safari.app is a symlink flagged hidden (macOS 13+ Cryptex).
        for url in items.sorted(by: { $0.path < $1.path }) where !url.lastPathComponent.hasPrefix(".") {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true || values?.isAliasFile == true {
                // Shown only if it leads to an app, which it is then shown as.
                if let target = AppLinks.app(at: url) { found.append(Found(url: url, target: target)) }
            } else if url.pathExtension == "app" {
                found.append(Found(url: url, target: url))
            } else if depth > 1, values?.isDirectory == true {
                collect(url, depth: depth - 1, into: &found)
            }
        }
    }

    static func record(for url: URL) -> AppRecord? { record(at: url, target: url) }

    /// The entry at `url` for the app bundle at `target` (the same, unless `url` is a link to it).
    static func record(at url: URL, target: URL) -> AppRecord? {
        let info = Bundle(url: target)?.infoDictionary ?? [:]
        if (info["LSBackgroundOnly"] as? Bool) == true { return nil }
        var name = FileManager.default.displayName(atPath: target.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        let bundleName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? name
        let bundleID = info["CFBundleIdentifier"] as? String
        return AppRecord(
            id: url.path,
            target: target.path,
            name: name,
            bundleName: bundleName,
            bundleID: bundleID,
            category: prettyCategory(info["LSApplicationCategoryType"] as? String),
            isApple: bundleID?.hasPrefix("com.apple.") == true,
            isUtility: url.deletingLastPathComponent().lastPathComponent == "Utilities",
            keys: Search.keys(name: name, altName: bundleName,
                              otherNames: LocalizedNames.chinese(resources: target.appendingPathComponent("Contents/Resources")))
        )
    }

    /// "public.app-category.developer-tools" -> "Developer Tools"
    static func prettyCategory(_ raw: String?) -> String? {
        guard let raw, let last = raw.split(separator: ".").last, raw.contains("app-category") else { return nil }
        return last.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}


/// Where a symbolic link or a Finder alias in the Applications folders leads, read from the links themselves.
enum AppLinks {
    /// The app bundle at the end of the chain (at most 8 links), or nil when it leads nowhere, to something that
    /// isn't an app, or into a folder macOS guards: looking there would ask the user, so it is left alone.
    static func app(at url: URL) -> URL? {
        var current = url
        for _ in 0..<8 {
            let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey, .isDirectoryKey])
            let next: String
            if values?.isSymbolicLink == true {
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { return nil }
                next = destination.hasPrefix("/") ? destination
                    : current.deletingLastPathComponent().appendingPathComponent(destination).path
            } else if values?.isAliasFile == true {
                guard let data = try? URL.bookmarkData(withContentsOf: current),
                      let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path else { return nil }
                next = path
            } else {
                return current.pathExtension == "app" && values?.isDirectory == true ? current : nil
            }
            let target = URL(fileURLWithPath: next).standardizedFileURL
            if GuardedFolders.contains(target.path) { return nil }
            current = target
        }
        return nil
    }
}

/// Watches the app folders (AppScanner.roots) for apps installed, removed or updated (spec §14): FSEvents with a 1 s
/// latency, then 1 s more of quiet before `changed` runs, so an install that writes for a while counts once.
@MainActor
final class AppWatcher {
    private var stream: FSEventStreamRef?
    private let changed: @MainActor () -> Void
    private var quiet: DispatchWorkItem?

    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let paths = AppScanner.roots.filter { FileManager.default.fileExists(atPath: $0) } as CFArray
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<AppWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.fired() } // delivered on the main queue
        }
        stream = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func fired() {
        quiet?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.changed() } }
        quiet = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
