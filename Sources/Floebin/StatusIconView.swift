import AppKit

/// Sits on top of the menu bar icon when "Click Menu Bar Icon for Recent Downloads" is on.
/// - Click: open the recent list under the icon
/// - Drag: drag your newest download straight out of the menu bar
/// - Right-click / Control-click: the regular Floebin menu
final class StatusIconView: NSView, NSDraggingSource {

    var fileProvider: (() -> URL?)?
    var onClick: (() -> Void)?
    var onMenu: (() -> Void)?
    var onDropped: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var mouseDownPoint: NSPoint = .zero
    private var didStartDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Floebin")
        setAccessibilityHelp("Press for recent downloads. Drag to drop your newest download.")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        onMenu?()
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onMenu?()
            return
        }
        mouseDownEvent = event
        mouseDownPoint = NSEvent.mouseLocation
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDownEvent != nil, !didStartDrag, let url = fileProvider?() else { return }
        let now = NSEvent.mouseLocation
        guard hypot(now.x - mouseDownPoint.x, now.y - mouseDownPoint.y) > 3 else { return }
        didStartDrag = true

        let side: CGFloat = 36
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(
            NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side),
            contents: NSWorkspace.shared.icon(forFile: url.path)
        )
        beginDraggingSession(with: [item], event: mouseDownEvent ?? event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil, !didStartDrag else { return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?()
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        didStartDrag = false
        mouseDownEvent = nil
        if operation != [] {
            onDropped?()
        }
    }
}
