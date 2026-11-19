import AppKit
import UniformTypeIdentifiers

// MARK: - Floebin mark

@MainActor
enum Glyph {
    /// Floebin's mark — an ice floe with a download arrow cut into it, floating on a waterline.
    /// Template image, so it tints to match the menu bar / any color.
    static func floe(size: CGFloat, badge: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let w = rect.width
            let h = rect.height
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: rect.minX + x * w, y: rect.minY + y * h)
            }
            NSColor.black.setFill()

            let floe = NSBezierPath()
            floe.windingRule = .evenOdd
            floe.move(to: p(0.04, 0.34))
            floe.line(to: p(0.16, 0.64))
            floe.line(to: p(0.38, 0.80))
            floe.line(to: p(0.60, 0.86))
            floe.line(to: p(0.80, 0.72))
            floe.line(to: p(0.94, 0.52))
            floe.line(to: p(0.98, 0.34))
            floe.close()
            // The arrow is cut out of the floe (even-odd fill makes it a hole).
            floe.appendRect(NSRect(x: rect.minX + 0.43 * w, y: rect.minY + 0.50 * h, width: 0.14 * w, height: 0.22 * h))
            floe.move(to: p(0.28, 0.50))
            floe.line(to: p(0.72, 0.50))
            floe.line(to: p(0.50, 0.34))
            floe.close()
            floe.fill()

            // Ripples
            let r = 0.035 * h
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 0.04 * w, y: rect.minY + 0.16 * h, width: 0.34 * w, height: 0.07 * h), xRadius: r, yRadius: r).fill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 0.62 * w, y: rect.minY + 0.16 * h, width: 0.34 * w, height: 0.07 * h), xRadius: r, yRadius: r).fill()

            // "New download" dot, top-right, with a small gap cut around it
            if badge {
                let dot = NSRect(x: rect.minX + 0.70 * w, y: rect.minY + 0.70 * h, width: 0.30 * w, height: 0.30 * h)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -0.07 * w, dy: -0.07 * h)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - File kinds (for colored badges and icon tiles)

enum FileKind {
    case video, audio, image, font, lut, archive, document, folder, other

    static func of(_ url: URL) -> FileKind {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true && values?.isPackage != true {
            return .folder
        }
        let ext = url.pathExtension.lowercased()
        if ["cube", "3dl", "look", "lut"].contains(ext) {
            return .lut
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .font) { return .font }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .pdf) || type.conforms(to: .text)
            || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) {
            return .document
        }
        return .other
    }

    var color: NSColor {
        switch self {
        case .video: return .systemPurple
        case .audio: return .systemPink
        case .image: return .systemGreen
        case .font: return .systemOrange
        case .lut: return .systemTeal
        case .archive: return .systemBrown
        case .document: return .systemBlue
        case .folder: return .systemCyan
        case .other: return .systemGray
        }
    }

    /// SF Symbol used when a file has no preview thumbnail.
    var symbol: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .font: return "textformat"
        case .lut: return "camera.filters"
        case .archive: return "doc.zipper"
        case .document: return "doc.text"
        case .folder: return "folder.fill"
        case .other: return "doc"
        }
    }

    /// Short badge text: the file extension (MP4, WAV, OTF…), or FOLDER.
    static func badgeText(for url: URL, kind: FileKind) -> String {
        if kind == .folder { return "FOLDER" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : String(ext.prefix(5))
    }
}

// MARK: - Dates

enum FileDates {
    /// When the file landed in Downloads (falls back to its modification date).
    static func added(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
        return values?.addedToDirectoryDate ?? values?.contentModificationDate
    }

    /// "Just now", "12m ago", "4h ago", "Yesterday", "3d ago", "12 Nov"
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if Calendar.current.isDateInToday(date) { return "\(Int(seconds / 3600))h ago" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        if seconds < 7 * 86400 { return "\(Int(seconds / 86400))d ago" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }

    /// Section the list groups a file under.
    static func section(for date: Date?) -> String {
        guard let date else { return "Earlier" }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return "Earlier"
    }
}

// MARK: - Small building blocks

/// A view whose coordinates run top-down, which makes list layout simpler.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingMiddle
    return field
}

@MainActor
func makeWrappingLabel(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size)
    field.textColor = color
    field.isSelectable = false
    return field
}

/// A rounded "pill" with short bold text, e.g. MP4. Solid = colored fill + white text.
@MainActor
func makeBadge(_ text: String, color: NSColor, solid: Bool, fontSize: CGFloat) -> NSView {
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let textSize = (text as NSString).size(withAttributes: [.font: font])
    let textHeight = ceil(textSize.height)
    let height = textHeight + 2
    let width = ceil(textSize.width) + 12

    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    container.wantsLayer = true
    container.layer?.cornerRadius = height / 2
    container.layer?.backgroundColor = (solid ? color : color.withAlphaComponent(0.16)).cgColor

    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = solid ? .white : color
    label.alignment = .center
    label.frame = NSRect(x: 0, y: (height - textHeight) / 2, width: width, height: textHeight)
    container.addSubview(label)
    return container
}

