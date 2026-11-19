import AppKit

/// What the Settings window can read and change. AppDelegate provides it.
@MainActor
protocol SettingsHost: AnyObject {
    var showFloatingButton: Bool { get set }
    var menuBarClickShowsRecent: Bool { get set }
    var launchAtLogin: Bool { get set }
    var automaticUpdateChecks: Bool { get set }
    var hotKeyPreset: Int { get set }
    var hotKeyRegistered: Bool { get }

    var buttonSizePoints: Int { get set }
    var buttonPositionLocked: Bool { get set }

    var recentCount: Int { get set }
    var playAudioOnHover: Bool { get set }

    var watchedFolderPaths: [String] { get }
    var projectFolderPath: String? { get }
    var sortIntoTypeFolders: Bool { get set }
    var autoSendToProject: Bool { get set }
    var lutFolderPath: String? { get }

    func moveButton(toSpot index: Int)
    func resetButtonPosition()
    func addWatchedFolder(_ path: String)
    func chooseWatchedFolder()
    func removeWatchedFolder(_ path: String)
    func chooseProjectFolder()
    func clearProjectFolder()
    func chooseLUTFolder()
    func checkForUpdatesNow()
    func showTutorial()
    /// A newer version that's ready to install (nil when up to date).
    var availableUpdateVersion: String? { get }
    func showAvailableUpdate()
}

