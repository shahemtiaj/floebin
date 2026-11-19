import AppKit
import AVFoundation

/// A larger preview card that appears beside the list while you hover a row.
/// - Video: move the mouse left → right across the row to scrub through it.
/// - Audio: plays automatically (can be turned off in Settings).
/// - Images & everything else: a big thumbnail + details.
/// - Hold ⌥ (Option) to make the card twice as big.
@MainActor
final class PreviewController: NSObject {

    var playsAudioOnHover: () -> Bool = { true }

    // Normal and large (hold ⌥) sizes
    private var isLarge = false
    private var size: NSSize {
        isLarge ? NSSize(width: 600, height: 415) : NSSize(width: 300, height: 246)
    }
    private var mediaRect: NSRect {
        isLarge ? NSRect(x: 12, y: 12, width: 576, height: 324) : NSRect(x: 12, y: 12, width: 276, height: 155)
    }
    private var modifierTimer: Timer?
    private var lastRowRect = NSRect.zero
    private var lastListFrame = NSRect.zero
    private var progressFraction: Double = 0
    private var lastScrubFraction: Double?

    private var panel: NSPanel?
    private let mediaBackground = NSView()
    private let imageView = NSImageView()
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private var overlayIcon: NSImageView!
    private var nameLabel: NSTextField!
    private var infoLabel: NSTextField!
    private var sourceLabel: NSTextField!

    private var currentURL: URL?
    private var kind: FileKind = .other
    private var sizeText = ""

    // Video scrubbing
    private var generator: AVAssetImageGenerator?
    private var duration: Double = 0
    private var isGenerating = false
    private var pendingFraction: Double?
    private var hasScrubFrame = false

    // Audio
    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var audioToken = UUID()

    var isVisible: Bool { panel?.isVisible ?? false }
    var currentPath: String? { currentURL?.path }

    // MARK: Show / hide

