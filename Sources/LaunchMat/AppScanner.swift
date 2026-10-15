import AppKit
import LaunchMatCore

struct AppRecord: Identifiable, Sendable {
    let id: String // bundle path
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

    static func scan() -> [AppRecord] {
        var seen = Set<String>()
        var out: [AppRecord] = []
        for root in roots {
            collect(URL(fileURLWithPath: root), depth: 2, seen: &seen, into: &out)
        }
        return out
    }

    private static func collect(_ dir: URL, depth: Int, seen: inout Set<String>, into out: inout [AppRecord]) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return }
        // Not .skipsHiddenFiles: /Applications/Safari.app is a symlink flagged hidden (macOS 13+ Cryptex).
        for url in items where !url.lastPathComponent.hasPrefix(".") {
            if url.pathExtension == "app" {
                let real = url.resolvingSymlinksInPath().path
                guard seen.insert(real).inserted, let rec = record(for: url) else { continue }
                out.append(rec)
            } else if depth > 1, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                collect(url, depth: depth - 1, seen: &seen, into: &out)
            }
        }
    }

    static func record(for url: URL) -> AppRecord? {
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        if (info["LSBackgroundOnly"] as? Bool) == true { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        let bundleName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? name
        let bundleID = info["CFBundleIdentifier"] as? String
        return AppRecord(
            id: url.path,
            name: name,
            bundleName: bundleName,
            bundleID: bundleID,
            category: prettyCategory(info["LSApplicationCategoryType"] as? String),
            isApple: bundleID?.hasPrefix("com.apple.") == true,
            isUtility: url.deletingLastPathComponent().lastPathComponent == "Utilities",
            keys: Search.keys(name: name, altName: bundleName,
                              otherNames: LocalizedNames.chinese(resources: url.appendingPathComponent("Contents/Resources")))
        )
    }

    /// "public.app-category.developer-tools" -> "Developer Tools"
    static func prettyCategory(_ raw: String?) -> String? {
        guard let raw, let last = raw.split(separator: ".").last, raw.contains("app-category") else { return nil }
        return last.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}

/// The blurred desktop picture behind the grid. It is computed on a background thread at launch and whenever the
/// picture or the Space changes, so opening the grid only reads the cache.
@MainActor
enum Wallpaper {
    private static var cache: [URL: NSImage] = [:]
    private static var pending: Set<URL> = []

    /// The prepared image for this screen's desktop picture, or nil if it isn't ready yet.
    static func cached(for screen: NSScreen) -> NSImage? {
        NSWorkspace.shared.desktopImageURL(for: screen).flatMap { cache[$0] }
    }

    /// Blurs the desktop pictures of these screens in the background; `ready` runs on the main thread after each
    /// new image is cached.
    static func prepare(for screens: [NSScreen], ready: @escaping @MainActor () -> Void) {
        for screen in screens {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  cache[url] == nil, pending.insert(url).inserted else { continue }
            Task.detached(priority: .utility) {
                let image = WallpaperImage(cg: render(url))
                await MainActor.run {
                    pending.remove(url)
                    if let cg = image.cg { cache[url] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
                    ready()
                }
            }
        }
    }

    /// Synchronous, for --snapshot.
    static func blurred(for screen: NSScreen) -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let hit = cache[url] { return hit }
        guard let cg = render(url) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[url] = image
        return image
    }

    /// Pre-blurred, downscaled copy of the desktop picture (Launchpad blurs the wallpaper, not the windows).
    nonisolated static func render(_ url: URL) -> CGImage? {
        guard let source = CIImage(contentsOf: url), source.extent.width > 0 else { return nil }
        let scale = 900 / source.extent.width
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: small.extent)
        return CIContext().createCGImage(blurred, from: small.extent)
    }
}

private struct WallpaperImage: @unchecked Sendable {
    let cg: CGImage?
}
