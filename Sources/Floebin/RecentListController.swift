import AppKit

/// Filter chips at the top of the list.
enum ListFilter: Int, CaseIterable {
    case all, video, audio, image, font, other

    var title: String {
        switch self {
        case .all: return "All"
        case .video: return "Video"
        case .audio: return "Audio"
        case .image: return "Images"
        case .font: return "Fonts"
        case .other: return "Other"
        }
    }

    func matches(_ kind: FileKind) -> Bool {
        switch self {
        case .all: return true
        case .video: return kind == .video
        case .audio: return kind == .audio
        case .image: return kind == .image
        case .font: return kind == .font
        case .other: return ![FileKind.video, .audio, .image, .font].contains(kind)
        }
    }
}

/// The floating list of recent downloads that opens when you click the Floebin button.
/// - Pinned files on top, then Today / Yesterday / Earlier
/// - Filter chips: All · Video · Audio · Images · Fonts · Other
/// - Hover a row → preview card (video scrubs, audio plays, hold ⌥ for a bigger card)
/// - ⌘-click / ⇧-click to select several, then drag them all at once
/// - Keyboard (when opened with the shortcut): ↑↓ move · Space preview · Return open ·
///   ⌘C copy · ⌘R show in Finder · ⌘⌫ remove · ⌘A select all · ←→ filter · Esc close
@MainActor
final class RecentListController: NSObject {

    enum Placement {
        case beside   // next to the floating button
        case below    // under the menu bar icon / the mouse pointer
    }

    var onSelect: ((URL) -> Void)?
    var onClear: (() -> Void)?
    var onDropped: (() -> Void)?
    var onSendToProject: (([URL]) -> Void)?
    var openDownloads: (() -> Void)?
    var settingsMenuProvider: (() -> NSMenu)?
    var fileMenuProvider: (([URL]) -> NSMenu)?
    var projectMenuProvider: (() -> NSMenu)?
    var projectNameProvider: (() -> String?)?
    /// Pinned files (shown on top, regardless of date).
    var pinnedProvider: (() -> [URL])?
    /// Keyboard shortcuts that run a file action (open, show in Finder, remove).
    var onKeyboardAction: ((FileAction, [URL]) -> Void)?
    /// Called when the list closes.
    var onHide: (() -> Void)?

    let preview = PreviewController()

    // Layout — one left edge (inset) shared by the title, chips, section labels and thumbnails.
    private let width: CGFloat = 380
    private let inset: CGFloat = 16
    private let headerHeight: CGFloat = 62
    private let chipsHeight: CGFloat = 38
    private let sectionHeight: CGFloat = 30
    private let rowHeight: CGFloat = 66
    private let footerHeight: CGFloat = 56
    private let emptyHeight: CGFloat = 160

    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var files: [URL] = []          // recent downloads (unfiltered)
    private var shown: [URL] = []          // what's on screen, in order (pinned first)
    private var rows: [RecentRowView] = []
    private var selectedPaths = Set<String>()
    private var lastClickedPath: String?
    private var subtitleLabel: NSTextField?
    private var previewHideToken = UUID()
    private var placement: Placement = .beside
    private var lastAnchor: NSRect?
    private weak var scrollView: NSScrollView?
    private var keyCatcher: KeyCatcherView?
    private var filter: ListFilter = .all
    private var focusedIndex: Int?
    private var wantsKeyboard = false

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(files: [URL], anchor: NSRect, placement: Placement = .beside, focusKeyboard: Bool = false) {
        if isVisible {
            hide()
        } else {
            show(files: files, anchor: anchor, placement: placement, focusKeyboard: focusKeyboard)
        }
    }

