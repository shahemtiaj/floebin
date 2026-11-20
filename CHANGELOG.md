# Changelog

Every version of Floebin is published on [GitHub Releases](https://github.com/shahemtiaj/floebin/releases) with a DMG. Installed copies find new versions through **Settings → General → Check Now** (or automatically, about once a day) and install them with **Install & Restart**.

## Unreleased

- Floebin is now open source under the MIT License.

## 1.0.0 (2026-11-20)

### New
- **One-click updates**: an update card pops up (even over full-screen apps) with what's new. **Install & Restart** downloads the new version, replaces Floebin and reopens it; **Later** and **Skip This Version** too. The menu bar menu shows **Update to Floebin x.y…** while an update is waiting.
- **About tab** in Settings with version, credits and links.
- Update checks keep running every few hours (about once a day) while Floebin is open.
- Settings shows the current version, when Floebin last checked, and any waiting update.

### Fixed
- All filter chips fit on one line; Fonts and Other no longer disappear.
- Button labels no longer get cut off ("All", "Images", "Set Project Folder").
- Pins follow files you send to a project; removing a pinned file unpins it.
- An open Settings window updates when you change something from a menu.
- Copy File, Copy Path and Copy Source Link confirm with the success pulse.

### Faster
- Opening the list stays quick in Downloads folders with thousands of files.
- Thumbnails refresh when a file is re-downloaded with the same name; the thumbnail cache has a size limit.

## 0.9.0 (2026-11-20)

First public release.

- Floating drop button above every app and Space, including full-screen apps.
- Recent downloads list with live previews (video scrub, audio, ⌥ for a bigger preview), media info, source website and browser icons.
- Filter chips, pins, multi-select drag and full keyboard control (⌃⌥D opens the list anywhere).
- Send to project (sorted into Footage, Audio, Images, Fonts, LUTs), install fonts, copy LUTs, unzip, convert images.
- Watch Desktop, Screenshots or any folder; menu bar mode; Settings window (⌘,); VoiceOver support; first-launch tour.
- Daily update check against GitHub Releases.
