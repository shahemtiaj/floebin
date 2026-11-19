import AppKit

/// The round floating button. Shows the current file's thumbnail with a colored type badge,
/// spins while a download is in progress, and lets you drag the file into any app.
///
/// - Drag (with a file)                 → drags the file out
/// - Option-drag, or drag with no file  → moves the button
/// - Click                              → recent downloads list
/// - Right-click                        → menu (file actions, position & size)
final class FloeButtonView: NSView, NSDraggingSource {

    var fileURL: URL? {
        didSet { updateContent() }
    }

    var isDownloading = false {
        didSet {
            if isDownloading != oldValue {
                updateSpinner()
                updateToolTip()
            }
        }
    }

    var onMoved: ((NSPoint) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDropped: (() -> Void)?
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    /// The file was moved or deleted in Finder.
    var onFileMissing: (() -> Void)?

    /// When false (position locked), the button can't be moved by dragging.
    var allowsMoving = true

    /// Shown as the tooltip when there is no file yet.
    var idleMessage = "Floebin — waiting for your next download" {
        didSet { if fileURL == nil { toolTip = idleMessage } }
    }

    private let inset: CGFloat
    private let background = NSVisualEffectView()
    private let imageView = NSImageView()
    private let successOverlay = NSView()
    private let borderLayer = CAShapeLayer()
    private let spinner = CAShapeLayer()
    private let ring = CALayer()
    private var badgeView: NSView?

    private var mouseDownEvent: NSEvent?
    private var mouseDownScreenPoint: NSPoint = .zero
    private var mouseDownWindowOrigin: NSPoint = .zero
    private var isMovingWindow = false
    private var didStartDrag = false
    private var thumbnailToken = UUID()

    override init(frame frameRect: NSRect) {
        inset = max(4, (frameRect.width * 0.09).rounded())
        super.init(frame: frameRect)
        wantsLayer = true

        // Frosted circle
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = NSImage(size: frameRect.size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        addSubview(background)

        // Thumbnail / icon, clipped to a circle
        let imageFrame = bounds.insetBy(dx: inset, dy: inset)
        imageView.frame = imageFrame
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = imageFrame.width / 2
        imageView.layer?.masksToBounds = true
        addSubview(imageView)

        // "Dropped!" checkmark overlay
        successOverlay.frame = imageFrame
        successOverlay.wantsLayer = true
        successOverlay.layer?.cornerRadius = imageFrame.width / 2
        successOverlay.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.85).cgColor
        successOverlay.alphaValue = 0
        let check = NSImageView(frame: successOverlay.bounds)
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Dropped")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: frameRect.width * 0.32, weight: .bold))
        check.contentTintColor = .white
        check.imageScaling = .scaleNone
        successOverlay.addSubview(check)
        addSubview(successOverlay)

        // Hairline border
        borderLayer.frame = bounds
        borderLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)

        // Download-in-progress spinner
        spinner.frame = bounds
        spinner.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.75, dy: 1.75), transform: nil)
        spinner.fillColor = nil
        spinner.strokeColor = NSColor.controlAccentColor.cgColor
        spinner.lineWidth = 2.5
        spinner.lineCap = .round
        spinner.strokeStart = 0
        spinner.strokeEnd = 0.28
        spinner.isHidden = true
        layer?.addSublayer(spinner)

        // Pulse ring
        ring.frame = bounds.insetBy(dx: 1, dy: 1)
        ring.cornerRadius = ring.frame.width / 2
        ring.borderWidth = 2.5
        ring.borderColor = NSColor.controlAccentColor.cgColor
        ring.opacity = 0
        layer?.addSublayer(ring)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))

        // VoiceOver: announce it as a button with the current file
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Drag to drop the file into any app. Press for recent downloads.")

        updateContent()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = menuProvider?() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: self)
        return true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - Content

    private func updateContent() {
        updateAccessibilityLabel()
        thumbnailToken = UUID()
        badgeView?.removeFromSuperview()
        badgeView = nil

        guard let url = fileURL else {
            toolTip = isDownloading ? "Downloading…" : idleMessage
            imageView.imageScaling = .scaleNone
            imageView.contentTintColor = .secondaryLabelColor
            imageView.image = Glyph.floe(size: (bounds.width * 0.5).rounded())
            return
        }

        toolTip = isDownloading
            ? "Downloading…"
            : "\(url.lastPathComponent)\nDrag into any app · Click for recent downloads"
        imageView.contentTintColor = nil
        imageView.imageScaling = .scaleAxesIndependently

        let kind = FileKind.of(url)
        let side = imageView.bounds.width
        let token = thumbnailToken
        Thumbnails.load(url, side: side, scale: window?.backingScaleFactor ?? 2,
                        placeholder: Thumbnails.kindTile(kind, side: side)) { [weak self] image in
            guard let self, self.thumbnailToken == token else { return }
            self.imageView.image = Thumbnails.aspectFill(image, side: side)
        }

        // Colored type badge (MP4, WAV, OTF…) along the bottom edge
        let fontSize: CGFloat = bounds.width >= 60 ? 9 : 8
        let badge = makeBadge(FileKind.badgeText(for: url, kind: kind), color: kind.color, solid: true, fontSize: fontSize)
        let maxWidth = bounds.width - 6
        if badge.frame.width > maxWidth {
            badge.frame.size.width = maxWidth
        }
        badge.frame.origin = NSPoint(x: ((bounds.width - badge.frame.width) / 2).rounded(), y: 1)
        addSubview(badge, positioned: .below, relativeTo: successOverlay)
        badgeView = badge
    }

    private func updateToolTip() {
        if isDownloading {
            toolTip = "Downloading…"
        } else if let url = fileURL {
            toolTip = "\(url.lastPathComponent)\nDrag into any app · Click for recent downloads"
        } else {
            toolTip = idleMessage
        }
        updateAccessibilityLabel()
    }

    private func updateAccessibilityLabel() {
        if let url = fileURL {
            setAccessibilityLabel("Floebin, \(url.lastPathComponent)" + (isDownloading ? ", downloading" : ""))
        } else {
            setAccessibilityLabel(isDownloading ? "Floebin, downloading" : "Floebin, no downloads yet")
        }
    }

    private func updateSpinner() {
        if isDownloading {
            spinner.isHidden = false
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.9
            spin.repeatCount = .infinity
            spinner.add(spin, forKey: "spin")
        } else {
            spinner.removeAnimation(forKey: "spin")
            spinner.isHidden = true
        }
    }

    // MARK: - Feedback

    func pulse(color: NSColor = .controlAccentColor) {
        ring.borderColor = color.cgColor
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            anim.values = [0, 1, 0]
            anim.duration = 0.8
        } else {
            anim.values = [0, 1, 0.2, 1, 0]
            anim.duration = 1.2
        }
        ring.add(anim, forKey: "pulse")
    }

    func showSuccess() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.successOverlay.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    self.successOverlay.animator().alphaValue = 0
                }
            }
        }
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        mouseDownScreenPoint = NSEvent.mouseLocation
        mouseDownWindowOrigin = window?.frame.origin ?? .zero
        isMovingWindow = allowsMoving && (event.modifierFlags.contains(.option) || fileURL == nil)
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - mouseDownScreenPoint.x
        let dy = now.y - mouseDownScreenPoint.y

        if isMovingWindow {
            window?.setFrameOrigin(NSPoint(x: mouseDownWindowOrigin.x + dx, y: mouseDownWindowOrigin.y + dy))
            return
        }

        guard !didStartDrag, let url = fileURL, hypot(dx, dy) > 3 else { return }
        didStartDrag = true

        guard FileManager.default.fileExists(atPath: url.path) else {
            onFileMissing?()
            return
        }

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = imageView.image ?? NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(imageView.frame, contents: image)
        beginDraggingSession(with: [item], event: mouseDownEvent ?? event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { isMovingWindow = false }

        if isMovingWindow, let origin = window?.frame.origin {
            let moved = hypot(origin.x - mouseDownWindowOrigin.x, origin.y - mouseDownWindowOrigin.y) > 1
            if moved {
                onMoved?(origin)
                return
            }
        }
        if !didStartDrag {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Always copy, never move: the original stays in Downloads.
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        didStartDrag = false
        if operation != [] {
            showSuccess()
            onDropped?()
        }
    }
}