    func show(files: [URL], anchor: NSRect, placement: Placement = .beside, focusKeyboard: Bool = false) {
        if !isVisible {
            wantsKeyboard = focusKeyboard
        }
        self.placement = placement
        lastAnchor = anchor
        // Newest first, so the date sections come out in order.
        self.files = files.sorted { (FileDates.added($0) ?? .distantPast) > (FileDates.added($1) ?? .distantPast) }

        // Pinned files first (if they still exist), then the rest grouped by date.
        let pinned = (pinnedProvider?() ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
        let pinnedPaths = Set(pinned.map(\.path))
        let unpinned = self.files.filter { !pinnedPaths.contains($0.path) }

        // Chips only for the kinds actually in the list, and only if there's a choice to make.
        let allKinds = Set((pinned + unpinned).map { FileKind.of($0) })
        let available = ListFilter.allCases.filter { filter in
            filter != .all && allKinds.contains { filter.matches($0) }
        }
        let showChips = available.count >= 2
        if !showChips || !available.contains(filter) {
            filter = .all
        }

        let visiblePinned = pinned.filter { filter.matches(FileKind.of($0)) }
        let visibleFiles = unpinned.filter { filter.matches(FileKind.of($0)) }
        var groups: [(title: String, files: [URL])] = []
        if !visiblePinned.isEmpty {
            groups.append((title: "Pinned", files: visiblePinned))
        }
        groups += group(visibleFiles)
        shown = groups.flatMap { $0.files }

        let paths = Set(shown.map(\.path))
        selectedPaths = selectedPaths.intersection(paths)

        let bodyHeight: CGFloat
        if shown.isEmpty {
            bodyHeight = emptyHeight
        } else {
            bodyHeight = groups.reduce(CGFloat(6)) { total, group in
                total + sectionHeight + CGFloat(group.files.count) * rowHeight
            } + 6
        }
        let topHeight = headerHeight + (showChips ? chipsHeight : 0)

        // Never taller than the screen — the list scrolls instead.
        let maxHeight = FloatingPanels.visibleFrame(near: anchor).height - 40
        let size = NSSize(width: width, height: min(topHeight + bodyHeight + footerHeight, maxHeight))

        // Re-rendering an open list (new download, an action…): keep the scroll position.
        let savedScroll = isVisible ? scrollView?.contentView.bounds.origin : nil

        let panel = self.panel ?? FloatingPanels.make(keyable: true)
        self.panel = panel
        let origin = placement == .below
            ? FloatingPanels.origin(for: size, below: anchor)
            : FloatingPanels.origin(for: size, beside: anchor)
        let frame = NSRect(origin: origin, size: size)
        let content = makeContent(size: size, groups: groups, bodyHeight: bodyHeight,
                                  topHeight: topHeight, chips: showChips ? [.all] + available : [])
        FloatingPanels.show(panel, frame: frame, content: content)

        if let savedScroll, let scroll = scrollView, let document = scroll.documentView {
            let maxY = max(0, document.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(savedScroll.y, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        startMonitoringOutsideClicks()

        // Keyboard: focus the panel (without activating Floebin) and highlight a row.
        if let focused = focusedIndex {
            focusedIndex = rows.isEmpty ? nil : min(focused, rows.count - 1)
        }
        if wantsKeyboard {
            if focusedIndex == nil, !rows.isEmpty {
                focusedIndex = 0
            }
            panel.makeKey()
            if let keyCatcher {
                panel.makeFirstResponder(keyCatcher)
            }
        }
        updateFocusUI(scroll: false)
    }

    /// Re-renders the list if it's open (for example when a new download arrives).
    func refresh(files: [URL], anchor: NSRect) {
        guard isVisible else { return }
        preview.hide()   // the rows are rebuilt, so the hovered one is gone
        // Stay where it was opened (beside the button or under the menu bar icon).
        show(files: files, anchor: lastAnchor ?? anchor, placement: placement)
    }

    func hide() {
        let wasVisible = isVisible
        preview.hide()
        panel?.orderOut(nil)
        stopMonitoringOutsideClicks()
        selectedPaths.removeAll()
        lastClickedPath = nil
        focusedIndex = nil
        filter = .all
        wantsKeyboard = false
        if wasVisible {
            onHide?()
        }
    }

    private func group(_ files: [URL]) -> [(title: String, files: [URL])] {
        var result: [(title: String, files: [URL])] = []
        for url in files {
            let title = FileDates.section(for: FileDates.added(url))
            if let last = result.last, last.title == title {
                result[result.count - 1].files.append(url)
            } else {
                result.append((title: title, files: [url]))
            }
        }
        return result
    }

    private func setFilter(_ newFilter: ListFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        selectedPaths.removeAll()
        focusedIndex = wantsKeyboard ? 0 : nil
        preview.hide()
        show(files: files, anchor: lastAnchor ?? .zero, placement: placement)
    }

    // MARK: Selection

    /// The files an action on `url` should apply to: the whole selection if `url` is part of it.
    private func targets(for url: URL) -> [URL] {
        guard selectedPaths.contains(url.path) else { return [url] }
        return shown.filter { selectedPaths.contains($0.path) }
    }

    private func handleClick(_ url: URL, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) || (modifiers.contains(.shift) && lastClickedPath == nil) {
            if selectedPaths.contains(url.path) {
                selectedPaths.remove(url.path)
            } else {
                selectedPaths.insert(url.path)
            }
        } else if modifiers.contains(.shift),
                  let anchorPath = lastClickedPath,
                  let a = shown.firstIndex(where: { $0.path == anchorPath }),
                  let b = shown.firstIndex(where: { $0.path == url.path }) {
            for i in min(a, b)...max(a, b) {
                selectedPaths.insert(shown[i].path)
            }
        } else {
            // Plain click: put this file on the button.
            onSelect?(url)
            hide()
            return
        }
        lastClickedPath = url.path
        updateSelectionUI()
    }

    private func updateSelectionUI() {
        for row in rows {
            row.isSelected = selectedPaths.contains(row.url.path)
        }
        subtitleLabel?.stringValue = subtitleText()
        subtitleLabel?.textColor = selectedPaths.isEmpty ? .secondaryLabelColor : .controlAccentColor
    }

    private func subtitleText() -> String {
        if files.isEmpty && shown.isEmpty {
            return "Waiting for your next download"
        }
        if !selectedPaths.isEmpty {
            return "\(selectedPaths.count) selected · drag or right-click to use them all"
        }
        if wantsKeyboard {
            return "↑↓ move · Space preview · ⌘C copy · Esc close"
        }
        return "Drag into any app · ⌘-click to select several"
    }

    // MARK: Keyboard

    private var focusedURL: URL? {
        guard let index = focusedIndex, index >= 0, index < rows.count else { return nil }
        return rows[index].url
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)

        switch event.keyCode {
        case 53:                                   // Esc
            hide()
            return true
        case 125:                                  // ↓
            moveFocus(by: 1)
            return true
        case 126:                                  // ↑
            moveFocus(by: -1)
            return true
        case 123:                                  // ←
            stepFilter(by: -1)
            return true
        case 124:                                  // →
            stepFilter(by: 1)
            return true
        case 49:                                   // Space
            togglePreviewForFocus()
            return true
        case 36, 76:                               // Return / Enter
            if let url = focusedURL {
                onKeyboardAction?(.open, targets(for: url))
            }
            return true
        case 51 where command:                     // ⌘⌫
            if let url = focusedURL {
                onKeyboardAction?(.remove, targets(for: url))
            }
            return true
        default:
            break
        }

        guard command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "c":
            if let url = focusedURL {
                let urls = targets(for: url)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
                rows[focusedIndex ?? 0].flashCopied()
            }
            return true
        case "r":
            if let url = focusedURL {
                onKeyboardAction?(.reveal, targets(for: url))
            }
            return true
        case "a":
            selectedPaths = Set(shown.map(\.path))
            updateSelectionUI()
            return true
        default:
            return false
        }
    }

    private func moveFocus(by step: Int) {
        guard !rows.isEmpty else { return }
        if let current = focusedIndex {
            focusedIndex = min(max(current + step, 0), rows.count - 1)
        } else {
            focusedIndex = step > 0 ? 0 : rows.count - 1
        }
        updateFocusUI(scroll: true)
        // Quick Look style: if the preview is open, it follows the focus.
        if preview.isVisible, let index = focusedIndex {
            showPreview(for: rows[index])
        }
    }

    private func stepFilter(by step: Int) {
        let chips = availableChips()
        guard chips.count > 1, let current = chips.firstIndex(of: filter) else { return }
        let next = min(max(current + step, 0), chips.count - 1)
        setFilter(chips[next])
    }

    private func availableChips() -> [ListFilter] {
        let pinned = (pinnedProvider?() ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
        let kinds = Set((pinned + files).map { FileKind.of($0) })
        let available = ListFilter.allCases.filter { filter in
            filter != .all && kinds.contains { filter.matches($0) }
        }
        return available.count >= 2 ? [.all] + available : []
    }

    private func togglePreviewForFocus() {
        guard let index = focusedIndex, index < rows.count else { return }
        let row = rows[index]
        if preview.isVisible && preview.currentPath == row.url.path {
            preview.hide()
        } else {
            showPreview(for: row)
        }
    }

    private func showPreview(for row: RecentRowView) {
        previewHideToken = UUID()
        preview.show(url: row.url, rowRect: row.screenRect(), listFrame: panel?.frame ?? row.screenRect())
    }

    private func updateFocusUI(scroll: Bool) {
        for (index, row) in rows.enumerated() {
            row.isFocused = index == focusedIndex
        }
        if scroll, let index = focusedIndex, index < rows.count {
            let row = rows[index]
            row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -8))
        }
    }

