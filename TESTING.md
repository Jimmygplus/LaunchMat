# Manual test checklist

Automated coverage: `swift test` (unit) and `.build/debug/LaunchGrid --selftest` (drag/drop, folders, multi-select,
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
