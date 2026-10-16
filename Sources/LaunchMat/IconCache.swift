import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Icon bitmaps kept on disk between launches (~/Library/Caches/LaunchMat/Icons), so a launch reads pixels instead of
/// having IconServices render every icon again. An entry is named after the app's path, its bundle's modification
/// date and the pixel size, so an updated app or a new icon size simply misses and is drawn again. Used from
/// background threads only.
enum IconCache {
    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LaunchMat/Icons", isDirectory: true)

    static func key(path: String, pixels: Int) -> String {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        // "3": icons are drawn from the app bundle itself (links and Finder aliases resolved), so any older entry,
        // which may carry an alias arrow, misses and is drawn again.
        let digest = SHA256.hash(data: Data("\(path)|\(modified)|\(pixels)|3".utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".png"
    }

    static func load(_ key: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(key) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func store(_ image: CGImage, as key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(key)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Deletes entries not in `keep` (apps removed or updated, old icon sizes).
    static func prune(keeping keep: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where file.hasSuffix(".png") && !keep.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}