    func show(url: URL, rowRect: NSRect, listFrame: NSRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        lastRowRect = rowRect
        lastListFrame = listFrame
        position(panel, rowRect: rowRect, listFrame: listFrame)
        if currentURL?.path != url.path {
            load(url)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        startWatchingOptionKey()
    }

    func hide() {
        stopAudio()
        panel?.orderOut(nil)
        currentURL = nil
        generator = nil
        pendingFraction = nil
        hasScrubFrame = false
        lastScrubFraction = nil
        modifierTimer?.invalidate()
        modifierTimer = nil
        if isLarge {
            isLarge = false
            applyLayout()
        }
    }

    // MARK: Hold ⌥ for a bigger card

    private func startWatchingOptionKey() {
        guard modifierTimer == nil else { return }
        modifierTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkOptionKey()
            }
        }
    }

    private func checkOptionKey() {
        let wantsLarge = NSEvent.modifierFlags.contains(.option)
        guard wantsLarge != isLarge, let panel else { return }
        isLarge = wantsLarge
        applyLayout()
        position(panel, rowRect: lastRowRect, listFrame: lastListFrame)
        if let currentURL, kind != .video || !hasScrubFrame {
            // Sharper picture for the big card
            Thumbnails.load(currentURL, side: 600, scale: 2) { [weak self] image in
                guard let self, self.currentURL?.path == currentURL.path, !self.hasScrubFrame else { return }
                self.imageView.image = image
            }
        }
        generator?.maximumSize = isLarge ? CGSize(width: 1280, height: 720) : CGSize(width: 640, height: 360)
        if let fraction = lastScrubFraction, let currentURL {
            scrub(url: currentURL, fraction: fraction)
        }
    }

    private func setProgress(_ fraction: Double) {
        progressFraction = fraction
        progressFill.frame = NSRect(x: 0, y: 0, width: progressTrack.bounds.width * CGFloat(fraction), height: 3)
    }

    /// Mouse position across the row, 0…1. Scrubs video.
    func scrub(url: URL, fraction: Double) {
        guard url.path == currentURL?.path, kind == .video, let generator, duration > 0 else { return }
        let f = min(max(fraction, 0), 1)
        lastScrubFraction = f
        setProgress(f)

        if isGenerating {
            pendingFraction = f
            return
        }
        isGenerating = true
        let time = CMTime(seconds: duration * f, preferredTimescale: 600)

        Task { @MainActor [weak self] in
            let result = try? await generator.image(at: time)
            guard let self else { return }
            self.isGenerating = false
            if self.currentURL?.path == url.path, let cgImage = result?.image {
                self.hasScrubFrame = true
                self.imageView.image = NSImage(cgImage: cgImage, size: .zero)
            }
            if let next = self.pendingFraction {
                self.pendingFraction = nil
                self.scrub(url: url, fraction: next)
            }
        }
    }

    // MARK: Loading a file

    private func load(_ url: URL) {
        stopAudio()
        currentURL = url
        kind = FileKind.of(url)
        generator = nil
        duration = 0
        pendingFraction = nil
        isGenerating = false
        hasScrubFrame = false

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            sizeText = "Folder"
        } else if let bytes = values?.fileSize {
            sizeText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            sizeText = ""
        }

        nameLabel.stringValue = url.lastPathComponent.trimmingCharacters(in: .whitespaces)
        infoLabel.stringValue = [FileKind.badgeText(for: url, kind: kind), sizeText].filter { !$0.isEmpty }.joined(separator: " · ")

        var sourceParts: [String] = []
        if let host = DownloadSource.host(for: url) {
            sourceParts.append("From \(host)")
        }
        if let browser = DownloadBrowser.name(for: url), DownloadBrowser.icon(for: url) != nil {
            sourceParts.append(browser)
        }
        if let added = FileDates.added(url) {
            sourceParts.append(FileDates.ago(added))
        }
        sourceLabel.stringValue = sourceParts.joined(separator: " · ")

        let isMedia = kind == .video || kind == .audio
        progressTrack.isHidden = !isMedia
        setProgress(0)
        overlayIcon.isHidden = true

        imageView.image = nil
        Thumbnails.load(url, side: isLarge ? 600 : 300, scale: 2, placeholder: Thumbnails.kindTile(kind, side: 155)) { [weak self] image in
            guard let self, self.currentURL?.path == url.path, !self.hasScrubFrame else { return }
            self.imageView.image = image
        }

        MediaInfoLoader.load(url, kind: kind) { [weak self] info in
            guard let self, self.currentURL?.path == url.path else { return }
            let parts = [FileKind.badgeText(for: url, kind: self.kind), info.summary, self.sizeText]
            self.infoLabel.stringValue = parts.filter { !$0.isEmpty }.joined(separator: " · ")
            if let seconds = info.duration {
                self.duration = seconds
            }
        }

        if kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = isLarge ? CGSize(width: 1280, height: 720) : CGSize(width: 640, height: 360)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
            self.generator = generator
            showOverlay("arrow.left.and.right", tooltip: "Move across the row to scrub")
        }

        if kind == .audio, playsAudioOnHover() {
            // Short delay so sweeping the mouse over the list doesn't fire off every sound.
            let token = UUID()
            audioToken = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.audioToken == token, self.currentURL?.path == url.path else { return }
                    self.startAudio(url)
                }
            }
        }
    }

    // MARK: Audio

    private func startAudio(_ url: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = 0.8
        player.play()
        self.player = player
        showOverlay("speaker.wave.2.fill", tooltip: "Playing")

        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateAudioProgress()
            }
        }
    }

    private func updateAudioProgress() {
        guard let player, player.duration > 0 else { return }
        let fraction = player.isPlaying ? player.currentTime / player.duration : 1
        setProgress(fraction)
        if !player.isPlaying {
            progressTimer?.invalidate()
            progressTimer = nil
            overlayIcon.isHidden = true
        }
    }

    private func stopAudio() {
        audioToken = UUID()
        player?.stop()
        player = nil
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: Layout

    private func showOverlay(_ symbol: String, tooltip: String) {
        overlayIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        overlayIcon.toolTip = tooltip
        overlayIcon.isHidden = false
    }

    private func position(_ panel: NSPanel, rowRect: NSRect, listFrame: NSRect) {
        let vf = FloatingPanels.visibleFrame(near: listFrame)
        // Opposite side of the list from the screen edge it's closest to.
        var x = listFrame.midX > vf.midX ? listFrame.minX - size.width - 10 : listFrame.maxX + 10
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        var y = rowRect.midY - size.height / 2
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = FloatingPanels.make()
        panel.ignoresMouseEvents = true
        let (root, content) = FloatingPanels.background(size: size)

        mediaBackground.wantsLayer = true
        mediaBackground.layer?.cornerRadius = 9
        mediaBackground.layer?.masksToBounds = true
        mediaBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        content.addSubview(mediaBackground)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        mediaBackground.addSubview(imageView)

        // Small icon in the media's bottom-right corner (scrub hint / speaker)
        let badge = NSImageView(frame: NSRect(x: 0, y: 8, width: 22, height: 22))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 11
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.contentTintColor = .white
        badge.imageScaling = .scaleNone
        badge.isHidden = true
        mediaBackground.addSubview(badge)
        overlayIcon = badge

        progressTrack.wantsLayer = true
        progressTrack.layer?.cornerRadius = 1.5
        progressTrack.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        content.addSubview(progressTrack)

        progressFill.wantsLayer = true
        progressFill.layer?.cornerRadius = 1.5
        progressFill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressTrack.addSubview(progressFill)

        nameLabel = makeLabel("", size: 13, weight: .semibold, color: .labelColor)
        content.addSubview(nameLabel)

        infoLabel = makeLabel("", size: 11.5, weight: .regular, color: .secondaryLabelColor)
        infoLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(infoLabel)

        sourceLabel = makeLabel("", size: 11.5, weight: .regular, color: .tertiaryLabelColor)
        sourceLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(sourceLabel)

        panel.setFrame(NSRect(origin: .zero, size: size), display: false)
        panel.contentView = root
        self.panel = panel
        applyLayout()
        return panel
    }

    /// Places everything for the current size (normal or large).
    private func applyLayout() {
        let media = mediaRect
        mediaBackground.frame = media
        imageView.frame = mediaBackground.bounds
        overlayIcon?.frame.origin = NSPoint(x: media.width - 30, y: 8)
        progressTrack.frame = NSRect(x: media.minX, y: media.maxY + 7, width: media.width, height: 3)
        setProgress(progressFraction)

        let textX = media.minX + 2
        let textWidth = media.width - 4
        nameLabel?.frame = NSRect(x: textX, y: media.maxY + 17, width: textWidth, height: 18)
        infoLabel?.frame = NSRect(x: textX, y: media.maxY + 37, width: textWidth, height: 16)
        sourceLabel?.frame = NSRect(x: textX, y: media.maxY + 54, width: textWidth, height: 16)

        if let panel, panel.frame.size != size {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: true)
            panel.invalidateShadow()
        }
    }
}
