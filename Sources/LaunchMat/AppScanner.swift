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
            keys: Search.keys(name: name, altName: bundleName)
        )
    }

    /// "public.app-category.developer-tools" -> "Developer Tools"
    static func prettyCategory(_ raw: String?) -> String? {
        guard let raw, let last = raw.split(separator: ".").last, raw.contains("app-category") else { return nil }
        return last.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}

enum Wallpaper {
    private static var cache: [URL: NSImage] = [:]

    /// Pre-blurred, downscaled copy of the desktop picture (Launchpad blurs the wallpaper, not the windows).
    static func blurred(for screen: NSScreen) -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let hit = cache[url] { return hit }
        guard let source = CIImage(contentsOf: url), source.extent.width > 0 else { return nil }
        let scale = 900 / source.extent.width
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: small.extent)
        guard let cg = CIContext().createCGImage(blurred, from: small.extent) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[url] = image
        return image
    }
}
