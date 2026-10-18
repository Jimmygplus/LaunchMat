# LaunchMat

**The Launchpad you remember, for macOS 26 and later.** Apple removed Launchpad in macOS 26. LaunchMat brings back the
full-screen grid of apps with pages, folders, drag-and-drop and instant search. It is a small native Swift app with no
dependencies, no network access and no telemetry.

[中文说明](#中文说明)

## Install
1. Download `LaunchMat-x.y.z.dmg` from [Releases](https://github.com/Jimmygplus/LaunchMat/releases).
2. Open it and drag **LaunchMat** into **Applications**.
3. Open LaunchMat. Optionally, drag it into your Dock; clicking it there toggles the grid, like the old Launchpad icon.

Release builds are signed with a Developer ID and notarized by Apple. Requires macOS 14 or later; Apple silicon and Intel.

Website: [launchmat.app](https://launchmat.app)

## Features
| | |
|---|---|
| **Open / close** | ⇧⌘Space from anywhere (changeable in the menu), the Dock icon, the menu-bar ▦ icon, a **hot corner**, or a **trackpad pinch** (3 fingers, or thumb + 3 fingers). Esc or a click on empty space closes it |
| **Launch** | Click, or use the arrow keys + Return |
| **Search** | Just start typing. Prefix matches rank first, then substrings. Initials work (`vsc` → Visual Studio Code) |
| **Pages** | Two-finger swipe, mouse wheel, click-drag on the background, or the page dots. Grid sizes from 7×5 to 10×6 |
| **Rearrange** | Drag an icon and the others make room. Hold it at the screen edge to move it to another page |
| **Folders** | Drop an app onto another app (hold for a moment) to make a folder. Click the title to rename it. Drag an app out to remove it |
| **Multi-select** | ⌘-click several apps, then drag them together, or right-click → *New Folder with N Apps* / *Hide N Apps* |
| **Uninstall** | Hold ⌥ (the icons wiggle) and click ✕, or right-click → *Move to Trash…*. Leftovers in `~/Library` are listed first. Everything goes to the Trash, so it can be restored |
| **Import** | Menu bar → *Import System Launchpad Layout…* restores your pages and folders from the pre-macOS-26 Launchpad database, if it is still on your Mac |
| **Launch at login** | Menu bar → *Launch at Login* |

Settings live in the menu-bar ▦ menu. The layout is a plain JSON file at
`~/Library/Application Support/LaunchMat/layout.json`.

### Permissions
- **Accessibility**: only if you turn on the trackpad pinch. Reading gestures system-wide needs it. Nothing else uses it.
- **Automation (Finder)**: only when you uninstall an app that is owned by the system administrator. Finder then asks for
  your password.
- Hot corners, the hotkey, search and everything else need no permission.

If you use the *thumb + 3 fingers* pinch, turn off **System Settings › Trackpad › More Gestures › Launchpad/Apps**
so that macOS doesn't respond to the same gesture.

## Build from source
```bash
git clone https://github.com/Jimmygplus/LaunchMat && cd LaunchMat
./build.sh                 # -> build/LaunchMat.app for this Mac
open build/LaunchMat.app
```
Xcode 15.3 or later (Swift 5.10+). `./scripts/release.sh` makes the universal, signed and notarized DMG; it needs a
Developer ID certificate and a `notarytool` keychain profile, named in environment variables. See
[docs/distribution.md](docs/distribution.md), which also covers checking a published release.

## Tests
```bash
swift test                                   # unit tests: layout, folders, search, gestures, import, uninstall scan
.build/debug/LaunchMat --selftest           # drives drag & drop, folders, multi-select, import on your real apps (saves nothing)
.build/debug/LaunchMat --snapshot out.png   # renders the UI off-screen (--query, --page, --open-folder, --fresh)
```
The checks that need a person at the trackpad are listed in [TESTING.md](TESTING.md).

## Code map
- `Sources/LaunchMatCore`: pure logic, unit-tested.
  - `PadLayout`: pages, folders, overflow, merge, multi-select grouping.
  - `Search`: weighted prefix/substring scoring with romanized and initial-letter keys.
  - `Gestures`: hot-corner and pinch recognizers.
  - `LegacyLaunchpad`: reads the old Dock database.
  - `RelatedFiles`: finds leftovers in `~/Library`.
- `Sources/LaunchMat`: the app.
  - `LaunchpadModel`: state, drag and drop, paging, keyboard.
  - `Views`: SwiftUI.
  - `WindowController`: full-screen overlay window and Carbon hotkey.
  - `Triggers`: hot corner, pinch event tap, launch at login.
  - `Uninstaller`, `AppScanner`, `AppDelegate`: menu bar.
  - `SettingsWindow`, `GuideWindow`, `WhatsNew`, `EntryMenu`: settings, welcome guide, update card, right-click menus.
  - `Strings`: every piece of interface text goes through `L("key", "English")`.

## Translations
The app's text is English, written in the code next to a stable key. To add a language, run
`./scripts/strings-template.sh > Support/<lang>.lproj/Localizable.strings` (for example `zh-Hans`) and translate the
right-hand sides; `build.sh` copies the folder into the app. Keys you leave out stay in English.

## License
[GPL-3.0](LICENSE). LaunchMat is free software, and so are its forks.

---

## 中文说明

**macOS 26 去掉了启动台（Launchpad），LaunchMat 把它找回来。** 它有全屏应用网格、分页、文件夹、拖拽排序和即时搜索，是原生
Swift 小工具，不联网、不收集任何数据，GPL-3.0 开源免费。

**安装：** 从 [Releases](https://github.com/Jimmygplus/LaunchMat/releases) 下载 DMG，把 LaunchMat 拖进“应用程序”，然后打开。
可以把它拖进 Dock，点一下就能打开或收起。发布版经过苹果签名和公证，双击就能打开。

**用法：**
- **打开/收起：** ⇧⌘空格（菜单里可改）、Dock 图标、菜单栏 ▦ 图标、触发角、触控板捏合都可以。Esc 或点空白处关闭。
- **搜索：** 直接打字，支持首字母（`vsc` → Visual Studio Code）。
- **整理：** 拖动图标排序，拖到屏幕边缘可以换页。把一个应用拖到另一个上停一下就会生成文件夹。
- **多选：** ⌘ 点选多个应用，可以一起拖动，也可以右键批量建文件夹或批量隐藏。
- **卸载：** 按住 ⌥ 图标会抖动，点 ✕ 卸载。卸载前会列出 `~/Library` 里的残留文件，全部移到废纸篓，可以恢复。
- **导入旧布局：** 菜单栏 → *Import System Launchpad Layout…*，从旧版启动台的数据库还原页面和文件夹。

**权限：**
- **辅助功能：** 只有开启触控板捏合时才需要。
- **自动化（访达）：** 只在卸载系统管理员所有的应用时需要，由访达弹出密码框。
