import Foundation
import LaunchMatCore

/// Every piece of interface text goes through here: a stable key and its English text. English comes from these
/// defaults; another language only needs a Localizable.strings with the same keys in Support/<lang>.lproj (copied
/// into the app by build.sh), so the copy can be replaced in one place without touching the views.
/// `scripts/strings-template.sh` lists every key with its English text, for translating.
func L(_ key: StaticString, _ english: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: english)
}

extension HotCorner {
    var title: String {
        switch self {
        case .off: return L("choice.off", "Off")
        case .topLeft: return L("corner.topLeft", "Top Left")
        case .topRight: return L("corner.topRight", "Top Right")
        case .bottomLeft: return L("corner.bottomLeft", "Bottom Left")
        case .bottomRight: return L("corner.bottomRight", "Bottom Right")
        }
    }
}

extension PinchFingers {
    var title: String {
        switch self {
        case .off: return L("choice.off", "Off")
        case .three: return L("pinch.three", "Pinch with 3 Fingers")
        case .fourOrFive: return L("pinch.thumbAndThree", "Pinch with Thumb and 3 Fingers")
        }
    }
}
