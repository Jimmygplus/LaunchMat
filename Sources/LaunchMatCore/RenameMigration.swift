import Foundation

/// LaunchMat was called LaunchGrid up to 0.1.0 (bundle ID `io.github.jimmygplus.LaunchGrid`). On the first launch
/// under the new name, the layout and settings are copied over so nobody loses their pages and folders. The old
/// files and preferences are left untouched, so going back to 0.1.0 still works.
public enum RenameMigration {
    public static let oldName = "LaunchGrid"
    public static let oldBundleID = "io.github.jimmygplus.LaunchGrid"
    /// The UserDefaults keys the app stores (see Geometry.swift and Triggers.swift).
    public static let settingKeys = ["gridCols", "gridRows", "hotCorner", "hotkey", "pinch"]
    /// Set in the new defaults once migration has run, so it never runs twice.
    public static let doneKey = "migratedFromLaunchGrid"

    /// Copies the regular files of `oldDir` (layout.json and any kept backups) into `newDir`, but only when `newDir`
    /// has no layout yet and `oldDir` has one. Symlinks are skipped and existing files are never overwritten.
    /// Returns true if a layout was copied.
    @discardableResult
    public static func migrateFiles(from oldDir: URL, to newDir: URL, fileManager fm: FileManager = .default) -> Bool {
        let oldLayout = oldDir.appendingPathComponent("layout.json")
        let newLayout = newDir.appendingPathComponent("layout.json")
        guard !fm.fileExists(atPath: newLayout.path), isRegularFile(oldLayout, fm) else { return false }
        guard let items = try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              (try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)) != nil else { return false }
        for item in items where isRegularFile(item, fm) {
            let target = newDir.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: item, to: target) }
        }
        return fm.fileExists(atPath: newLayout.path)
    }

    /// Copies the old app's settings into `new` for every key `new` doesn't have yet. Returns the keys copied.
    @discardableResult
    public static func migrateSettings(from old: UserDefaults?, to new: UserDefaults) -> [String] {
        guard let old else { return [] }
        var copied: [String] = []
        for key in settingKeys where new.object(forKey: key) == nil {
            if let value = old.object(forKey: key) {
                new.set(value, forKey: key)
                copied.append(key)
            }
        }
        return copied
    }

    /// Runs both steps once. `supportDir` is ~/Library/Application Support; `newName` the app's folder name there.
    /// Returns true if anything was carried over.
    @discardableResult
    public static func runOnce(supportDir: URL, newName: String, defaults: UserDefaults = .standard,
                               oldDefaults: UserDefaults? = UserDefaults(suiteName: oldBundleID),
                               fileManager: FileManager = .default) -> Bool {
        guard !defaults.bool(forKey: doneKey) else { return false }
        let files = migrateFiles(from: supportDir.appendingPathComponent(oldName, isDirectory: true),
                                 to: supportDir.appendingPathComponent(newName, isDirectory: true), fileManager: fileManager)
        let settings = migrateSettings(from: oldDefaults, to: defaults)
        defaults.set(true, forKey: doneKey)
        return files || !settings.isEmpty
    }

    private static func isRegularFile(_ url: URL, _ fm: FileManager) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
