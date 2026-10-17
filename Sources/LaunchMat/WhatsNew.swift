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
        case "0.2.0":
            return WhatsNew(version: version, items: [
                L("whatsNew.0.2.0.folders", "Folders open out of their icon and close back into it."),
                L("whatsNew.0.2.0.smooth", "Dragging is smooth, and holding ⌥ makes the icons wiggle."),
                L("whatsNew.0.2.0.menu", "Click the menu bar icon to open the grid; right-click it for Settings."),
            ])
        default:
            return nil
        }
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
    /// For the picture: the desktop picture behind the grid, and two of the grid's own apps.
    var wallpaper: NSImage? = nil
    var icons: [NSImage?] = []
    let releaseNotes: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderPicture(wallpaper: wallpaper, icons: icons)
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

/// The picture: two of the grid's own apps and the folder they make, on the desktop picture behind the grid. All of
/// it is the app's: its icons as the grid draws them (AppIconImage) and its folder icon (FolderPreview).
private struct FolderPicture: View {
    let wallpaper: NSImage?
    let icons: [NSImage?]

    var body: some View {
        let pair = Array(icons.prefix(2))
        ZStack {
            if let wallpaper {
                Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
            }
            HStack(spacing: 18) {
                ForEach(Array(pair.enumerated()), id: \.offset) { i, icon in
                    if i > 0 { symbol("plus") }
                    AppIconImage(image: icon, size: 72)
                }
                symbol("arrow.right")
                FolderPreview(icons: pair, size: 96)
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
    }
}
