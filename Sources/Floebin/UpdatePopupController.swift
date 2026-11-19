import AppKit

/// The "A new version is ready" card. Floats over everything (full-screen apps too),
/// shows what's new, and installs the update in one click: download → replace → relaunch.
@MainActor
final class UpdatePopupController: NSObject {

    var onSkip: ((String) -> Void)?

    private var panel: NSPanel?
    private var info: UpdateInfo?
    private var anchor: NSRect = .zero
    private var download: UpdateDownload?
    private var state: State = .offer

    private enum State {
        case offer
        case downloading(Double)
        case installing
        case failed(String)
    }

    private let width: CGFloat = 340
    private let inset: CGFloat = 18

    var isVisible: Bool { panel?.isVisible ?? false }
    var isBusy: Bool {
        switch state {
        case .downloading, .installing: return true
        default: return false
        }
    }

    func show(_ info: UpdateInfo, near anchor: NSRect) {
        if isBusy, self.info?.version == info.version {
            panel?.orderFrontRegardless()
            return
        }
        self.info = info
        self.anchor = anchor
        state = .offer
        render()
    }

    func hide() {
        guard !isBusy else { return }
        panel?.orderOut(nil)
    }

    // MARK: Actions

    private func install() {
        guard let info else { return }
        guard let dmg = info.dmgURL else {
            openPage()
            return
        }
        guard UpdateInstaller.replaceableAppURL() != nil else {
            // Can't write where Floebin lives (e.g. a read-only disk): just get the DMG.
            state = .failed("Floebin can't replace itself in this folder. Download the new version and drag it into Applications.")
            render()
            return
        }

        state = .downloading(0)
        render()
        let download = UpdateDownload(
            onProgress: { [weak self] fraction in
                MainActor.assumeIsolated { self?.updateProgress(fraction) }
            },
            onFinish: { [weak self] result in
                MainActor.assumeIsolated { self?.downloaded(result) }
            }
        )
        self.download = download
        download.start(dmg)
    }

    private func updateProgress(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(fraction)
        progressBar?.doubleValue = fraction * 100
        statusLabel?.stringValue = "Downloading… \(Int(fraction * 100))%"
    }