/// A rounded button drawn by hand, so icon and text sit together exactly where we want them.
final class PillButton: NSView {

    enum Style {
        case normal      // soft gray fill
        case prominent   // accent fill, white text
        case subtle      // no fill until hovered (icon buttons)
    }

    var onPress: (() -> Void)?

    private let style: Style
    private let titleText: String?
    private var isHovering = false {
        didSet { updateBackground() }
    }
    private var isPressed = false {
        didSet { updateBackground() }
    }

    init(title: String?, symbol: String?, style: Style = .normal, height: CGFloat = 28) {
        self.style = style
        self.titleText = title

        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textColor: NSColor = style == .prominent ? .white : .labelColor
        let iconColor: NSColor = style == .prominent ? .white : .secondaryLabelColor
        let iconSize: CGFloat = 16
        let gap: CGFloat = 5
        let padding: CGFloat = 12

        var icon: NSImageView?
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title ?? symbol)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)) {
            let view = NSImageView()
            view.image = image
            view.contentTintColor = iconColor
            view.imageScaling = .scaleNone
            icon = view
        }

        var label: NSTextField?
        var labelSize = NSSize.zero
        if let title {
            let field = NSTextField(labelWithString: title)
            field.font = font
            field.textColor = textColor
            labelSize = field.intrinsicContentSize
            label = field
        }

        let width: CGFloat
        if label == nil {
            width = height // round icon button
        } else {
            width = ceil(padding * 2 + (icon == nil ? 0 : iconSize + gap) + labelSize.width)
        }

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = height / 2

        var x: CGFloat = label == nil ? (width - iconSize) / 2 : padding
        if let icon {
            icon.frame = NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
            addSubview(icon)
            x += iconSize + gap
        }
        if let label {
            label.frame = NSRect(x: x, y: ((height - labelSize.height) / 2).rounded(), width: ceil(labelSize.width), height: labelSize.height)
            addSubview(label)
        }

        updateBackground()
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))

        // VoiceOver: a real button with a name
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title ?? symbol)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Icon-only buttons take their spoken name from the tooltip.
    override var toolTip: String? {
        didSet {
            if titleText == nil {
                setAccessibilityLabel(toolTip)
            }
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    private func updateBackground() {
        let color: NSColor
        switch style {
        case .prominent:
            color = NSColor.controlAccentColor.withAlphaComponent(isPressed ? 0.7 : (isHovering ? 0.88 : 1))
        case .normal:
            color = NSColor.labelColor.withAlphaComponent(isPressed ? 0.18 : (isHovering ? 0.13 : 0.08))
        case .subtle:
            color = NSColor.labelColor.withAlphaComponent(isPressed ? 0.16 : (isHovering ? 0.1 : 0))
        }
        layer?.backgroundColor = color.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onPress?()
        }
    }
}

// MARK: - Keyboard

/// A floating panel that can take keyboard input (the recent list, when opened with the shortcut)
/// without activating Floebin or pulling the app you're in to the background.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Invisible view that receives key presses for a panel. Never intercepts clicks.
final class KeyCatcherView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), window?.firstResponder === self, onKeyDown?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Floating panels (list, welcome tips)

@MainActor
enum FloatingPanels {
    /// A borderless panel that floats over everything, including full-screen apps,
    /// and never steals focus.
    static func make(keyable: Bool = false) -> NSPanel {
        let panel: NSPanel
        if keyable {
            panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        } else {
            panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        }
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    /// The usable area of the screen the anchor is on.
    static func visibleFrame(near anchor: NSRect) -> NSRect {
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Beside the anchor, on whichever side has more room, kept on screen.
    static func origin(for size: NSSize, beside anchor: NSRect) -> NSPoint {
        let vf = visibleFrame(near: anchor)
        var x = anchor.midX > vf.midX ? anchor.minX - size.width - 12 : anchor.maxX + 12
        var y = anchor.maxY - size.height
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }

    /// Centered under the anchor (used for the menu bar icon), kept on screen.
    static func origin(for size: NSSize, below anchor: NSRect) -> NSPoint {
        let vf = visibleFrame(near: anchor)
        var x = anchor.midX - size.width / 2
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        let y = max(anchor.minY - size.height - 6, vf.minY + 8)
        return NSPoint(x: x, y: y)
    }

    /// Frosted rounded background + a top-down content view to lay things out in.
    static func background(size: NSSize) -> (root: NSVisualEffectView, content: FlippedView) {
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: 14)

        let content = FlippedView(frame: effect.bounds)
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return (effect, content)
    }

    /// A thin divider line, inset from the panel edges.
    static func divider(y: CGFloat, width: CGFloat, inset: CGFloat) -> NSView {
        let line = NSView(frame: NSRect(x: inset, y: y, width: width - inset * 2, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return line
    }

    static func show(_ panel: NSPanel, frame: NSRect, content: NSView) {
        let wasVisible = panel.isVisible
        panel.setFrame(frame, display: false)
        panel.contentView = content
        panel.invalidateShadow()
        if wasVisible {
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
