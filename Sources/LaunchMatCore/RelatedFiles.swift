import Foundation

/// Leftovers an app typically writes under ~/Library, found by exact bundle ID (and exact app name for the
/// two folders where apps use their name). Only existing paths are returned; nothing is deleted here.
public enum RelatedFiles {
    public static func find(bundleID: String?, appName: String, library: URL,
                            fileManager fm: FileManager = .default) -> [URL] {
        var candidates: [String] = []
        if let id = bundleID, isSafeBundleID(id) {
            candidates += [
                "Application Support/\(id)",
                "Caches/\(id)",
                "HTTPStorages/\(id)",
                "HTTPStorages/\(id).binarycookies",
                "WebKit/\(id)",
                "Preferences/\(id).plist",
                "Saved Application State/\(id).savedState",
                "Containers/\(id)",
                "Application Scripts/\(id)",
                "Cookies/\(id).binarycookies",
                "Logs/\(id)",
            ]
            candidates += matching(in: library.appendingPathComponent("Preferences/ByHost"), fm: fm) {
                $0.hasPrefix(id + ".") && $0.hasSuffix(".plist")
            }.map { "Preferences/ByHost/\($0)" }
            candidates += matching(in: library.appendingPathComponent("LaunchAgents"), fm: fm) {
                $0 == id + ".plist" || ($0.hasPrefix(id + ".") && $0.hasSuffix(".plist"))
            }.map { "LaunchAgents/\($0)" }
            candidates += matching(in: library.appendingPathComponent("Group Containers"), fm: fm) {
                $0.hasSuffix("." + id) || $0 == id
            }.map { "Group Containers/\($0)" }
        }
        let name = appName.trimmingCharacters(in: .whitespaces)
        if name.count >= 3, isSafeComponent(name) {
            candidates += ["Application Support/\(name)", "Logs/\(name)"]
        }
        let root = library.standardizedFileURL.path
        var seen = Set<String>()
        return candidates
            .map { library.appendingPathComponent($0).standardizedFileURL }
            .filter { url in
                // Must stay exactly two levels below ~/Library (three for Preferences/ByHost), never a symlink.
                let rel = url.path.hasPrefix(root + "/") ? String(url.path.dropFirst(root.count + 1)) : ""
                let parts = rel.split(separator: "/")
                let depthOK = parts.count == 2 || (parts.count == 3 && parts[0] == "Preferences" && parts[1] == "ByHost")
                guard depthOK, parts.allSatisfy({ isSafeComponent(String($0)) }), seen.insert(url.path).inserted,
                      let attrs = try? fm.attributesOfItem(atPath: url.path),
                      attrs[.type] as? FileAttributeType != .typeSymbolicLink else { return false }
                return true
            }
    }

    /// Reverse-DNS only: letters, digits, '-', '_' separated by single dots, at least two parts.
    public static func isSafeBundleID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression) != nil
    }

    static func isSafeComponent(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix(".") && !s.contains("/") && s != "~"
    }

    private static func matching(in dir: URL, fm: FileManager, _ keep: (String) -> Bool) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter(keep).sorted()
    }
}