    private func downloaded(_ result: Result<URL, Error>) {
        download = nil
        switch result {
        case .failure(let error):
            state = .failed("The download didn't finish. \(error.localizedDescription)")
            render()
        case .success(let dmg):
            state = .installing
            render()
            let bundleID = Bundle.main.bundleIdentifier ?? "com.shahemtiaj.floebin"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let staged = Result { try UpdateInstaller.stage(dmg: dmg, bundleID: bundleID) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.staged(staged) }
                }
            }
        }
    }

    private func staged(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            state = .failed(error.localizedDescription)
            render()
        case .success(let app):
            guard let target = UpdateInstaller.replaceableAppURL() else {
                state = .failed("Floebin can't replace itself in this folder.")
                render()
                return
            }
            do {
                try UpdateInstaller.scheduleSwapAndRelaunch(
                    staged: app, target: target, pid: NSRunningApplication.current.processIdentifier)
                statusLabel?.stringValue = "Restarting Floebin…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    MainActor.assumeIsolated { NSApp.terminate(nil) }
                }
            } catch {
                state = .failed(error.localizedDescription)
                render()
            }
        }
    }

    private func openPage() {
        if let info {
            NSWorkspace.shared.open(info.pageURL)
        }
        state = .offer
        panel?.orderOut(nil)
    }

    private func later() {
        download?.cancel()
        download = nil
        state = .offer
        panel?.orderOut(nil)
    }

    private func skip() {
        if let version = info?.version {
            onSkip?(version)
        }
        later()
    }

    // MARK: Drawing

    private weak var progressBar: NSProgressIndicator?
    private weak var statusLabel: NSTextField?

    private func render() {
        guard let info else { return }
        let notesText = Self.plainNotes(info.notes)
        let notesHeight: CGFloat = notesText.isEmpty ? 0 : 128
        let statusHeight: CGFloat
        switch state {
        case .offer: statusHeight = 0
        case .downloading, .installing: statusHeight = 46
        case .failed: statusHeight = 64
        }
        let height = 92 + (notesHeight > 0 ? notesHeight + 26 : 0) + statusHeight + 62
        let size = NSSize(width: width, height: height)

        let (root, content) = FloatingPanels.background(size: size)

        // Header: icon + title
        let icon = NSImageView(frame: NSRect(x: inset, y: 20, width: 52, height: 52))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        let textX = icon.frame.maxX + 12
        let kicker = makeLabel("UPDATE AVAILABLE", size: 10, weight: .semibold, color: .controlAccentColor)
        kicker.frame = NSRect(x: textX, y: 22, width: width - textX - inset, height: 13)
        content.addSubview(kicker)
        let title = makeLabel("Floebin \(info.version) is here", size: 15, weight: .semibold, color: .labelColor)
        title.frame = NSRect(x: textX, y: 37, width: width - textX - inset, height: 20)
        content.addSubview(title)
        let subtitle = makeLabel("You have \(UpdateChecker.currentVersion)", size: 11.5, weight: .regular, color: .secondaryLabelColor)
        subtitle.frame = NSRect(x: textX, y: 58, width: width - textX - inset, height: 15)
        content.addSubview(subtitle)

        var y: CGFloat = 92

        // What's new
        if notesHeight > 0 {
            let heading = makeLabel("WHAT'S NEW", size: 10, weight: .semibold, color: .tertiaryLabelColor)
            heading.frame = NSRect(x: inset, y: y, width: width - inset * 2, height: 13)
            content.addSubview(heading)
            y += 20

            let scroll = NSScrollView(frame: NSRect(x: inset - 4, y: y, width: width - inset * 2 + 8, height: notesHeight))
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 0, height: 2)
            textView.autoresizingMask = [.width]
            textView.font = NSFont.systemFont(ofSize: 12)
            textView.textColor = .labelColor
            textView.string = notesText
            scroll.documentView = textView
            content.addSubview(scroll)
            y += notesHeight + 6
        }

        // Progress / error
        switch state {
        case .offer:
            break
        case .downloading(let fraction):
            addProgress(to: content, y: y, indeterminate: false, value: fraction, text: "Downloading… \(Int(fraction * 100))%")
        case .installing:
            addProgress(to: content, y: y, indeterminate: true, value: 0, text: "Installing…")
        case .failed(let message):
            let label = makeWrappingLabel(message, size: 11.5, color: .systemRed)
            label.frame = NSRect(x: inset, y: y + 4, width: width - inset * 2, height: 56)
            content.addSubview(label)
        }
        y += statusHeight

        // Buttons
        content.addSubview(FloatingPanels.divider(y: height - 58, width: width, inset: 0))
        let buttonY = height - 44
        var right = width - inset + 4

        func addButton(_ title: String, style: PillButton.Style, enabled: Bool = true, action: @escaping () -> Void) {
            let button = PillButton(title: title, symbol: nil, style: style, height: 30)
            button.frame.origin = NSPoint(x: right - button.frame.width, y: buttonY)
            button.onPress = enabled ? action : nil
            button.alphaValue = enabled ? 1 : 0.45
            content.addSubview(button)
            right = button.frame.minX - 6
        }

        switch state {
        case .offer:
            if info.dmgURL != nil {
                addButton("Install & Restart", style: .prominent) { [weak self] in self?.install() }
            } else {
                addButton("Download", style: .prominent) { [weak self] in self?.openPage() }
            }
            addButton("Later", style: .normal) { [weak self] in self?.later() }
            let skip = PillButton(title: "Skip This Version", symbol: nil, style: .subtle, height: 30)
            skip.frame.origin = NSPoint(x: inset - 8, y: buttonY)
            skip.toolTip = "Don't remind me about \(info.version). You can still update from Check for Updates."
            skip.onPress = { [weak self] in self?.skip() }
            content.addSubview(skip)
        case .downloading:
            addButton("Cancel", style: .normal) { [weak self] in self?.later() }
        case .installing:
            addButton("Installing…", style: .prominent, enabled: false) {}
        case .failed:
            addButton("Download Page", style: .prominent) { [weak self] in self?.openPage() }
            addButton("Close", style: .normal) { [weak self] in self?.later() }
        }

        let panel = self.panel ?? FloatingPanels.make()
        self.panel = panel
        let origin: NSPoint
        if panel.isVisible {
            // Grow/shrink in place, keeping the top edge where it was.
            origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - height)
        } else {
            origin = FloatingPanels.origin(for: size, beside: anchor)
        }
        FloatingPanels.show(panel, frame: NSRect(origin: origin, size: size), content: root)
    }

    private func addProgress(to content: NSView, y: CGFloat, indeterminate: Bool, value: Double, text: String) {
        let bar = NSProgressIndicator(frame: NSRect(x: inset, y: y + 6, width: width - inset * 2, height: 12))
        bar.style = .bar
        bar.isIndeterminate = indeterminate
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = value * 100
        if indeterminate {
            bar.startAnimation(nil)
        }
        content.addSubview(bar)
        progressBar = bar

        let label = makeLabel(text, size: 11.5, weight: .regular, color: .secondaryLabelColor)
        label.frame = NSRect(x: inset, y: y + 24, width: width - inset * 2, height: 15)
        content.addSubview(label)
        statusLabel = label
    }

    /// Release notes are Markdown; show them as clean text.
    static func plainNotes(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") {
                line.removeFirst()
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "• " + line.dropFirst(2)
            }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            if line.isEmpty, lines.last?.isEmpty ?? true {
                continue
            }
            lines.append(line)
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
