import Foundation

/// Weighted search fields for one app; array index == weight, lower wins.
public struct SearchKeys: Hashable, Sendable {
    public let fields: [String]
    public init(fields: [String]) { self.fields = fields }
}

/// Scoring scheme:
/// pre-computed romanised "full" + initials "abbr" keys, prefix hit = weight,
/// substring hit = weight + 20, best (lowest) score wins, ties keep layout order.
public enum Search {
    public static let containsPenalty = 20

    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    public static func normalizedQuery(_ s: String) -> String {
        fold(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "Visual Studio Code" -> ("visualstudiocode", "vsc"); "微信" -> ("weixin", "wx").
    public static func fullAndAbbr(_ text: String) -> (full: String, abbr: String) {
        var full = ""
        var abbr = ""
        for chunk in chunks(text) {
            let m = NSMutableString(string: chunk)
            CFStringTransform(m as CFMutableString, nil, kCFStringTransformToLatin, false)
            CFStringTransform(m as CFMutableString, nil, kCFStringTransformStripCombiningMarks, false)
            for piece in (m as String).components(separatedBy: .whitespaces) where !piece.isEmpty {
                let lower = piece.lowercased()
                full += lower
                abbr.append(lower.first!)
            }
        }
        return (full, abbr)
    }

    /// Runs of Latin letters/digits stay one word; any other letter (e.g. one CJK character) is its own chunk.
    static func chunks(_ text: String) -> [String] {
        var out: [String] = []
        var run = ""
        for ch in text {
            if isLatinWordChar(ch) {
                run.append(ch)
                continue
            }
            if !run.isEmpty {
                out.append(run)
                run = ""
            }
            if ch.isLetter || ch.isNumber { out.append(String(ch)) }
        }
        if !run.isEmpty { out.append(run) }
        return out
    }

    static func isLatinWordChar(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        if scalar.isASCII { return ch.isLetter || ch.isNumber }
        return ch.isLetter && scalar.value < 0x0250
    }

    /// `name` is the localized display name, `altName` the bundle's own (usually English) name.
    public static func keys(name: String, altName: String) -> SearchKeys {
        let n = fullAndAbbr(name)
        let a = altName == name ? (full: "", abbr: "") : fullAndAbbr(altName)
        return SearchKeys(fields: [
            fold(name),
            altName == name ? "" : fold(altName),
            n.full, n.abbr,
            a.full, a.abbr,
        ])
    }

    /// `query` must already be normalized. Lower is better; nil = no match.
    public static func score(_ keys: SearchKeys, query: String) -> Int? {
        guard !query.isEmpty else { return nil }
        var best: Int?
        for (weight, field) in keys.fields.enumerated() where !field.isEmpty {
            let s: Int
            if field.hasPrefix(query) {
                s = weight
            } else if field.contains(query) {
                s = weight + containsPenalty
            } else {
                continue
            }
            if best == nil || s < best! { best = s }
        }
        return best
    }

    public static func rank<T>(_ items: [T], query: String, keys: (T) -> SearchKeys, order: (T) -> Int) -> [T] {
        let q = normalizedQuery(query)
        guard !q.isEmpty else { return items }
        return items
            .compactMap { item in score(keys(item), query: q).map { (item, $0, order(item)) } }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .map(\.0)
    }
}
