import Foundation

/// An app's names in Chinese, whatever the system language, so pinyin search works on an English Mac too
/// (`wx` → 微信 when WeChat calls itself "WeChat" in English). Third-party apps keep them in
/// `<lang>.lproj/InfoPlist.strings`; Apple's apps in `InfoPlist.loctable`, one dictionary per locale.
public enum LocalizedNames {
    static let lprojNames = ["zh-Hans", "zh_CN", "zh-CN", "zh-Hant", "zh_TW", "zh-TW", "zh_HK", "zh-HK"]
    static let loctableLocales = ["zh_CN", "zh-Hans", "zh_TW", "zh-Hant", "zh_HK", "zh-HK"]
    static let nameKeys = ["CFBundleDisplayName", "CFBundleName"]

    /// Distinct Chinese display names found in an app's Resources folder, in a stable order.
    public static func chinese(resources: URL, fileManager fm: FileManager = .default) -> [String] {
        var names: [String] = []
        func add(_ table: [String: Any]?) {
            guard let table else { return }
            for key in nameKeys {
                if let name = (table[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty, !names.contains(name) {
                    names.append(name)
                }
            }
        }
        for lproj in lprojNames {
            let strings = resources.appendingPathComponent("\(lproj).lproj/InfoPlist.strings")
            if fm.fileExists(atPath: strings.path) { add(NSDictionary(contentsOf: strings) as? [String: Any]) }
        }
        let loctable = resources.appendingPathComponent("InfoPlist.loctable")
        if fm.fileExists(atPath: loctable.path), let all = NSDictionary(contentsOf: loctable) as? [String: Any] {
            for locale in loctableLocales { add(all[locale] as? [String: Any]) }
        }
        return names
    }
}
