# Floebin

A small button that floats above every Mac app, full-screen apps included. When a browser download finishes, it appears on the button — drag it straight into Premiere, Resolve, Figma, Slack or anywhere else.

**Version:** 0.9.0 · **Requires:** macOS 13+ · **By** [Shah Emtiaj](https://shahemtiaj.com)

## Build and run

1. Make sure Swift is installed (Xcode, or Command Line Tools: `xcode-select --install`).
2. In Terminal:

   ```bash
   cd path/to/Floe   (the folder with Package.swift)
   bash build.sh
   open build/Floebin.app
   ```

3. The first time, macOS asks: *"Floebin would like to access files in your Downloads folder."* Click **Allow**.

To install for real: `cp -R build/Floebin.app /Applications/`, then turn on **Launch at Login** from the menu bar icon.

## How to use

| Action | What happens |
| --- | --- |
| Download a file in any browser | The button lights up with its thumbnail and pulses |
| Drag the button | Drags the file into the app under your cursor (a copy — the original stays in Downloads) |
| Click the button | Opens your recent downloads, grouped Today / Yesterday / Earlier. Drag any row into an app; click a row to put it on the button; hover a row for 🔍 Show in Finder; right-click for more |
| Option-drag the button | Moves it anywhere (position is remembered, kept on screen) |
| **⌃⌥D** (anywhere) | Opens your recent downloads at the mouse pointer, ready for the keyboard. Change or turn off the shortcut in Settings → General |
| **Settings… (⌘,)** | A Settings window with General · Button · List · Folders tabs (also: right-click menu, menu bar icon, ⚙ in the list) |
| Right-click the button | File actions, Recent Downloads, Settings, Hide, Quit |
| Menu bar icon | About, Show/Hide Floating Button, Recent Downloads, Settings, Launch at Login, Show Tutorial, Quit. A dot appears on it when a new download lands |
| Menu bar mode (Settings → Click Menu Bar Icon for Recent Downloads) | Click the menu bar icon to open your recent downloads under it, drag the icon to drop your newest file, right-click for the menu. Turn off Settings → Show Floating Button for a menu-bar-only setup |

## Working with files

| Feature | How |
| --- | --- |
| **Preview** | Hover a row: videos scrub as you move the mouse across the row, audio plays (Settings → Play Audio on Hover), images show large. **Hold ⌥ Option** for a twice-as-big preview |
| **Filter** | When the list has more than one kind of file, chips appear on top: All · Video · Audio · Image · Font · Other |
| **Pin** | Right-click → Pin to Top. Pinned files stay in a Pinned section above everything else |
| **Keyboard** | ↑↓ move · Space preview · Return open · ⌘C copy file · ⌘R show in Finder · ⌘⌫ remove · ⌘A select all · ←→ change filter · Esc close |
| **More folders** | Settings → Folders → Add Desktop / Add Screenshots / Add Folder… New files there show up too (Auto-Send only applies to Downloads) |
| **Several files at once** | ⌘-click or ⇧-click rows, then drag any selected row — they all go together. Right-click acts on the whole selection |
| **Media info** | Each row shows duration · resolution · fps (video), duration · sample rate (audio), or pixel size (images) |
| **Source tracking** | Each row shows the website it came from. Right-click → Open Source Page / Copy Source Link (handy for licenses and credits) |
| **Send to project** | Footer → Set Project Folder. Then hover a row → 📁+, or right-click → Send to “Project”. Files are sorted into Footage / Audio / Images / Fonts / LUTs / Documents. Turn on Auto-Send to file every new download automatically |
| **Smart actions** (right-click) | Fonts → Install Font · LUTs → Copy to LUT Folder · ZIPs → Unzip · Images → Convert to PNG / JPG |

## Project layout

```
Package.swift                     Swift package (no Xcode project needed)
Sources/Floebin/FloebinApp.swift        Entry point (menu-bar-only app)
Sources/Floebin/AppDelegate.swift    Floating panel, menus, recent list, launch at login
Sources/Floebin/DownloadWatcher.swift  Watches ~/Downloads, ignores unfinished files
Sources/Floebin/FloeButtonView.swift   The round button: thumbnail, drag-out, pulse
Sources/Floebin/RecentListController.swift  The recent-downloads list and its draggable rows
Sources/Floebin/Thumbnails.swift       Quick Look thumbnails with a cache
Sources/Floebin/AboutController.swift    About Floebin — version and credits
Sources/Floebin/TutorialController.swift  First-launch step-by-step tour (skippable)
Sources/Floebin/StatusIconView.swift  Menu bar icon: click for recents, drag the newest file
Sources/Floebin/Styles.swift           Floebin mark, file-type badges, pill buttons, floating panels
Sources/Floebin/PreviewController.swift  Hover preview card (video scrub, audio play)
Sources/Floebin/MediaInfo.swift        Duration / resolution / fps / sample rate + download source
Sources/Floebin/FileActions.swift      File menus, send to project, install font, unzip, convert
Sources/Floebin/SettingsWindowController.swift  The Settings window (⌘,)
Sources/Floebin/HotKey.swift           Global keyboard shortcut
Sources/Floebin/UpdateChecker.swift    Checks GitHub Releases for a newer version
Resources/Info.plist              App bundle settings (LSUIElement = no Dock icon)
Resources/AppIcon.iconset/        App icon PNGs (build.sh turns them into AppIcon.icns)
Resources/AppIcon.svg             Icon source artwork
build.sh                          Builds and signs build/Floebin.app
release.sh                        Signed + notarized Floebin.dmg for sharing (needs Developer ID)
```

Open it in Xcode with `open Package.swift` if you prefer.

## Signing

`build.sh` picks the best signature it can find:

1. **Developer ID Application** (paid Apple Developer account) — required to share Floebin with other people.
2. **Floebin Local** — a free certificate you make once. macOS then remembers Floebin's Downloads permission across rebuilds.
3. **Ad-hoc** — works on this Mac only; macOS may ask for Downloads access again after each rebuild.

To make **Floebin Local** (one time, 1 minute): open **Keychain Access** → menu **Keychain Access → Certificate Assistant → Create a Certificate…** → Name: `Floebin Local`, Identity Type: *Self Signed Root*, Certificate Type: *Code Signing* → Create. Then run `bash build.sh` again.

## Sharing and updates

1. With a Developer ID set up (see the notes at the top of `release.sh`), run `bash release.sh`. You get `build/Floebin-0.9.0.dmg`, signed, notarized and stapled, so it opens on any Mac without warnings.
2. Create a GitHub release at `github.com/shahemtiaj/floebin` with the tag `v0.9.0` and attach the DMG.
3. Every copy of Floebin checks once a day (Settings → General → Check for updates automatically) and offers the new version. You can also check from the menu bar icon → Check for Updates….

Remember to bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` before each release.

## Known limits

- Not sandboxed, so this build isn't ready for the Mac App Store yet.
- Updates open the download page; they don't install themselves yet.

## Next

- Search in the list
- Clean up stock-site file names
- Drop files onto Floebin (two-way shelf)

## Credits

Floebin is designed and built by **Shah Emtiaj**.

- Website: [shahemtiaj.com](https://shahemtiaj.com)
- GitHub: [github.com/shahemtiaj](https://github.com/shahemtiaj)
- Facebook: [facebook.com/shahemtiaj](https://www.facebook.com/shahemtiaj/)
- X: [x.com/shahemtiaj](https://x.com/shahemtiaj)