/// A real Settings window (⌘,) with tabs: General · Button · List · Folders · About.
/// Built from code; it re-reads everything each time it opens or something changes.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    weak var host: SettingsHost?

    private var window: NSWindow?
    private var selectedTab = 0
    private let paneWidth: CGFloat = 540
    private let labelWidth: CGFloat = 170
    private var folderPaths: [String] = []
    private var rebuildScheduled = false

    static let spots = ["Top Left", "Top Right", "Middle Left", "Middle Right", "Bottom Left", "Bottom Right"]
    static let sizes: [(title: String, points: Int)] = [("Small", 44), ("Medium", 54), ("Large", 66)]
    static let counts = [5, 10, 15, 20, 30]

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: paneWidth, height: 400),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Floebin Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
            rebuild()
            window.center()
        } else {
            rebuild()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Call after a setting changes somewhere else (a menu, the list…): updates the window if it's open.
    func refreshIfOpen() {
        guard window?.isVisible == true else { return }
        scheduleRebuild()
    }

    /// Rebuilds on the next run-loop turn, once, even if several things change at once —
    /// and never while a control in the old view is still handling its click.
    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.rebuildScheduled = false
                self?.rebuild()
            }
        }
    }

    /// Re-reads every value (call after anything changes).
    func rebuild() {
        guard let window, host != nil else { return }
        if let current = window.contentViewController as? NSTabViewController {
            selectedTab = current.selectedTabViewItemIndex
        }

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let panes: [(String, String, NSView)] = [
            ("General", "gearshape", generalPane()),
            ("Button", "circle.circle", buttonPane()),
            ("List", "list.bullet.rectangle", listPane()),
            ("Folders", "folder", foldersPane()),
            ("About", "info.circle", aboutPane())
        ]
        for (title, symbol, view) in panes {
            let controller = NSViewController()
            controller.view = view
            controller.preferredContentSize = view.frame.size
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = min(selectedTab, panes.count - 1)
        window.contentViewController = tabs
        window.title = "Floebin Settings"
    }

    // MARK: - Panes

    private func generalPane() -> NSView {
        guard let host else { return NSView() }
        let pane = Pane(width: paneWidth, labelWidth: labelWidth, target: self)

        pane.section("Floebin")
        pane.checkbox("Show the floating button", on: host.showFloatingButton, action: #selector(toggleShowButton(_:)))
        pane.checkbox("Click the menu bar icon to see recent downloads", on: host.menuBarClickShowsRecent,
                      action: #selector(toggleMenuBarClick(_:)),
                      note: "Drag the menu bar icon to drop your newest download. Right-click it for the menu.")
        pane.checkbox("Open Floebin at login", on: host.launchAtLogin, action: #selector(toggleLogin(_:)),
                      note: "Works when Floebin.app is in your Applications folder.")

        pane.section("Keyboard shortcut")
        let popup = pane.popup(label: "Open recent downloads:", items: HotKeyCenter.presets.map { $0.title },
                               selected: host.hotKeyPreset, action: #selector(hotKeyChanged(_:)))
        popup.toolTip = "Opens the list at the mouse pointer, ready for the keyboard"
        if host.hotKeyPreset > 0 && !host.hotKeyRegistered {
            pane.note("⚠️ Another app already uses that shortcut. Pick a different one.", color: .systemOrange)
        }
        pane.note("In the list: ↑↓ move · Space preview · Return open · ⌘C copy file · ⌘R show in Finder · ⌘⌫ remove · ←→ filter · Esc close")

        pane.section("Updates")
        if let newVersion = host.availableUpdateVersion {
            pane.note("✨ Floebin \(newVersion) is ready to install.", color: .controlAccentColor)
            pane.buttons([("Install Update…", #selector(showUpdate)), ("Check Again", #selector(checkNow))])
        } else {
            var status = "You have Floebin \(UpdateChecker.currentVersion)."
            if let last = UpdateChecker.lastCheck {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                status += " Last checked \(formatter.localizedString(for: last, relativeTo: Date()))."
            }
            pane.note(status)
            pane.buttons([("Check Now", #selector(checkNow))])
        }
        pane.checkbox("Check for updates automatically", on: host.automaticUpdateChecks, action: #selector(toggleUpdates(_:)),
                      note: "Floebin looks for a new version about once a day and asks before installing it.")

        pane.section("Help")
        pane.buttons([("Show Tutorial", #selector(showTutorial))])

        return pane.finish()
    }

    private func buttonPane() -> NSView {
        guard let host else { return NSView() }
        let pane = Pane(width: paneWidth, labelWidth: labelWidth, target: self)

        pane.section("Floating button")
        let selectedSize = Self.sizes.firstIndex { $0.points == host.buttonSizePoints } ?? 1
        pane.segmented(label: "Size:", items: Self.sizes.map { $0.title }, selected: selectedSize, action: #selector(sizeChanged(_:)))
        pane.popup(label: "Move to:", items: ["Choose a spot…"] + Self.spots, selected: 0, action: #selector(spotChosen(_:)))
        pane.checkbox("Lock position", on: host.buttonPositionLocked, action: #selector(toggleLock(_:)),
                      note: "Stops the button from being moved by accident.")
        pane.buttons([("Reset Position", #selector(resetPosition))])
        pane.note("Tip: hold ⌥ Option and drag the button to put it anywhere.")

        return pane.finish()
    }

    private func listPane() -> NSView {
        guard let host else { return NSView() }
        let pane = Pane(width: paneWidth, labelWidth: labelWidth, target: self)

        pane.section("Recent downloads")
        let countIndex = Self.counts.firstIndex(of: host.recentCount) ?? 1
        pane.popup(label: "Show:", items: Self.counts.map { $0 == 10 ? "10 files (default)" : "\($0) files" },
                   selected: countIndex, action: #selector(countChanged(_:)))
        pane.checkbox("Play sounds when hovering an audio file", on: host.playAudioOnHover, action: #selector(toggleAudio(_:)))

        pane.section("Tips")
        pane.note("Hover a file to preview it. Videos scrub as you move across the row; hold ⌥ Option for a bigger preview.")
        pane.note("⌘-click or ⇧-click to pick several files, then drag them together.")
        pane.note("Right-click a file to pin it to the top, copy it, send it to your project, install a font, unzip, or convert an image.")

        return pane.finish()
    }

    private func foldersPane() -> NSView {
        guard let host else { return NSView() }
        let pane = Pane(width: paneWidth, labelWidth: labelWidth, target: self)

        pane.section("Watched folders")
        pane.note("New files in these folders show up in Floebin.")
        folderPaths = host.watchedFolderPaths
        for (index, path) in folderPaths.enumerated() {
            pane.folderRow(path: path, removeTag: index, canRemove: folderPaths.count > 1, action: #selector(removeFolder(_:)))
        }
        var adds: [(String, Selector)] = [("Add Folder…", #selector(addFolder))]
        let desktop = NSHomeDirectory() + "/Desktop"
        if !folderPaths.contains(desktop) {
            adds.append(("Add Desktop", #selector(addDesktop)))
        }
        let screenshots = Self.screenshotsFolder()
        if !folderPaths.contains(screenshots) && screenshots != desktop {
            adds.append(("Add Screenshots", #selector(addScreenshots)))
        }
        pane.buttons(adds)

        pane.section("Project folder")
        pane.valueRow(label: "Send files to:", value: host.projectFolderPath.map { Self.prettyPath($0) } ?? "Not set")
        pane.buttons([("Choose…", #selector(chooseProject)), ("Clear", #selector(clearProject))])
        pane.checkbox("Sort into Footage, Audio, Images, Fonts, LUTs…", on: host.sortIntoTypeFolders, action: #selector(toggleSort(_:)))
        let autoSend = pane.checkbox("Automatically send every new download to the project", on: host.autoSendToProject,
                                     action: #selector(toggleAutoSend(_:)))
        autoSend.isEnabled = host.projectFolderPath != nil

        pane.section("LUTs")
        pane.valueRow(label: "LUT folder:", value: host.lutFolderPath.map { Self.prettyPath($0) } ?? "Not set")
        pane.buttons([("Choose…", #selector(chooseLUT))])

        return pane.finish()
    }

    private func aboutPane() -> NSView {
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: paneWidth, height: 420))

        func centered(_ label: NSTextField, y: CGFloat, height: CGFloat) {
            label.alignment = .center
            label.frame = NSRect(x: 20, y: y, width: paneWidth - 40, height: height)
            view.addSubview(label)
        }

        let icon = NSImageView(frame: NSRect(x: (paneWidth - 84) / 2, y: 22, width: 84, height: 84))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(icon)

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        centered(makeLabel("Floebin", size: 22, weight: .bold, color: .labelColor), y: 112, height: 28)
        centered(makeLabel("Version \(version) (\(build))", size: 12, weight: .regular, color: .secondaryLabelColor), y: 142, height: 16)
        centered(makeLabel("Your downloads, one drag away.", size: 12.5, weight: .regular, color: .secondaryLabelColor), y: 162, height: 17)

        let divider = NSBox(frame: NSRect(x: 60, y: 194, width: paneWidth - 120, height: 1))
        divider.boxType = .separator
        view.addSubview(divider)

        centered(makeLabel("DESIGNED & BUILT BY", size: 10, weight: .semibold, color: .tertiaryLabelColor), y: 210, height: 13)
        centered(makeLabel("Shah Emtiaj", size: 17, weight: .semibold, color: .labelColor), y: 226, height: 22)

        let links: [(String, String, String)] = [
            ("shahemtiaj.com", "globe", "https://shahemtiaj.com"),
            ("GitHub", "chevron.left.forwardslash.chevron.right", "https://github.com/shahemtiaj"),
            ("Facebook", "f.square", "https://www.facebook.com/shahemtiaj/"),
            ("X", "x.square", "https://x.com/shahemtiaj")
        ]
        var buttons: [NSButton] = []
        for (title, symbol, address) in links {
            let button = NSButton(title: title, target: self, action: #selector(openLink(_:)))
            button.bezelStyle = .rounded
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.identifier = NSUserInterfaceItemIdentifier(address)
            button.toolTip = address
            button.sizeToFit()
            buttons.append(button)
        }
        let totalWidth = buttons.reduce(CGFloat(0)) { $0 + $1.frame.width } + CGFloat(buttons.count - 1) * 6
        var x = ((paneWidth - totalWidth) / 2).rounded()
        for button in buttons {
            button.frame.origin = NSPoint(x: x, y: 262)
            view.addSubview(button)
            x += button.frame.width + 6
        }

        let project = NSButton(title: "Floebin on GitHub — updates, source and issues", target: self, action: #selector(openLink(_:)))
        project.bezelStyle = .inline
        project.identifier = NSUserInterfaceItemIdentifier("https://github.com/\(UpdateChecker.repository)")
        project.sizeToFit()
        project.frame.origin = NSPoint(x: ((paneWidth - project.frame.width) / 2).rounded(), y: 306)
        view.addSubview(project)

        let year = Calendar.current.component(.year, from: Date())
        centered(makeLabel("© \(year) Shah Emtiaj · Free for everyone", size: 11, weight: .regular, color: .tertiaryLabelColor),
                 y: 344, height: 15)
        return view
    }

    // MARK: - Actions

    @objc private func toggleShowButton(_ sender: NSButton) { host?.showFloatingButton = sender.state == .on; scheduleRebuild() }
    @objc private func toggleMenuBarClick(_ sender: NSButton) { host?.menuBarClickShowsRecent = sender.state == .on }
    @objc private func toggleLogin(_ sender: NSButton) { host?.launchAtLogin = sender.state == .on; scheduleRebuild() }
    @objc private func toggleUpdates(_ sender: NSButton) { host?.automaticUpdateChecks = sender.state == .on }
    @objc private func hotKeyChanged(_ sender: NSPopUpButton) { host?.hotKeyPreset = sender.indexOfSelectedItem; scheduleRebuild() }
    @objc private func checkNow() { host?.checkForUpdatesNow() }
    @objc private func showTutorial() { window?.close(); host?.showTutorial() }
    @objc private func showUpdate() { host?.showAvailableUpdate() }

    @objc private func sizeChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < Self.sizes.count else { return }
        host?.buttonSizePoints = Self.sizes[index].points
    }
    @objc private func spotChosen(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        if index >= 0 {
            host?.moveButton(toSpot: index)
        }
        sender.selectItem(at: 0)
    }
    @objc private func toggleLock(_ sender: NSButton) { host?.buttonPositionLocked = sender.state == .on }
    @objc private func resetPosition() { host?.resetButtonPosition() }

    @objc private func countChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < Self.counts.count else { return }
        host?.recentCount = Self.counts[index]
    }
    @objc private func toggleAudio(_ sender: NSButton) { host?.playAudioOnHover = sender.state == .on }

    @objc private func removeFolder(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < folderPaths.count else { return }
        host?.removeWatchedFolder(folderPaths[sender.tag])
        scheduleRebuild()
    }
    @objc private func addFolder() { host?.chooseWatchedFolder(); scheduleRebuild(); window?.makeKeyAndOrderFront(nil) }
    @objc private func addDesktop() { host?.addWatchedFolder(NSHomeDirectory() + "/Desktop"); scheduleRebuild() }
    @objc private func addScreenshots() { host?.addWatchedFolder(Self.screenshotsFolder()); scheduleRebuild() }
    @objc private func chooseProject() { host?.chooseProjectFolder(); scheduleRebuild(); window?.makeKeyAndOrderFront(nil) }
    @objc private func clearProject() { host?.clearProjectFolder(); scheduleRebuild() }
    @objc private func toggleSort(_ sender: NSButton) { host?.sortIntoTypeFolders = sender.state == .on }
    @objc private func toggleAutoSend(_ sender: NSButton) { host?.autoSendToProject = sender.state == .on }
    @objc private func chooseLUT() { host?.chooseLUTFolder(); scheduleRebuild(); window?.makeKeyAndOrderFront(nil) }
    @objc private func openLink(_ sender: NSButton) {
        if let address = sender.identifier?.rawValue, let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    /// Where macOS saves screenshots (Desktop unless changed in the Screenshot app).
    static func screenshotsFolder() -> String {
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !custom.isEmpty {
            return (custom as NSString).expandingTildeInPath
        }
        return NSHomeDirectory() + "/Desktop"
    }

    static func prettyPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Simple top-down form builder

/// Lays out a settings pane from top to bottom: sections, checkboxes, label + control rows, notes.
@MainActor
private final class Pane {
    let view: FlippedView
    private let width: CGFloat
    private let labelWidth: CGFloat
    private weak var target: AnyObject?
    private var y: CGFloat = 20
    private let left: CGFloat = 28

    init(width: CGFloat, labelWidth: CGFloat, target: AnyObject) {
        self.width = width
        self.labelWidth = labelWidth
        self.target = target
        view = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
    }

    func section(_ title: String) {
        if y > 24 {
            y += 10
        }
        let label = makeLabel(title, size: 13, weight: .semibold, color: .labelColor)
        label.frame = NSRect(x: left, y: y, width: width - left * 2, height: 18)
        view.addSubview(label)
        y += 26
    }

    @discardableResult
    func checkbox(_ title: String, on: Bool, action: Selector, note: String? = nil) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: target, action: action)
        box.state = on ? .on : .off
        box.frame = NSRect(x: left, y: y, width: width - left * 2, height: 20)
        view.addSubview(box)
        y += 24
        if let note {
            let label = makeWrappingLabel(note, size: 11, color: .secondaryLabelColor)
            let height = self.height(of: label, width: width - left * 2 - 20)
            label.frame = NSRect(x: left + 20, y: y - 2, width: width - left * 2 - 20, height: height)
            view.addSubview(label)
            y += height + 4
        }
        return box
    }

    @discardableResult
    func popup(label: String, items: [String], selected: Int, action: Selector) -> NSPopUpButton {
        addRowLabel(label)
        let popup = NSPopUpButton(frame: NSRect(x: left + labelWidth + 8, y: y - 2, width: 220, height: 26), pullsDown: false)
        popup.addItems(withTitles: items)
        popup.selectItem(at: max(0, min(selected, items.count - 1)))
        popup.target = target
        popup.action = action
        view.addSubview(popup)
        y += 32
        return popup
    }

    func segmented(label: String, items: [String], selected: Int, action: Selector) {
        addRowLabel(label)
        let control = NSSegmentedControl(labels: items, trackingMode: .selectOne, target: target, action: action)
        control.selectedSegment = selected
        control.sizeToFit()
        control.frame.origin = NSPoint(x: left + labelWidth + 8, y: y - 2)
        view.addSubview(control)
        y += 32
    }

    func valueRow(label: String, value: String) {
        addRowLabel(label)
        let text = makeLabel(value, size: 12.5, weight: .regular, color: .labelColor)
        text.lineBreakMode = .byTruncatingMiddle
        text.toolTip = value
        text.frame = NSRect(x: left + labelWidth + 8, y: y + 1, width: width - left - labelWidth - 8 - left, height: 17)
        view.addSubview(text)
        y += 26
    }

    func folderRow(path: String, removeTag: Int, canRemove: Bool, action: Selector) {
        let icon = NSImageView(frame: NSRect(x: left, y: y, width: 18, height: 18))
        icon.image = NSWorkspace.shared.icon(forFile: path)
        icon.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(icon)

        let text = makeLabel(SettingsWindowController.prettyPath(path), size: 12.5, weight: .regular, color: .labelColor)
        text.lineBreakMode = .byTruncatingMiddle
        text.toolTip = path
        text.frame = NSRect(x: left + 26, y: y + 1, width: width - left * 2 - 26 - 90, height: 17)
        view.addSubview(text)

        let remove = NSButton(title: "Remove", target: target, action: action)
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        remove.tag = removeTag
        remove.isEnabled = canRemove
        remove.sizeToFit()
        remove.frame.origin = NSPoint(x: width - left - remove.frame.width, y: y - 3)
        view.addSubview(remove)
        y += 28
    }

    func buttons(_ items: [(String, Selector)]) {
        var x = left
        for (title, action) in items {
            let button = NSButton(title: title, target: target, action: action)
            button.bezelStyle = .rounded
            button.sizeToFit()
            button.frame.origin = NSPoint(x: x - 6, y: y - 2)
            view.addSubview(button)
            x += button.frame.width + 4
        }
        y += 34
    }

    func note(_ text: String, color: NSColor = .secondaryLabelColor) {
        let label = makeWrappingLabel(text, size: 11.5, color: color)
        let height = self.height(of: label, width: width - left * 2)
        label.frame = NSRect(x: left, y: y, width: width - left * 2, height: height)
        view.addSubview(label)
        y += height + 6
    }

    /// Final height = content + bottom margin.
    func finish() -> NSView {
        view.frame.size.height = max(y + 20, 320)
        return view
    }

    private func addRowLabel(_ text: String) {
        let label = makeLabel(text, size: 12.5, weight: .regular, color: .labelColor)
        label.alignment = .right
        label.frame = NSRect(x: left, y: y + 1, width: labelWidth, height: 17)
        view.addSubview(label)
    }

    private func height(of label: NSTextField, width: CGFloat) -> CGFloat {
        label.preferredMaxLayoutWidth = width
        let size = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)) ?? NSSize(width: width, height: 16)
        return ceil(size.height)
    }
}
