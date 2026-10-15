import AppKit
import SwiftUI

/// One card per version about its most useful new thing, shown over the grid the first time it opens after an
/// upgrade (a fresh install gets the welcome guide instead). Its picture is drawn by the app: nothing is loaded.
struct WhatsNew: Equatable {
    let version: String
    /// One line each; ⌘ is drawn as a key cap.
    let items: [String]

    static let seenKey = "whatsNewSeenVersion"

    var title: String { L("whatsNew.title", "What’s new in LaunchMat \(version)") }

    /// The card for the running version, if it has one.
    static var current: WhatsNew? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        switch version {
        case "0.1.2":
            var items = [L("whatsNew.0.1.2.pinyin", "Typing wx now finds 微信 even when your Mac’s language is English.")]
            if cameFromLaunchGrid {
                items.append(L("whatsNew.0.1.2.rename", "LaunchGrid is now called LaunchMat. Your layout came with you."))
            }
            return WhatsNew(version: version, items: items)
        default:
            return nil
        }
    }

    /// People updating from LaunchGrid still have its layout file.
    private static var cameFromLaunchGrid: Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileManager.default.fileExists(atPath: support.appendingPathComponent("LaunchGrid/layout.json").path)
    }

    /// Due when this version has a card that hasn't been seen.
    static var due: WhatsNew? {
        guard let card = current, UserDefaults.standard.string(forKey: seenKey) != card.version else { return nil }
        return card
    }

    static func markSeen() {
        if let card = current { UserDefaults.standard.set(card.version, forKey: seenKey) }
    }
}

/// The card: 498 × 419 pt, rounded 24, picture on top (480 × 236, inset 4, rounded 20), title, two lines of text,
/// and two buttons at the bottom right.
struct WhatsNewCard: View {
    let card: WhatsNew
    let releaseNotes: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchPicture()
                .frame(width: 480, height: 236)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(4)
            Text(card.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.top, 20)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(card.items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        KeyCapText(text: item).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Color(white: 0.72))
            .padding(.horizontal, 24)
            .padding(.top, 8)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Spacer()
                Button(L("whatsNew.releaseNotes", "Release Notes"), action: releaseNotes)
                    .buttonStyle(CardButtonStyle(light: false))
                    .frame(width: 122)
                Button(L("whatsNew.ok", "OK"), action: dismiss)
                    .buttonStyle(CardButtonStyle(light: true))
                    .frame(width: 110)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 498, height: 419)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(red: 0x39 / 255, green: 0x39 / 255, blue: 0x39 / 255).opacity(0.94)))
        .background(VisualEffect(material: .hudWindow, blending: .withinWindow).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous)))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        .environment(\.colorScheme, .dark)
    }
}

private struct CardButtonStyle: ButtonStyle {
    let light: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(light ? Color(white: 0.12) : Color(white: 0.9))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(light ? Color(red: 0xE0 / 255, green: 0xE0 / 255, blue: 0xE0 / 255) : Color(white: 0.2))
                .opacity(configuration.isPressed ? 0.75 : 1))
            .contentShape(Rectangle())
    }
}

/// Text in which "⌘" is drawn as a small key cap.
private struct KeyCapText: View {
    let text: String

    var body: some View {
        let parts = text.components(separatedBy: "⌘")
        parts.enumerated().reduce(Text("")) { result, part in
            let (i, piece) = part
            let cap = i == 0 ? Text("") : Text(Image(systemName: "command.square")).baselineOffset(-1)
            return result + cap + Text(piece)
        }
    }
}

/// The picture: the search field with "wx" typed, and the one app it finds. Our own drawing, in the stand-in style of
/// the website's demo (no real app icons).
private struct SearchPicture: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.2, green: 0.17, blue: 0.36), Color(red: 0.07, green: 0.09, blue: 0.18)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 26) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.75))
                    Text("wx").foregroundStyle(.white)
                    Rectangle().fill(.white).frame(width: 1.5, height: 16)
                    Spacer()
                }
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .frame(width: 230, height: 32)
                .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 0.8))
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.82, blue: 0.4), Color(red: 0.2, green: 0.62, blue: 0.27)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 70, height: 70)
                        .overlay(Text("W").font(.system(size: 28, weight: .bold)).foregroundStyle(.white))
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.18)).padding(-8))
                    Text("微信").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                }
            }
        }
    }
}