    // MARK: Preview

    private func rowHover(_ url: URL, inside: Bool, rowRect: NSRect) {
        if inside {
            previewHideToken = UUID()
            if let index = rows.firstIndex(where: { $0.url.path == url.path }) {
                focusedIndex = index
                updateFocusUI(scroll: false)
            }
            preview.show(url: url, rowRect: rowRect, listFrame: panel?.frame ?? rowRect)
        } else {
            // Small delay so moving between rows doesn't flicker the card.
            let token = UUID()
            previewHideToken = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.previewHideToken == token else { return }
                    self.preview.hide()
                }
            }
        }
    }

    // MARK: Building

    private func makeContent(size: NSSize, groups: [(title: String, files: [URL])], bodyHeight: CGFloat,
                             topHeight: CGFloat, chips: [ListFilter]) -> NSView {
        let (root, content) = FloatingPanels.background(size: size)
        rows.removeAll()

        // Invisible keyboard receiver
        let catcher = KeyCatcherView(frame: content.bounds)
        catcher.autoresizingMask = [.width, .height]
        catcher.onKeyDown = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        content.addSubview(catcher)
        keyCatcher = catcher

        // ── Header ─────────────────────────────────────────────
        let gear = PillButton(title: nil, symbol: "gearshape", style: .subtle, height: 28)
        gear.toolTip = "Settings"
        gear.frame.origin = NSPoint(x: size.width - 10 - gear.frame.width, y: 17)
        gear.onPress = { [weak self, weak gear] in
            guard let self, let gear, let menu = self.settingsMenuProvider?() else { return }
            self.preview.hide()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: gear)
        }
        content.addSubview(gear)

        var titleRight = gear.frame.minX - 8
        if !files.isEmpty {
            let count = makeBadge("\(files.count)", color: .secondaryLabelColor, solid: false, fontSize: 10.5)
            count.frame.origin = NSPoint(
                x: gear.frame.minX - 6 - count.frame.width,
                y: (gear.frame.midY - count.frame.height / 2).rounded()
            )
            count.toolTip = "\(files.count) recent downloads"
            count.setAccessibilityElement(true)
            count.setAccessibilityLabel("\(files.count) recent downloads")
            content.addSubview(count)
            titleRight = count.frame.minX - 8
        }

        let title = makeLabel("Recent Downloads", size: 15, weight: .semibold, color: .labelColor)
        title.frame = NSRect(x: inset, y: 14, width: titleRight - inset, height: 20)
        content.addSubview(title)

        let subtitle = makeLabel(subtitleText(), size: 11.5, weight: .regular,
                                 color: selectedPaths.isEmpty ? .secondaryLabelColor : .controlAccentColor)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: inset, y: 35, width: titleRight - inset, height: 16)
        content.addSubview(subtitle)
        subtitleLabel = subtitle

        // ── Filter chips ───────────────────────────────────────
        if !chips.isEmpty {
            // Every chip must fit on one line: tighten the padding and gaps until they do.
            let available = size.width - inset * 2 + 4
            var buttons: [PillButton] = []
            var gap: CGFloat = 6
            for (padding, spacing) in [(CGFloat(11), CGFloat(6)), (9, 5), (7, 4), (5, 3)] {
                buttons = chips.map { chip in
                    PillButton(title: chip.title, symbol: nil, style: chip == filter ? .prominent : .normal,
                               height: 24, padding: padding)
                }
                gap = spacing
                let total = buttons.reduce(CGFloat(0)) { $0 + $1.frame.width } + gap * CGFloat(buttons.count - 1)
                if total <= available {
                    break
                }
            }
            var x = inset - 2
            for (chip, button) in zip(chips, buttons) {
                button.frame.origin = NSPoint(x: x, y: headerHeight + 6)
                button.setAccessibilityLabel("Show \(chip.title)")
                button.toolTip = chip == .all ? "Show everything" : "Show only \(chip.title.lowercased())"
                button.onPress = { [weak self] in
                    self?.setFilter(chip)
                }
                content.addSubview(button)
                x += button.frame.width + gap
            }
        }

        content.addSubview(FloatingPanels.divider(y: topHeight - 1, width: size.width, inset: 0))

        // ── Body ───────────────────────────────────────────────
        let bodyFrame = NSRect(x: 0, y: topHeight, width: size.width, height: size.height - topHeight - footerHeight)
        let hasProject = projectNameProvider?() != nil
        let pinnedPaths = Set((pinnedProvider?() ?? []).map(\.path))

        if groups.isEmpty {
            if files.isEmpty && pinnedPaths.isEmpty {
                addEmptyState(to: content, in: bodyFrame,
                              title: "No downloads yet",
                              hint: "Anything you download in your browser shows up here.")
            } else {
                addEmptyState(to: content, in: bodyFrame,
                              title: "No \(filter.title.lowercased()) here",
                              hint: "Pick another filter above.")
            }
        } else {
            let document = FlippedView(frame: NSRect(x: 0, y: 0, width: size.width, height: bodyHeight))
            var y: CGFloat = 6
            for group in groups {
                let header = makeLabel(group.title.uppercased(), size: 10.5, weight: .semibold, color: .tertiaryLabelColor)
                header.frame = NSRect(x: inset, y: y + 11, width: size.width - inset * 2, height: 14)
                document.addSubview(header)
                y += sectionHeight

                for url in group.files {
                    let row = RecentRowView(
                        frame: NSRect(x: 8, y: y, width: size.width - 16, height: rowHeight - 4),
                        url: url,
                        showsProjectButton: hasProject,
                        pinned: pinnedPaths.contains(url.path)
                    )
                    configure(row)
                    document.addSubview(row)
                    rows.append(row)
                    y += rowHeight
                }
            }

            let scroll = NSScrollView(frame: bodyFrame)
            scroll.drawsBackground = false
            scroll.contentView.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.documentView = document
            content.addSubview(scroll)
            scrollView = scroll
        }

        // ── Footer: [📁 Project ▾]            [⤓] [Clear] ──
        let footerY = size.height - footerHeight
        content.addSubview(FloatingPanels.divider(y: footerY, width: size.width, inset: 0))
        let buttonY = footerY + (footerHeight - 28) / 2

        var right = size.width - inset + 4
        if !files.isEmpty {
            let clearButton = PillButton(title: "Clear", symbol: "xmark", style: .subtle, height: 28)
            clearButton.toolTip = "Clear the list (files stay in Downloads)"
            clearButton.frame.origin = NSPoint(x: right - clearButton.frame.width, y: buttonY)
            clearButton.onPress = { [weak self] in
                self?.onClear?()
            }
            content.addSubview(clearButton)
            right = clearButton.frame.minX - 4
        }

        let downloadsButton = PillButton(title: nil, symbol: "arrow.down.circle", style: .subtle, height: 28)
        downloadsButton.toolTip = "Open Downloads folder"
        downloadsButton.frame.origin = NSPoint(x: right - downloadsButton.frame.width, y: buttonY)
        downloadsButton.onPress = { [weak self] in
            self?.hide()
            self?.openDownloads?()
        }
        content.addSubview(downloadsButton)

        let projectTitle = projectNameProvider?().map { name in
            name.count > 22 ? String(name.prefix(21)) + "…" : name
        } ?? "Set Project Folder"
        let projectButton = PillButton(title: projectTitle, symbol: hasProject ? "folder.fill" : "folder.badge.plus",
                                       style: .normal, height: 28)
        projectButton.toolTip = hasProject ? "Project folder — click for options" : "Choose a folder to send downloads into"
        projectButton.frame.origin = NSPoint(x: inset - 4, y: buttonY)
        projectButton.onPress = { [weak self, weak projectButton] in
            guard let self, let projectButton, let menu = self.projectMenuProvider?() else { return }
            self.preview.hide()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: projectButton)
        }
        content.addSubview(projectButton)

        return root
    }

    private func configure(_ row: RecentRowView) {
        row.isSelected = selectedPaths.contains(row.url.path)
        row.onClick = { [weak self] url, modifiers in
            self?.handleClick(url, modifiers: modifiers)
        }
        row.dragURLs = { [weak self] url in
            self?.targets(for: url) ?? [url]
        }
        row.onDragStart = { [weak self] in
            self?.preview.hide()
        }
        row.onDropped = { [weak self] in
            self?.onDropped?()
        }
        row.onReveal = { [weak self] url in
            guard let self else { return }
            let urls = self.targets(for: url)
            self.hide()
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        row.onSendToProject = { [weak self] url in
            guard let self else { return }
            self.preview.hide()
            self.onSendToProject?(self.targets(for: url))
        }
        row.menuProvider = { [weak self] url in
            guard let self else { return NSMenu() }
            self.preview.hide()
            return self.fileMenuProvider?(self.targets(for: url)) ?? NSMenu()
        }
        row.onHover = { [weak self] url, inside, rect in
            self?.rowHover(url, inside: inside, rowRect: rect)
        }
        row.onScrub = { [weak self] url, fraction in
            self?.preview.scrub(url: url, fraction: fraction)
        }
    }

    private func addEmptyState(to content: NSView, in frame: NSRect, title: String, hint: String) {
        let iconSize: CGFloat = 44
        let icon = NSImageView(frame: NSRect(x: (frame.width - iconSize) / 2, y: frame.minY + 28, width: iconSize, height: iconSize))
        icon.image = Glyph.floe(size: iconSize)
        icon.contentTintColor = .tertiaryLabelColor
        content.addSubview(icon)

        let titleLabel = makeLabel(title, size: 13, weight: .semibold, color: .secondaryLabelColor)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: inset, y: frame.minY + 82, width: frame.width - inset * 2, height: 18)
        content.addSubview(titleLabel)

        let hintLabel = makeLabel(hint, size: 11.5, weight: .regular, color: .tertiaryLabelColor)
        hintLabel.alignment = .center
        hintLabel.frame = NSRect(x: inset, y: frame.minY + 102, width: frame.width - inset * 2, height: 16)
        content.addSubview(hintLabel)
    }

    // MARK: Outside clicks close the list

    private func startMonitoringOutsideClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func stopMonitoringOutsideClicks() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
}

