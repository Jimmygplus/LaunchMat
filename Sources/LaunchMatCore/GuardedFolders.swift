import Foundation

/// Folders macOS guards with a privacy prompt ("… would like to access files in your Downloads folder"): Desktop,
/// Documents, Downloads, iCloud Drive and other cloud storage, other apps' data, and other volumes. LaunchMat never
/// reads a file in one of them for its own sake (the desktop picture behind the grid), so nobody is asked.
/// Decided from the path alone: looking at the file (even resolving a link) would already ask.
public enum GuardedFolders {
    static let inHome = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage",
                         "Library/Containers", "Library/Group Containers"]

    public static func contains(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let p = (path as NSString).standardizingPath
        if p.hasPrefix("/Volumes/") { return true }
        return inHome.contains { p == "\(home)/\($0)" || p.hasPrefix("\(home)/\($0)/") }
    }
}
