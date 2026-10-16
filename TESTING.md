# Manual test checklist

Automated coverage: `swift test` (unit) and `.build/debug/LaunchMat --selftest` (drag/drop, folders, multi-select,
import, uninstall eligibility on the real app list). The items below need a person, a trackpad and a mouse. Run them
on the **notarized DMG** before tagging a release.

## Install
- [ ] Download the DMG in a browser, open it, drag the app to Applications, launch it. No Gatekeeper warning.
- [ ] The menu-bar ▦ icon appears. There is no Dock icon until you add one.

## Open / close
- [ ] ⇧⌘Space (and each Hotkey preset) opens the grid on the screen with the cursor and closes it again.
- [ ] Clicking the app in the Dock toggles the grid.
- [ ] Esc, clicking empty space, and switching apps (⌘Tab) close it.
- [ ] Hot corner: choose each corner in the menu, move the cursor into it, and the grid toggles. Moving away and back
      toggles it again.
- [ ] Pinch (3 fingers): enable it, grant Accessibility when prompted. Pinching in opens the grid; spreading closes it.
- [ ] Pinch (thumb + 3): the conflict alert appears while the system gesture is on. Turn the system gesture off,
      then retest.

- [ ] Opened by hot corner / pinch while another app is frontmost: the search field has focus and ⌘Tab away hides the grid.
- [ ] ⌘C / ⌘V / ⌘A work in the search field and the folder name; ←/→ move the caret while typing.
- [ ] While the uninstall dialog is open, the hotkey does not cover it.

## Grid
- [ ] A two-finger horizontal swipe follows the fingers and snaps; the first and last pages rubber-band.
- [ ] Mouse wheel: one notch moves one page. Page dots work.
- [ ] Arrow keys move the highlight across page boundaries; Return launches.
- [ ] Grid Size presets reflow without losing apps.

## Drag & drop
- [ ] Dragging an icon makes the others reflow smoothly; dropping keeps the new order after reopening.
- [ ] Holding at the right edge flips the page, and past the last page makes a new one.
- [ ] Hovering over an app's center highlights it; the drop creates a folder that opens with a category name.
- [ ] Dropping onto an existing folder adds the app.
- [ ] In a folder: reordering works, renaming persists, dragging an app out places it where it is dropped, and a folder
      with one app dissolves.

## Multi-select
- [ ] ⌘-click marks several icons with checkmarks; Esc clears them.
- [ ] Dragging one selected icon carries the others (red count badge); they land together in order.
- [ ] Dropping a selection onto an app's center makes one folder with all of them.
- [ ] Right-click → New Folder with N Apps / Hide N Apps.

## Search
- [ ] Typing starts the search at once. `te` puts TextEdit/Terminal before substring hits. A pinyin query matches a
      Chinese-named app. Return launches the first hit.

## Uninstall (use a disposable app)
- [ ] Holding ⌥ makes icons wiggle with ✕ badges, but none on system apps (Safari, Notes…).
- [ ] The dialog lists the `~/Library` leftovers. "Move App and N Files" puts everything in the Trash, and Put Back
      restores it.
- [ ] A running app shows "Quit it first".
- [ ] A root-owned app makes Finder ask for a password.

## Import / login
- [ ] Import System Launchpad Layout reproduces the old pages and folders (on a Mac upgraded from macOS 15 or
      earlier).
- [ ] Launch at Login: toggle it, log out and back in, and the menu-bar icon is there.

## Film takes (`--film-take`, test builds only)
The film's screen recordings are played by the app itself, so nobody has to drive the mouse and no permission is
needed. Each shot hands synthetic events to the app (as `--mouse-test` does; the real pointer is not moved, the film
draws its own) and logs what it did. It uses the saved layout but saves nothing, opens no app and trashes nothing.

```bash
LaunchMat.app/Contents/MacOS/LaunchMat --film-take open --takes ~/x-ops/film/takes --demo-layout ~/x-ops/film/demo-layout.json
```

| Shot | What it does |
|---|---|
| `open` | a beat, then the grid opens (as ⇧⌘Space does), turns to page 2 and back with short drags on blank space; the drawn pointer is hidden meanwhile (page turns are shown as a trackpad swipe) |
| `folder` | holds Music over Podcasts until they make a folder, names it "Listen" (⌘A, Return), closes the folder; writes the layout to `<takes>/folder.layout.json` for the search take's `--demo-layout` |
| `search` | types w, x, deletes them, types v, s, c (no Return) |
| `uninstall` | right-clicks Sketchpad, picks Move to Trash…, shows the leftovers list for about 4 s, then Cancel |
| `close` | Esc closes the grid |

- **Output:** `<takes>/<shot>.actions.jsonl`, one object per line: `{t, type, x, y, t2?, x2?, y2?, text?}`. `type` is
  click, right, drag, key or type. `t` is in seconds since the recording started, read from `<takes>/.<shot>.start`
  (written by `record.sh capture`); without that file, since the take started. `x` and `y` are fractions (0–1) of
  the screen from its top left; a drag ends at (`x2`, `y2`) at `t2`; keys and typed characters are in `text`.
- **Screen:** the built-in display, unless `--screen main`. The first line printed names it and gives its
  `screencapture -D` number. Record that display.
- **Demo layout:** `--demo-layout FILE` shows the film's own grid instead of the saved one (which is neither read nor
  written): system apps and Apple's apps in Launchpad's default arrangement (from the Dock's `LaunchPadLayout.plist`),
  the other system apps by name, then Visual Studio Code, WeChat and the dummy Sketchpad. It is read from FILE when
  that exists, otherwise built and written there. `--film-take layout --demo-layout FILE` only prepares it and
  prints the pages, showing nothing.
- **Staging without a demo layout:** `record.sh prepare` puts Podcasts, Music and the dummy Sketchpad on page 1.
  `--fresh` uses the default arrangement instead; the grid then turns to the right page first.
- **Pointer:** the app draws the system arrow in a window of its own above everything it shows. It glides to each
  action and moves with every synthetic event, so it and a dragged icon follow one path. Record without the system
  pointer.
- **Pacing:** a beat (about 0.45 s) before each action and one after it, per the film's pacing notes.
- A release build refuses `--film-take`. Screen time is shared: ask the coordinator first (`~/jimmy-hq/SCREEN.md`).