// MARK: - One row in the list

/// [thumb]  file name
///          [MP4]  0:12 · 1920×1080 · 25fps · 20.6 MB
///          🌐 pexels.com · 4h ago                      (📁+ 🔍 on hover)
final class RecentRowView: NSView, NSDraggingSource {

    let url: URL
    var onClick: ((URL, NSEvent.ModifierFlags) -> Void)?
    var onReveal: ((URL) -> Void)?
    var onSendToProject: ((URL) -> Void)?
    var onDropped: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onHover: ((URL, Bool, NSRect) -> Void)?
    var onScrub: ((URL, Double) -> Void)?
    var dragURLs: ((URL) -> [URL])?
    var menuProvider: ((URL) -> NSMenu)?

    var isSelected = false {
        didSet { updateAppearance() }
    }
    /// Keyboard focus (↑↓) — shown like a hover with a soft outline.
    var isFocused = false {
        didSet { if isFocused != oldValue { updateAppearance() } }
    }
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    private let kind: FileKind
    private let thumb = NSImageView()
    private let revealButton: PillButton
    private let projectButton: PillButton?
    private var metaLabel: NSTextField!
    private var mouseDownEvent: NSEvent?
    private var mouseDownPoint: NSPoint = .zero
    private var didStartDrag = false

    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect, url: URL, showsProjectButton: Bool, pinned: Bool = false) {
        self.url = url
        self.kind = FileKind.of(url)
        revealButton = PillButton(title: nil, symbol: "magnifyingglass", style: .subtle, height: 26)
        projectButton = showsProjectButton ? PillButton(title: nil, symbol: "folder.badge.plus", style: .subtle, height: 26) : nil
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        toolTip = url.path

        let added = FileDates.added(url)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        let sizeText: String
        if values?.isDirectory == true {
            sizeText = "Folder"
        } else if let bytes = values?.fileSize {
            sizeText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            sizeText = ""
        }

        // Thumbnail (or a colored type tile when there's no preview)
        let side: CGFloat = 46
        thumb.frame = NSRect(x: 8, y: ((frameRect.height - side) / 2).rounded(), width: side, height: side)
        thumb.imageScaling = .scaleAxesIndependently
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 9
        thumb.layer?.masksToBounds = true
        thumb.layer?.borderWidth = 0.5
        thumb.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        addSubview(thumb)
        Thumbnails.load(url, side: side, scale: 2, placeholder: Thumbnails.kindTile(kind, side: side)) { [weak self] image in
            self?.thumb.image = Thumbnails.aspectFill(image, side: side)
        }

        // Pinned: a small pin badge on the thumbnail's corner
        if pinned {
            let pin = NSImageView(frame: NSRect(x: thumb.frame.minX - 4, y: thumb.frame.minY - 4, width: 18, height: 18))
            pin.wantsLayer = true
            pin.layer?.cornerRadius = 9
            pin.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold))
            pin.contentTintColor = .white
            pin.imageScaling = .scaleNone
            pin.toolTip = "Pinned"
            addSubview(pin)
        }

        // Hover buttons on the right: [send to project] [show in Finder]
        let buttonY = ((frameRect.height - 26) / 2).rounded()
        revealButton.frame.origin = NSPoint(x: frameRect.width - 6 - revealButton.frame.width, y: buttonY)
        revealButton.toolTip = "Show in Finder"
        revealButton.isHidden = true
        revealButton.onPress = { [weak self] in
            guard let self else { return }
            self.onReveal?(self.url)
        }
        addSubview(revealButton)

        if let projectButton {
            projectButton.frame.origin = NSPoint(x: revealButton.frame.minX - 2 - projectButton.frame.width, y: buttonY)
            projectButton.toolTip = "Send to project folder"
            projectButton.isHidden = true
            projectButton.onPress = { [weak self] in
                guard let self else { return }
                self.onSendToProject?(self.url)
            }
            addSubview(projectButton)
        }

        // Text column — same width on every row so everything lines up.
        let textX = thumb.frame.maxX + 12
        let textRight = frameRect.width - 6 - 26 - 2 - 26 - 6

        // Line 1: file name + the icon of the browser it came from
        let displayName = url.lastPathComponent.trimmingCharacters(in: .whitespaces)
        let name = makeLabel(displayName, size: 13, weight: .medium, color: .labelColor)
        let browserIcon = DownloadBrowser.icon(for: url)
        let iconSpace: CGFloat = browserIcon == nil ? 0 : 20
        let nameWidth = min(ceil(name.intrinsicContentSize.width), textRight - textX - iconSpace)
        name.frame = NSRect(x: textX, y: 7, width: nameWidth, height: 18)
        addSubview(name)

        if let browserIcon {
            let iconView = NSImageView(frame: NSRect(x: name.frame.maxX + 4, y: 8, width: 16, height: 16))
            iconView.image = browserIcon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.toolTip = DownloadBrowser.name(for: url).map { "Downloaded with \($0)" }
            addSubview(iconView)
        }

        // Line 2: [MP4]  media info · size
        let metaY: CGFloat = 26
        let lineHeight: CGFloat = 15
        let badge = makeBadge(FileKind.badgeText(for: url, kind: kind), color: kind.color, solid: false, fontSize: 9)
        badge.frame.origin = NSPoint(x: textX, y: (metaY + (lineHeight - badge.frame.height) / 2).rounded())
        addSubview(badge)

        let meta = makeLabel(sizeText, size: 11, weight: .regular, color: .secondaryLabelColor)
        meta.lineBreakMode = .byTruncatingTail
        meta.frame = NSRect(x: badge.frame.maxX + 7, y: metaY, width: textRight - badge.frame.maxX - 7, height: lineHeight)
        addSubview(meta)
        metaLabel = meta

        MediaInfoLoader.load(url, kind: kind) { [weak self] info in
            guard let self else { return }
            self.metaLabel.stringValue = [info.summary, sizeText].filter { !$0.isEmpty }.joined(separator: " · ")
        }

        // Line 3: 🌐 source · time
        let sourceY: CGFloat = 43
        var sourceX = textX
        var sourceParts: [String] = []
        if let host = DownloadSource.host(for: url) {
            let globe = NSImageView(frame: NSRect(x: textX, y: sourceY + 1.5, width: 12, height: 12))
            globe.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Source")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9.5, weight: .regular))
            globe.contentTintColor = .tertiaryLabelColor
            globe.imageScaling = .scaleNone
            addSubview(globe)
            sourceX += 16
            sourceParts.append(host)
        }
        let isNew = added.map { Date().timeIntervalSince($0) < 600 } ?? false
        if let added {
            sourceParts.append(FileDates.ago(added))
        }
        let source = makeLabel(sourceParts.joined(separator: " · "), size: 11, weight: isNew ? .medium : .regular,
                               color: isNew ? .controlAccentColor : .tertiaryLabelColor)
        source.lineBreakMode = .byTruncatingTail
        source.frame = NSRect(x: sourceX, y: sourceY, width: textRight - sourceX, height: lineHeight)
        addSubview(source)

        // VoiceOver: one element per row, read as a sentence
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let spoken = [displayName, FileKind.badgeText(for: url, kind: kind), sizeText,
                      added.map { FileDates.ago($0) } ?? "", pinned ? "pinned" : ""]
        setAccessibilityLabel(spoken.filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityHelp("Drag into any app. Press to put it on the Floebin button.")

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func updateAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isHovering || isFocused ? 0.24 : 0.18).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        } else if isHovering || isFocused {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            layer?.borderWidth = isFocused && !isHovering ? 1 : 0
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor
        } else {
            layer?.backgroundColor = nil
            layer?.borderWidth = 0
        }
        revealButton.isHidden = !isHovering
        projectButton?.isHidden = !isHovering
    }

    /// Brief green flash after ⌘C.
    func flashCopied() {
        let flash = CABasicAnimation(keyPath: "backgroundColor")
        flash.fromValue = NSColor.systemGreen.withAlphaComponent(0.35).cgColor
        flash.toValue = layer?.backgroundColor
        flash.duration = 0.6
        layer?.add(flash, forKey: "copied")
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(url, [])
        return true
    }

    func screenRect() -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.openHand.set()
        onHover?(url, true, screenRect())
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
        onHover?(url, false, .zero)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onScrub?(url, Double(point.x / max(bounds.width, 1)))
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if !revealButton.isHidden, revealButton.frame.contains(local) {
            return revealButton
        }
        if let projectButton, !projectButton.isHidden, projectButton.frame.contains(local) {
            return projectButton
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        mouseDownPoint = NSEvent.mouseLocation
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        guard !didStartDrag, hypot(now.x - mouseDownPoint.x, now.y - mouseDownPoint.y) > 3 else { return }
        didStartDrag = true
        onDragStart?()

        // Drag every selected file if this row is part of the selection.
        let urls = dragURLs?(url) ?? [url]
        var items: [NSDraggingItem] = []
        for (index, fileURL) in urls.enumerated() {
            let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
            let offset = CGFloat(min(index, 4)) * 5
            let image: NSImage
            if fileURL.path == url.path, let thumbImage = thumb.image {
                image = thumbImage
            } else {
                image = NSWorkspace.shared.icon(forFile: fileURL.path)
            }
            item.setDraggingFrame(thumb.frame.offsetBy(dx: offset, dy: offset), contents: image)
            items.append(item)
        }
        beginDraggingSession(with: items, event: mouseDownEvent ?? event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didStartDrag {
            onClick?(url, event.modifierFlags)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?(url) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        didStartDrag = false
        if operation != [] {
            onDropped?()
        }
    }
}
