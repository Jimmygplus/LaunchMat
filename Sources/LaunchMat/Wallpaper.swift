import AppKit
import CoreImage

/// The blurred desktop picture behind the grid. Taken from the desktop picture's own window, as LaunchOS does
/// (spec, section 4): the window list gives the Dock's wallpaper window as large as the screen, and SkyLight's
/// `CGSHWCaptureWindowList`, looked up at run time, captures it. The picture's file is never read, so a picture in a
/// folder macOS guards (Downloads, Desktop…) asks for nothing. When the window or the function can't be found, or the
/// capture comes back empty, one line goes to the log and the grid keeps its dark backdrop.
/// Computed on a background thread at launch and whenever the picture, the Space or the screens change, so opening
/// the grid only reads the cache.
@MainActor
enum Wallpaper {
    private static var cache: [String: NSImage] = [:]
    private static var pending: Set<String> = []

    /// Changes with the screen and with its desktop picture (whose address is only compared, never opened).
    private static func key(for screen: NSScreen) -> String {
        "\(screen.displayID) \(NSWorkspace.shared.desktopImageURL(for: screen)?.absoluteString ?? "")"
    }

    /// The prepared image for this screen's desktop picture, or nil if it isn't ready yet (or couldn't be taken).
    static func cached(for screen: NSScreen) -> NSImage? {
        cache[key(for: screen)]
    }

    /// Captures and blurs the desktop pictures of these screens in the background; `ready` runs on the main thread
    /// after each new image is cached.
    static func prepare(for screens: [NSScreen], ready: @escaping @MainActor () -> Void) {
        for screen in screens {
            let key = key(for: screen)
            guard cache[key] == nil, pending.insert(key).inserted else { continue }
            let display = screen.displayID
            Task.detached(priority: .utility) {
                let width = CGDisplayBounds(display).width
                let image = WallpaperImage(cg: capture(display).flatMap { blur($0, screenWidth: width) })
                await MainActor.run {
                    pending.remove(key)
                    if let cg = image.cg { cache[key] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
                    ready()
                }
            }
        }
    }

    /// Synchronous, for --snapshot.
    static func blurred(for screen: NSScreen) -> NSImage? {
        let key = key(for: screen)
        if let hit = cache[key] { return hit }
        guard let cg = capture(screen.displayID).flatMap({ blur($0, screenWidth: screen.frame.width) }) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[key] = image
        return image
    }

    /// The desktop picture of this display as it is drawn, or nil (logged).
    nonisolated static func capture(_ display: CGDirectDisplayID) -> CGImage? {
        let bounds = CGDisplayBounds(display) // global, top left, like the window list
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        // The Dock draws each screen's desktop picture in a window at (or just below) the desktop level, as large
        // as the screen. The Finder's desktop-icons window is as large too, but above that level and not the Dock's.
        let window = windows.first { w in
            guard w[kCGWindowOwnerName as String] as? String == "Dock",
                  let layer = w[kCGWindowLayer as String] as? Int, layer <= desktop, layer >= desktop - 2,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { return false }
            return rect == bounds
        }
        guard let number = window?[kCGWindowNumber as String] as? NSNumber else {
            NSLog("LaunchMat: wallpaper capture failed: no desktop picture window for display \(display)")
            return nil
        }
        guard let capture = SkyLight.capture, let connection = SkyLight.mainConnection else {
            NSLog("LaunchMat: wallpaper capture failed: CGSHWCaptureWindowList not available")
            return nil
        }
        var id = number.uint32Value
        // Nominal (1×) resolution is plenty for a picture that is blurred at 900 px wide.
        let options: UInt32 = 1 << 9 | 1 << 11 // nominal resolution, ignore the global clip shape
        guard let list = capture(connection(), &id, 1, options)?.takeRetainedValue() as? [CGImage],
              let image = list.first, image.width > 1 else {
            NSLog("LaunchMat: wallpaper capture failed: empty capture for window \(id)")
            return nil
        }
        return image
    }

    /// The picture behind the grid, as LaunchOS makes it (spec 13.1): darker (RGB × 0.7), more saturated (× 1.4),
    /// then blurred with a radius of 30 pt on the screen, in a 900 px wide copy. Made once, in the background; it
    /// fades in when ready (0.36 s), and nothing is laid over it.
    nonisolated static func blur(_ image: CGImage, screenWidth: CGFloat) -> CGImage? {
        let source = CIImage(cgImage: image)
        guard source.extent.width > 0 else { return nil }
        let scale = 900 / source.extent.width
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let darker = small.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.7, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.7, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.7, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        let richer = darker.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.4, kCIInputBrightnessKey: 0, kCIInputContrastKey: 1,
        ])
        // 30 pt on a screen `screenWidth` wide is 30 × 900 / width pixels in the copy.
        let radius = 30 * 900 / max(1, screenWidth)
        let blurred = richer.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: small.extent)
        return CIContext().createCGImage(blurred, from: small.extent)
    }
}

/// SkyLight's window capture, looked up at run time so a missing symbol only turns the wallpaper off.
private enum SkyLight {
    typealias Capture = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, UInt32, UInt32) -> Unmanaged<CFArray>?
    typealias Connection = @convention(c) () -> Int32

    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let capture: Capture? = symbol("CGSHWCaptureWindowList")
    static let mainConnection: Connection? = symbol("CGSMainConnectionID")

    private static func symbol<T>(_ name: String) -> T? {
        guard let p = dlsym(handle ?? UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // -2: RTLD_DEFAULT
        return unsafeBitCast(p, to: T.self)
    }
}

private struct WallpaperImage: @unchecked Sendable {
    let cg: CGImage?
}
