import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: Settings
    private let idleAlpha: CGFloat = 0.5
    private var maxRecent = 10
    private let recentCounts = [5, 10, 15, 20, 30]
    private let freshDuration: TimeInterval = 90 // how long a new file stays fully bright

    private let recentCountKey = "FloeRecentCount"
    private let originKey = "FloeButtonOrigin"
    private let lockKey = "FloeLockPosition"
    private let sizeKey = "FloeButtonSize"
    private let welcomeKey = "FloeWelcomeShown"        // older builds
    private let tutorialKey = "FloebinTutorialDone"
    private let showButtonKey = "FloebinShowButton"
    private let statusClickKey = "FloebinStatusClickShowsRecent"
    private let playAudioKey = "FloePlayAudioOnHover"
    private let hiddenKey = "FloebinHiddenPaths"      // "Remove from List" — remembered across launches
    private let clearedKey = "FloebinClearedAt"       // "Clear" — files from before this stay hidden
    private let foldersKey = "FloebinWatchedFolders"
    private let pinnedKey = "FloebinPinned"
    private let hotKeyKey = "FloebinHotKey"

    /// Preset spots for the button, on whichever screen it's currently on.
    private enum Spot: String, CaseIterable {
        case topLeft, topRight, middleLeft, middleRight, bottomLeft, bottomRight

        var title: String {
            switch self {
            case .topLeft: return "Top Left"
            case .topRight: return "Top Right"
            case .middleLeft: return "Middle Left"
            case .middleRight: return "Middle Right"
            case .bottomLeft: return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            }
        }
    }

    private let sizes: [(title: String, points: Int)] = [("Small", 44), ("Medium", 54), ("Large", 66)]

    // MARK: State
    private var buttonSize: CGFloat = 54
    private var panel: NSPanel!
    private var button: FloeButtonView!
    private var list: RecentListController!
    private var tutorial: TutorialController!
    private var about: AboutController!
    private var actions: FileActionCenter!
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusIconView: StatusIconView?
    private var watchers: [DownloadWatcher] = []
    private var settingsWindow: SettingsWindowController!
    private var updater: UpdateChecker!
    private var hotKeyOK = true
    private var pinnedList: [String] = []
    private var recent: [URL] = []
    private var hasFreshFile = false
    private var isHovering = false
    private var isDownloading = false
    private var idleTimer: Timer?
    private var hiddenList: [String] = []
    private var hiddenSet = Set<String>()

    private let downloadsURL: URL =
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        replaceOtherCopies()

        UserDefaults.standard.register(defaults: [
            playAudioKey: true,
            showButtonKey: true,
            hotKeyKey: HotKeyCenter.defaultPreset,
            UpdateChecker.autoKey: true,
            FileActionCenter.sortKey: true
        ])

        let savedSize = UserDefaults.standard.integer(forKey: sizeKey)
        if sizes.contains(where: { $0.points == savedSize }) {
            buttonSize = CGFloat(savedSize)
        }
        let savedCount = UserDefaults.standard.integer(forKey: recentCountKey)
        if recentCounts.contains(savedCount) {
            maxRecent = savedCount
        }
        hiddenList = UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []
        hiddenSet = Set(hiddenList)
        pinnedList = UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []

        setupActions()
        setupPanel()
        setupList()
        setupTutorial()
        about = AboutController()
        setupStatusItem()
        startWatching()

        settingsWindow = SettingsWindowController()
        settingsWindow.host = self

        updater = UpdateChecker()
        updater.beforeAlert = { [weak self] in
            self?.list.hide()
            self?.tutorial.hide()
        }

        HotKeyCenter.action = { [weak self] in
            self?.toggleListAtCursor()
        }
        registerHotKey()

        // Quiet daily update check, a little after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated { self?.updater.checkIfDue() }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // First launch only: people who already finished (or skipped) the tour never see it again.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: tutorialKey) && !defaults.bool(forKey: welcomeKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.showTutorial() }
            }
        }
    }

    // MARK: - One copy at a time

    /// Quits older builds (the "Floe" era) and any other running copy of Floebin,
    /// so there's only ever one floating button. The newest launch wins.
    private func replaceOtherCopies() {
        let me = NSRunningApplication.current.processIdentifier
        let ids = [Bundle.main.bundleIdentifier ?? "", "com.shahusamah.floe", "com.shahusamah.floebin"]
        for id in ids where !id.isEmpty {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where app.processIdentifier != me {
                app.terminate()
            }
        }
    }

    // MARK: - Floating button

    private func setupPanel() {
        let origin = savedOrigin() ?? defaultOrigin()
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: buttonSize, height: buttonSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // These lines keep Floebin above everything, including full-screen apps,
        // without ever stealing focus from the app you're working in.
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        installButton()
        panel.alphaValue = idleAlpha
        if isButtonShown {
            panel.orderFrontRegardless()
        }
    }

    /// Creates the button view at the current size (also used when the size changes).
    private func installButton() {
        let old: FloeButtonView? = button
        let newButton = FloeButtonView(frame: NSRect(x: 0, y: 0, width: buttonSize, height: buttonSize))
        newButton.allowsMoving = !UserDefaults.standard.bool(forKey: lockKey)
        newButton.idleMessage = old?.idleMessage ?? "Floebin — waiting for your next download"
        newButton.isDownloading = isDownloading
        newButton.fileURL = old?.fileURL

        newButton.onMoved = { [weak self] origin in
            self?.finishMove(origin)
        }
        newButton.onHover = { [weak self] inside in
            guard let self else { return }
            self.isHovering = inside
            self.updateAlpha(animated: true)
        }
        newButton.onDropped = { [weak self] in
            self?.fileWasDropped()
        }
        newButton.onClick = { [weak self] in
            self?.toggleList()
        }
        newButton.onFileMissing = { [weak self] in
            self?.pruneMissing()
        }
        newButton.menuProvider = { [weak self] in
            self?.buildButtonMenu() ?? NSMenu()
        }

        button = newButton
        panel.contentView = newButton
    }

    private func updateAlpha(animated: Bool) {
        let touring = tutorial?.isVisible ?? false
        let target: CGFloat = (hasFreshFile || isHovering || isDownloading || touring) ? 1.0 : idleAlpha
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.panel.animator().alphaValue = target
            }
        } else {
            panel.alphaValue = target
        }
    }

    // MARK: - Recent downloads list

    private func setupActions() {
        actions = FileActionCenter()
        actions.onMoved = { [weak self] old, new in
            self?.replace(old, with: new)
        }
        actions.onRemoveFromList = { [weak self] urls in
            self?.remove(urls)
        }
        actions.onSuccess = { [weak self] in
            self?.button.showSuccess()
        }
        actions.isPinned = { [weak self] url in
            self?.pinnedList.contains(url.path) ?? false
        }
        actions.onPin = { [weak self] urls, pin in
            self?.setPinned(urls, pin)
        }
        actions.onProjectChanged = { [weak self] in
            guard let self else { return }
            self.list.refresh(files: self.recent, anchor: self.panel.frame)
        }
        actions.beforeModal = { [weak self] in
            self?.list.hide()
            self?.tutorial.hide()
        }
    }

    private func setupList() {
        list = RecentListController()
        list.onSelect = { [weak self] url in
            self?.select(url)
        }
        list.fileMenuProvider = { [weak self] urls in
            self?.actions.menu(for: urls) ?? NSMenu()
        }
        list.projectMenuProvider = { [weak self] in
            self?.actions.projectMenu() ?? NSMenu()
        }
        list.projectNameProvider = { [weak self] in
            self?.actions.projectName
        }
        list.onSendToProject = { [weak self] urls in
            self?.actions.perform(.sendToProject, on: urls)
        }
        let audioKey = playAudioKey
        list.preview.playsAudioOnHover = {
            UserDefaults.standard.bool(forKey: audioKey)
        }
        list.onClear = { [weak self] in
            self?.clearRecent()
        }
        list.onDropped = { [weak self] in
            self?.button.showSuccess()
            self?.fileWasDropped()
        }
        list.openDownloads = { [weak self] in
            self?.openDownloadsFolder()
        }
        list.settingsMenuProvider = { [weak self] in
            self?.settingsMenu() ?? NSMenu()
        }
        list.pinnedProvider = { [weak self] in
            self?.pinnedList.map { URL(fileURLWithPath: $0) } ?? []
        }
        list.onKeyboardAction = { [weak self] action, urls in
            self?.actions.perform(action, on: urls)
        }
        list.onHide = { [weak self] in
            guard let self else { return }
            self.statusItem?.button?.highlight(false)
            self.tutorial.resumeIfSuspended(anchor: self.cardAnchor)
        }
    }

    private func toggleList() {
        tutorial.suspend()
        pruneMissing()
        setStatusBadge(false)
        list.toggle(files: recent, anchor: panel.frame)
    }

    @objc private func showList() {
        tutorial.suspend()
        pruneMissing()
        setStatusBadge(false)
        if isButtonShown {
            list.show(files: recent, anchor: panel.frame)
        } else {
            list.show(files: recent, anchor: statusIconRect(), placement: .below)
        }
    }

    /// From the menu bar icon (when "Click Menu Bar Icon for Recent Downloads" is on).
    private func toggleListFromStatus() {
        tutorial.suspend()
        pruneMissing()
        setStatusBadge(false)
        list.toggle(files: recent, anchor: statusIconRect(), placement: .below)
        statusItem.button?.highlight(list.isVisible)
    }

    /// From the keyboard shortcut: the list opens at the mouse pointer, ready for the keyboard.
    private func toggleListAtCursor() {
        if list.isVisible {
            list.hide()
            return
        }
        tutorial.suspend()
        about.hide()
        pruneMissing()
        setStatusBadge(false)
        let mouse = NSEvent.mouseLocation
        list.show(files: recent, anchor: NSRect(x: mouse.x, y: mouse.y, width: 1, height: 1),
                  placement: .below, focusKeyboard: true)
    }

    private func registerHotKey() {
        hotKeyOK = HotKeyCenter.register(presetIndex: UserDefaults.standard.integer(forKey: hotKeyKey))
    }

    // MARK: - Pins

    private func setPinned(_ urls: [URL], _ pin: Bool) {
        for url in urls {
            pinnedList.removeAll { $0 == url.path }
            if pin {
                pinnedList.insert(url.path, at: 0)
            }
        }
        UserDefaults.standard.set(pinnedList, forKey: pinnedKey)
        list.refresh(files: recent, anchor: panel.frame)
    }

    /// Where helper cards (tour, About) should appear: by the button, or by the menu bar icon if it's hidden.
    private var cardAnchor: NSRect {
        isButtonShown ? panel.frame : statusIconRect()
    }

    // MARK: - Tutorial

    private func setupTutorial() {
        tutorial = TutorialController()
        tutorial.onFinish = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(true, forKey: self.tutorialKey)
            self.updateAlpha(animated: true)
        }
        tutorial.onStepShown = { [weak self] step in
            guard let self else { return }
            self.updateAlpha(animated: true)
            switch step {
            case 1, 4: self.button.pulse()                    // "Meet your button", "Click the button"
            case 3: self.button.pulse(color: .systemGreen)    // "Drag it anywhere"
            default: break
            }
        }
    }

    @objc func showTutorial() {
        list.hide()
        about.hide()
        tutorial.start(anchor: cardAnchor)
    }

    @objc private func showAbout() {
        list.hide()
        tutorial.hide()
        about.show(near: cardAnchor)
    }


    // MARK: - Position & size

    private func currentScreen() -> NSScreen {
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func origin(for spot: Spot) -> NSPoint {
        let vf = currentScreen().visibleFrame
        let margin: CGFloat = 16
        let left = vf.minX + margin
        let right = vf.maxX - buttonSize - margin
        let high = vf.maxY - buttonSize - margin
        let low = vf.minY + margin
        let middle = vf.midY - buttonSize / 2

        switch spot {
        case .topLeft: return NSPoint(x: left, y: high)
        case .topRight: return NSPoint(x: right, y: high)
        case .middleLeft: return NSPoint(x: left, y: middle)
        case .middleRight: return NSPoint(x: right, y: middle)
        case .bottomLeft: return NSPoint(x: left, y: low)
        case .bottomRight: return NSPoint(x: right, y: low)
        }
    }

    private func defaultOrigin() -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: frame.maxX - buttonSize - 16, y: frame.minY + 120)
    }

    private func savedOrigin() -> NSPoint? {
        guard let string = UserDefaults.standard.string(forKey: originKey) else { return nil }
        let point = NSPointFromString(string)
        return isOnScreen(point) ? point : nil
    }

    private func saveOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(NSStringFromPoint(origin), forKey: originKey)
    }

    private func isOnScreen(_ origin: NSPoint) -> Bool {
        let center = NSPoint(x: origin.x + buttonSize / 2, y: origin.y + buttonSize / 2)
        return NSScreen.screens.contains { $0.frame.contains(center) }
    }

    /// Keep the button fully on screen and remember the spot.
    private func finishMove(_ origin: NSPoint) {
        list.hide()
        let vf = currentScreen().visibleFrame
        let x = min(max(origin.x, vf.minX + 4), vf.maxX - buttonSize - 4)
        let y = min(max(origin.y, vf.minY + 4), vf.maxY - buttonSize - 4)
        let clamped = NSPoint(x: x, y: y)
        if clamped != panel.frame.origin {
            panel.setFrameOrigin(clamped)
        }
        saveOrigin(clamped)
        tutorial.follow(anchor: panel.frame)
    }

    private func moveButton(to origin: NSPoint) {
        list.hide()
        panel.setFrameOrigin(origin)
        saveOrigin(origin)
        if isButtonShown {
            panel.orderFrontRegardless()
        }
        button.pulse()
        tutorial.follow(anchor: panel.frame)
    }

    @objc private func moveToSpot(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let spot = Spot(rawValue: raw) else { return }
        moveButton(to: origin(for: spot))
    }

    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: originKey)
        moveButton(to: defaultOrigin())
    }

    @objc private func toggleLock() {
        let locked = !UserDefaults.standard.bool(forKey: lockKey)
        UserDefaults.standard.set(locked, forKey: lockKey)
        button.allowsMoving = !locked
    }

    @objc private func changeSize(_ sender: NSMenuItem) {
        applyButtonSize(sender.tag)
    }

    private func applyButtonSize(_ points: Int) {
        let newSize = CGFloat(points)
        guard sizes.contains(where: { $0.points == points }), newSize != buttonSize else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        buttonSize = newSize
        UserDefaults.standard.set(points, forKey: sizeKey)

        panel.setFrame(NSRect(x: center.x - newSize / 2, y: center.y - newSize / 2, width: newSize, height: newSize), display: true)
        installButton()
        finishMove(panel.frame.origin)
        button.pulse()
    }

    @objc private func screensChanged() {
        if !isOnScreen(panel.frame.origin) {
            panel.setFrameOrigin(defaultOrigin())
        }
    }

    /// Settings: position, size, list length, lock. Shown from the list's gear,
    /// the button's right-click menu and the menu bar icon.
    private func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open Settings Window…", #selector(openSettings), symbol: "macwindow"))
        menu.addItem(.separator())

        let projectTitle = actions.projectName.map { "Project: \($0)" } ?? "Project Folder"
        menu.addItem(submenuItem(projectTitle, symbol: "folder", submenu: actions.projectMenu()))
        menu.addItem(.separator())

        let positionMenu = NSMenu()
        for spot in Spot.allCases {
            let entry = item(spot.title, #selector(moveToSpot(_:)))
            entry.representedObject = spot.rawValue
            positionMenu.addItem(entry)
        }
        positionMenu.addItem(.separator())
        positionMenu.addItem(disabledItem("Tip: Option-drag the button to move it anywhere"))
        menu.addItem(submenuItem("Button Position", symbol: "arrow.up.and.down.and.arrow.left.and.right", submenu: positionMenu))

        let sizeMenu = NSMenu()
        for size in sizes {
            let entry = item(size.title, #selector(changeSize(_:)))
            entry.tag = size.points
            entry.state = Int(buttonSize) == size.points ? .on : .off
            sizeMenu.addItem(entry)
        }
        menu.addItem(submenuItem("Button Size", symbol: "circle.circle", submenu: sizeMenu))

        let countMenu = NSMenu()
        for count in recentCounts {
            let entry = item(count == 10 ? "10 (default)" : "\(count)", #selector(changeRecentCount(_:)))
            entry.tag = count
            entry.state = count == maxRecent ? .on : .off
            countMenu.addItem(entry)
        }
        menu.addItem(submenuItem("Recent Downloads to Show", symbol: "list.number", submenu: countMenu))

        let audio = item("Play Audio on Hover", #selector(toggleAudioPreview), symbol: "speaker.wave.2")
        audio.state = UserDefaults.standard.bool(forKey: playAudioKey) ? .on : .off
        menu.addItem(audio)
        menu.addItem(.separator())

        menu.addItem(disabledItem("Menu Bar"))
        let statusClick = item("Click Menu Bar Icon for Recent Downloads", #selector(toggleStatusClick), symbol: "menubar.arrow.down.rectangle")
        statusClick.state = statusClickShowsRecent ? .on : .off
        statusClick.toolTip = "Click the icon for your recent files, drag from it for the newest one. Right-click for this menu."
        menu.addItem(statusClick)
        let showButton = item("Show Floating Button", #selector(toggleVisible), symbol: "circle.circle")
        showButton.state = isButtonShown ? .on : .off
        menu.addItem(showButton)
        menu.addItem(.separator())

        let lock = item("Lock Position", #selector(toggleLock), symbol: "lock")
        lock.state = UserDefaults.standard.bool(forKey: lockKey) ? .on : .off
        menu.addItem(lock)
        menu.addItem(item("Reset Position", #selector(resetPosition), symbol: "arrow.counterclockwise"))
        return menu
    }

    private func submenuItem(_ title: String, symbol: String, submenu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        entry.submenu = submenu
        return entry
    }

    private func settingsSubmenuItem() -> NSMenuItem {
        submenuItem("Settings", symbol: "gearshape", submenu: settingsMenu())
    }

    @objc private func toggleAudioPreview() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: playAudioKey), forKey: playAudioKey)
    }

    @objc private func changeRecentCount(_ sender: NSMenuItem) {
        applyRecentCount(sender.tag)
    }

    private func applyRecentCount(_ count: Int) {
        guard recentCounts.contains(count), count != maxRecent else { return }
        maxRecent = count
        UserDefaults.standard.set(maxRecent, forKey: recentCountKey)

        // Refill at the new length (keeps files you already sent to a project).
        recent = mergedRecent()
        if button.fileURL == nil {
            button.fileURL = recent.first
        }
        list.refresh(files: recent, anchor: panel.frame)
    }

    // MARK: - Downloads

    /// Downloads by default; more folders (Desktop, Screenshots, your own) can be added in Settings.
    private var watchedFolderList: [String] {
        let saved = UserDefaults.standard.stringArray(forKey: foldersKey) ?? []
        return saved.isEmpty ? [downloadsURL.path] : saved
    }

    private func startWatching() {
        watchers.forEach { $0.stop() }

        var newWatchers: [DownloadWatcher] = []
        for path in watchedFolderList {
            let folderName = URL(fileURLWithPath: path).lastPathComponent
            let watcher = DownloadWatcher(folder: URL(fileURLWithPath: path))
            watcher.onNewFile = { [weak self] url in
                self?.handleNewFile(url)
            }
            watcher.onDownloadingChanged = { [weak self] _ in
                self?.updateDownloadingState()
            }
            watcher.onAccessDenied = { [weak self] in
                self?.button.idleMessage = "Floebin needs access to “\(folderName)”: System Settings → Privacy & Security → Files and Folders"
            }
            watcher.onStarted = { [weak self] in
                guard let self else { return }
                self.button.idleMessage = "Floebin — waiting for your next download"
                // Fill the list with what's already in the watched folders.
                self.recent = self.mergedRecent()
                if self.button.fileURL == nil {
                    self.button.fileURL = self.recent.first
                }
                self.list.refresh(files: self.recent, anchor: self.panel.frame)
            }
            newWatchers.append(watcher)
        }
        watchers = newWatchers
        watchers.forEach { $0.start() }
    }

    private func updateDownloadingState() {
        let downloading = watchers.contains { $0.isDownloadingNow }
        isDownloading = downloading
        button.isDownloading = downloading
        updateAlpha(animated: true)
    }

    private func saveWatchedFolders(_ paths: [String]) {
        // Files from a folder that's no longer watched leave the list.
        let removed = Set(watchedFolderList).subtracting(paths)
        recent.removeAll { removed.contains($0.deletingLastPathComponent().path) }
        UserDefaults.standard.set(paths, forKey: foldersKey)
        startWatching()
        recent = mergedRecent()
        list.refresh(files: recent, anchor: panel.frame)
    }

    private func handleNewFile(_ newFile: URL) {
        // Auto-Send: move it straight into the project folder.
        unhide(newFile.path)   // downloaded again after being removed from the list
        // Auto-Send only applies to real downloads (not Desktop or Screenshots).
        let fromDownloads = newFile.deletingLastPathComponent().standardizedFileURL.path == downloadsURL.standardizedFileURL.path
        let url = (fromDownloads ? actions.autoSendIfEnabled(newFile) : nil) ?? newFile
        recent.removeAll { $0.path == url.path }
        recent.insert(url, at: 0)
        if recent.count > maxRecent {
            recent.removeLast(recent.count - maxRecent)
        }
        makeCurrent(url)
        list.refresh(files: recent, anchor: panel.frame)
    }

    private func select(_ url: URL) {
        recent.removeAll { $0.path == url.path }
        recent.insert(url, at: 0)
        makeCurrent(url)
    }

    private func remove(_ urls: [URL]) {
        let paths = Set(urls.map(\.path))
        for path in paths where !hiddenSet.contains(path) {
            hiddenList.append(path)
            hiddenSet.insert(path)
        }
        if hiddenList.count > 500 {
            let extra = hiddenList.count - 500
            hiddenSet.subtract(hiddenList.prefix(extra))
            hiddenList.removeFirst(extra)
        }
        UserDefaults.standard.set(hiddenList, forKey: hiddenKey)

        recent = mergedRecent()   // the next-newest file moves up into the list
        if let current = button.fileURL, paths.contains(current.path) {
            button.fileURL = recent.first
            hasFreshFile = false
            updateAlpha(animated: true)
        }
        list.refresh(files: recent, anchor: panel.frame)
    }

    /// A file moved (e.g. sent to the project): keep it in the list at its new location.
    private func replace(_ old: URL, with new: URL) {
        if let index = recent.firstIndex(where: { $0.path == old.path }) {
            recent[index] = new
        }
        if button.fileURL?.path == old.path {
            button.fileURL = new
        }
        list.refresh(files: recent, anchor: panel.frame)
    }

    private func clearRecent() {
        // Everything downloaded up to now stays out of the list, even after a restart.
        UserDefaults.standard.set(Date(), forKey: clearedKey)
        recent.removeAll()
        button.fileURL = nil
        hasFreshFile = false
        updateAlpha(animated: true)
        list.refresh(files: recent, anchor: panel.frame)
    }

    private func makeCurrent(_ url: URL) {
        button.fileURL = url
        hasFreshFile = true
        if !list.isVisible {
            setStatusBadge(true)
        }
        updateAlpha(animated: true)
        button.pulse()

        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: freshDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hasFreshFile = false
                self?.updateAlpha(animated: true)
            }
        }
    }

    private func fileWasDropped() {
        setStatusBadge(false)
        idleTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.hasFreshFile = false
                self?.updateAlpha(animated: true)
            }
        }
    }

    /// Drop files that were moved or deleted since they downloaded, and top the list back up.
    private func pruneMissing() {
        recent = mergedRecent()
        if let current = button.fileURL, !FileManager.default.fileExists(atPath: current.path) {
            button.fileURL = recent.first
        }
    }

    /// The list as it should be: what's already in it (including files sent to a project)
    /// plus the newest files in Downloads — minus deleted, removed or cleared ones — newest first.
    private func mergedRecent() -> [URL] {
        let fm = FileManager.default
        let fromFolder = watchers.flatMap { watcher in
            watcher.latestFiles(limit: maxRecent, excluding: { url in self.isHidden(url) })
        }
        var seenPaths = Set<String>()
        var merged: [URL] = []
        for url in recent + fromFolder where !seenPaths.contains(url.path) {
            seenPaths.insert(url.path)
            if fm.fileExists(atPath: url.path) && !isHidden(url) {
                merged.append(url)
            }
        }
        merged.sort { (FileDates.added($0) ?? .distantPast) > (FileDates.added($1) ?? .distantPast) }
        return Array(merged.prefix(maxRecent))
    }

    private func isHidden(_ url: URL) -> Bool {
        if hiddenSet.contains(url.path) {
            return true
        }
        if let cleared = UserDefaults.standard.object(forKey: clearedKey) as? Date,
           let added = FileDates.added(url), added <= cleared {
            return true
        }
        return false
    }

    private func unhide(_ path: String) {
        guard hiddenSet.contains(path) else { return }
        hiddenSet.remove(path)
        hiddenList.removeAll { $0 == path }
        UserDefaults.standard.set(hiddenList, forKey: hiddenKey)
    }

    // MARK: - Right-click menu on the button

    private func buildButtonMenu() -> NSMenu {
        list.hide()
        pruneMissing()
        // File actions for the button's current file (open, send to project, install font…)
        let menu: NSMenu
        if let current = button.fileURL {
            menu = actions.menu(for: [current])
            menu.addItem(.separator())
        } else {
            menu = NSMenu()
        }

        menu.addItem(item("Recent Downloads", #selector(showList), symbol: "list.bullet.rectangle"))
        menu.addItem(settingsSubmenuItem())
        menu.addItem(item("Settings…", #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(item("Open Downloads Folder", #selector(openDownloadsFolder), symbol: "arrow.down.circle"))
        menu.addItem(.separator())
        menu.addItem(item("About Floebin", #selector(showAbout), symbol: "info.circle"))
        menu.addItem(item("Hide Floating Button", #selector(toggleVisible)))
        menu.addItem(item("Quit Floebin", #selector(quit)))
        return menu
    }

    // MARK: - Menu bar icon

    private var isButtonShown: Bool {
        UserDefaults.standard.bool(forKey: showButtonKey)
    }

    private var statusClickShowsRecent: Bool {
        UserDefaults.standard.bool(forKey: statusClickKey)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Glyph.floe(size: 18)
        statusItem.button?.toolTip = "Floebin"
        statusMenu = NSMenu()
        statusMenu.delegate = self
        applyStatusMode()
    }

    /// Menu mode: clicking the icon opens the menu.
    /// Recent mode: clicking opens the recent list, dragging pulls out the newest file, right-click opens the menu.
    private func applyStatusMode() {
        guard let statusButton = statusItem.button else { return }
        if statusClickShowsRecent {
            statusItem.menu = nil
            if statusIconView == nil {
                let overlay = StatusIconView(frame: statusButton.bounds)
                overlay.autoresizingMask = [.width, .height]
                overlay.fileProvider = { [weak self] in
                    guard let self else { return nil }
                    self.pruneMissing()
                    return self.button.fileURL ?? self.recent.first
                }
                overlay.onClick = { [weak self] in
                    self?.toggleListFromStatus()
                }
                overlay.onMenu = { [weak self] in
                    self?.showStatusMenu()
                }
                overlay.onDropped = { [weak self] in
                    self?.setStatusBadge(false)
                    self?.fileWasDropped()
                }
                statusButton.addSubview(overlay)
                statusIconView = overlay
            }
            statusButton.toolTip = "Floebin — click for recent downloads, drag for the newest, right-click for menu"
        } else {
            statusIconView?.removeFromSuperview()
            statusIconView = nil
            statusItem.menu = statusMenu
            statusButton.toolTip = "Floebin"
        }
    }

    private func showStatusMenu() {
        list.hide()
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)   // opens the menu (blocks until it closes)
        statusItem.menu = nil
    }

    private func statusIconRect() -> NSRect {
        guard let statusButton = statusItem?.button, let window = statusButton.window else {
            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSRect(x: screen.maxX - 200, y: screen.maxY - 24, width: 24, height: 24)
        }
        return window.convertToScreen(statusButton.convert(statusButton.bounds, to: nil))
    }

    private func setStatusBadge(_ on: Bool) {
        statusItem?.button?.image = Glyph.floe(size: 18, badge: on)
    }

    @objc private func toggleStatusClick() {
        UserDefaults.standard.set(!statusClickShowsRecent, forKey: statusClickKey)
        applyStatusMode()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("About Floebin", #selector(showAbout), symbol: "info.circle"))
        menu.addItem(.separator())
        menu.addItem(item(isButtonShown ? "Hide Floating Button" : "Show Floating Button", #selector(toggleVisible)))
        menu.addItem(item("Recent Downloads", #selector(showList), symbol: "list.bullet.rectangle"))
        menu.addItem(settingsSubmenuItem())
        menu.addItem(item("Settings…", #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdatesFromMenu), symbol: "arrow.triangle.2.circlepath"))
        menu.addItem(.separator())

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Show Tutorial", #selector(showTutorial), symbol: "graduationcap"))
        menu.addItem(item("Open Downloads Folder", #selector(openDownloadsFolder), symbol: "arrow.down.circle"))
        menu.addItem(.separator())
        menu.addItem(item("Quit Floebin", #selector(quit), key: "q"))
    }

    /// Show / hide the floating button (remembered). The menu bar icon always stays.
    @objc private func toggleVisible() {
        list.hide()
        tutorial.hide()
        let show = !isButtonShown
        UserDefaults.standard.set(show, forKey: showButtonKey)
        if show {
            panel.orderFrontRegardless()
            button.pulse()
        } else {
            panel.orderOut(nil)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "Move Floebin.app into your Applications folder and try again.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        list.hide()
        tutorial.hide()
        about.hide()
        settingsWindow.show()
    }

    @objc private func checkForUpdatesFromMenu() {
        updater.check(userInitiated: true)
    }

    @objc private func openDownloadsFolder() {
        NSWorkspace.shared.open(downloadsURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func item(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        if let symbol {
            menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return menuItem
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }
}

// MARK: - Settings window

extension AppDelegate: SettingsHost {

    var showFloatingButton: Bool {
        get { isButtonShown }
        set {
            if newValue != isButtonShown {
                toggleVisible()
            }
        }
    }

    var menuBarClickShowsRecent: Bool {
        get { statusClickShowsRecent }
        set {
            UserDefaults.standard.set(newValue, forKey: statusClickKey)
            applyStatusMode()
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue != (SMAppService.mainApp.status == .enabled) {
                toggleLaunchAtLogin()
            }
        }
    }

    var automaticUpdateChecks: Bool {
        get { updater.automaticChecks }
        set { updater.automaticChecks = newValue }
    }

    var hotKeyPreset: Int {
        get { UserDefaults.standard.integer(forKey: hotKeyKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: hotKeyKey)
            registerHotKey()
        }
    }

    var hotKeyRegistered: Bool { hotKeyOK }

    var buttonSizePoints: Int {
        get { Int(buttonSize) }
        set { applyButtonSize(newValue) }
    }

    var buttonPositionLocked: Bool {
        get { UserDefaults.standard.bool(forKey: lockKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: lockKey)
            button.allowsMoving = !newValue
        }
    }

    var recentCount: Int {
        get { maxRecent }
        set { applyRecentCount(newValue) }
    }

    var playAudioOnHover: Bool {
        get { UserDefaults.standard.bool(forKey: playAudioKey) }
        set { UserDefaults.standard.set(newValue, forKey: playAudioKey) }
    }

    var watchedFolderPaths: [String] { watchedFolderList }

    var projectFolderPath: String? { actions.projectURL?.path }

    var sortIntoTypeFolders: Bool {
        get { actions.sortsByTypeSetting }
        set { actions.sortsByTypeSetting = newValue }
    }

    var autoSendToProject: Bool {
        get { actions.autoSendSetting }
        set { actions.autoSendSetting = newValue }
    }

    var lutFolderPath: String? { actions.lutFolderPath }

    func moveButton(toSpot index: Int) {
        let spots = Spot.allCases
        guard index >= 0, index < spots.count else { return }
        moveButton(to: origin(for: spots[index]))
    }

    func resetButtonPosition() {
        resetPosition()
    }

    func addWatchedFolder(_ path: String) {
        var paths = watchedFolderList
        guard !paths.contains(path) else { return }
        paths.append(path)
        saveWatchedFolders(paths)
    }

    func chooseWatchedFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Watch Folder"
        openPanel.message = "New files in this folder will show up in Floebin."
        if openPanel.runModal() == .OK, let url = openPanel.url {
            addWatchedFolder(url.path)
        }
    }

    func removeWatchedFolder(_ path: String) {
        var paths = watchedFolderList
        paths.removeAll { $0 == path }
        if paths.isEmpty {
            paths = [downloadsURL.path]
        }
        saveWatchedFolders(paths)
    }

    func chooseProjectFolder() {
        actions.chooseProjectFolderInteractively()
    }

    func clearProjectFolder() {
        actions.clearProjectFolder()
    }

    func chooseLUTFolder() {
        actions.chooseLUTFolderInteractively()
    }

    func checkForUpdatesNow() {
        updater.check(userInitiated: true)
    }
}

