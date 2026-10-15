import AppKit
import SwiftUI

/// One card per version about its most useful new thing, shown over the grid the first time it opens after an
/// upgrade (a fresh install gets the welcome guide instead). Its picture is drawn by the app: nothing is loaded.
struct WhatsNew: Equatable {
    let version: String
    let title: String
    /// May contain "⌘", drawn as a key cap.
    let body: String

    static let seenKey = "whatsNewSeenVersion"

    /// The card for the running version, if it has one.
    static var current: WhatsNew? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return cards.first { $0.version == version }
    }

    private static let cards = [
        WhatsNew(version: "0.1.2",
                 title: "Drop one app on another. A folder.",
                 body: "Hold an app over another for a moment, then let go. ⌘-click to pick several apps and move them together."),
    ]

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
            MergePicture()
                .frame(width: 480, height: 236)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(4)
            Text(card.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.top, 20)
            KeyCapText(text: card.body)
                .font(.system(size: 13))
                .foregroundStyle(Color(white: 0.72))
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.horizontal, 24)
                .padding(.top, 8)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Spacer()
                Button("What’s New", action: releaseNotes)
                    .buttonStyle(CardButtonStyle(light: false))
                    .frame(width: 122)
                Button("Got It", action: dismiss)
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

/// The picture: two app tiles on a dark wallpaper, one lifted onto the other over the merge plate. Our own drawing,
/// in the stand-in style of the website's demo (no real app icons).
private struct MergePicture: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.2, green: 0.17, blue: 0.36), Color(red: 0.07, green: 0.09, blue: 0.18)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 46) {
                Tile(color: Color(red: 0.25, green: 0.56, blue: 0.99), glyph: "N").opacity(0.55)
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.white.opacity(0.3))
                        .frame(width: 86, height: 86)
                    Tile(color: Color(red: 0.43, green: 0.79, blue: 0.44), glyph: "M")
                    Tile(color: Color(red: 0.95, green: 0.31, blue: 0.40), glyph: "♪")
                        .scaleEffect(1.1)
                        .offset(x: 16, y: -14)
                        .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .offset(x: 34, y: 6)
                }
                Tile(color: Color(red: 0.42, green: 0.38, blue: 0.95), glyph: "P").opacity(0.55)
            }
        }
    }

    private struct Tile: View {
        let color: Color
        let glyph: String

        var body: some View {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                .frame(width: 66, height: 66)
                .overlay(Text(glyph).font(.system(size: 26, weight: .bold)).foregroundStyle(.white))
        }
    }
}
