import AppKit

/// A short step-by-step tour for first-time users, shown beside the floating button.
/// Skippable at any step; can be replayed from the menu bar → Show Tutorial.
@MainActor
final class TutorialController: NSObject {

    /// Called when the tour is finished or skipped.
    var onFinish: (() -> Void)?
    /// Called each time a step appears (index), e.g. to pulse the button.
    var onStepShown: ((Int) -> Void)?

    private enum Art {
        case appIcon
        case floeMark
        case symbol(String)
    }

    private struct Step {
        let art: Art
        let tint: NSColor
        let title: String
        let body: String
    }

    private let steps: [Step] = [
        Step(art: .appIcon, tint: .systemBlue,
             title: "Welcome to Floebin",
             body: "Your downloads, one drag away. Take a quick 1-minute tour, or skip it if you already know your way around."),
        Step(art: .floeMark, tint: .controlAccentColor,
             title: "Meet your button",
             body: "This round button floats above every app, even full-screen Premiere, Resolve or Figma. It never steals focus from what you're doing."),
        Step(art: .symbol("arrow.down.circle"), tint: .systemTeal,
             title: "Downloads land here",
             body: "When a download finishes in any browser, it lands on the button with a thumbnail and a colored type badge. A spinning ring means something is still downloading."),
        Step(art: .symbol("hand.draw"), tint: .systemGreen,
             title: "Drag it anywhere",
             body: "Drag the button straight onto your timeline, canvas or chat. Floebin drops a copy, so the original stays safe in Downloads."),
        Step(art: .symbol("list.bullet.rectangle"), tint: .systemPurple,
             title: "All your recent downloads",
             body: "Click the button (or press ⌃⌥D) for your recent downloads. Hover to preview, hold ⌥ for a bigger preview, ⌘-click to grab several, right-click to pin."),
        Step(art: .symbol("folder.badge.plus"), tint: .systemOrange,
             title: "Send to your project",
             body: "Set a project folder and send files there, sorted into Footage, Audio, Images and more. Right-click a file to install fonts, unzip, or convert images."),
        Step(art: .symbol("slider.horizontal.3"), tint: .systemPink,
             title: "Make it yours",
             body: "Option-drag the button to move it. Prefer the menu bar? Settings can open your downloads from the menu bar icon, or hide the button. Replay this tour from the menu bar.")
    ]

    private let size = NSSize(width: 340, height: 380)
    private var index = 0
    private var anchor: NSRect = .zero
    private var panel: NSPanel?
    private(set) var isSuspended = false

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: Control

    func start(anchor: NSRect) {
        index = 0
        isSuspended = false
        self.anchor = anchor
        render()
    }

    func hide() {
        isSuspended = false
        panel?.orderOut(nil)
    }

    /// Steps aside while the recent list is open (the user is trying it out)…
    func suspend() {
        guard isVisible else { return }
        isSuspended = true
        panel?.orderOut(nil)
    }

    /// …and comes back to the same step when it closes.
    func resumeIfSuspended(anchor: NSRect) {
        guard isSuspended else { return }
        isSuspended = false
        self.anchor = anchor
        render()
    }

    /// The button moved: move the tour card along with it.
    func follow(anchor: NSRect) {
        guard isVisible else { return }
        self.anchor = anchor
        render()
    }

    private func next() {
        if index < steps.count - 1 {
            index += 1
            render()
        } else {
            finish()
        }
    }

    private func back() {
        guard index > 0 else { return }
        index -= 1
        render()
    }

    private func finish() {
        hide()
        onFinish?()
    }

    // MARK: Drawing

    private func render() {
        let panel = self.panel ?? FloatingPanels.make()
        self.panel = panel
        let frame = NSRect(origin: FloatingPanels.origin(for: size, beside: anchor), size: size)
        FloatingPanels.show(panel, frame: frame, content: makeContent())
        onStepShown?(index)
    }

    private func makeContent() -> NSView {
        let (root, content) = FloatingPanels.background(size: size)
        let step = steps[index]
        let inset: CGFloat = 16
        let width = size.width - inset * 2
        let isFirst = index == 0
        let isLast = index == steps.count - 1

        // Illustration tile
        let tile = NSView(frame: NSRect(x: inset, y: inset, width: width, height: 136))
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 12
        tile.layer?.backgroundColor = step.tint.withAlphaComponent(0.14).cgColor
        content.addSubview(tile)

        let art = NSImageView()
        switch step.art {
        case .appIcon:
            art.frame = NSRect(x: (tile.bounds.width - 96) / 2, y: (tile.bounds.height - 96) / 2, width: 96, height: 96)
            art.image = NSApp.applicationIconImage
            art.imageScaling = .scaleProportionallyUpOrDown
        case .floeMark:
            art.frame = NSRect(x: (tile.bounds.width - 64) / 2, y: (tile.bounds.height - 64) / 2, width: 64, height: 64)
            art.image = Glyph.floe(size: 64)
            art.contentTintColor = step.tint
        case .symbol(let name):
            art.frame = tile.bounds
            art.image = NSImage(systemSymbolName: name, accessibilityDescription: step.title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 54, weight: .regular))
            art.contentTintColor = step.tint
            art.imageScaling = .scaleNone
        }
        tile.addSubview(art)

        // Step label, title, text
        let stepText = isFirst ? "QUICK TOUR" : "STEP \(index) OF \(steps.count - 1)"
        let stepLabel = makeLabel(stepText, size: 10.5, weight: .semibold, color: step.tint)
        stepLabel.frame = NSRect(x: inset, y: 166, width: width, height: 14)
        content.addSubview(stepLabel)

        let title = makeLabel(step.title, size: 18, weight: .bold, color: .labelColor)
        title.frame = NSRect(x: inset, y: 183, width: width, height: 24)
        content.addSubview(title)

        let body = makeWrappingLabel(step.body, size: 12.5, color: .secondaryLabelColor)
        body.frame = NSRect(x: inset, y: 212, width: width, height: 86)
        content.addSubview(body)

        // Progress dots (active one is a wider capsule)
        let dotSize: CGFloat = 6
        let activeWidth: CGFloat = 18
        let gap: CGFloat = 6
        let totalWidth = CGFloat(steps.count - 1) * (dotSize + gap) + activeWidth
        var x = ((size.width - totalWidth) / 2).rounded()
        for i in 0..<steps.count {
            let w = i == index ? activeWidth : dotSize
            let dot = NSView(frame: NSRect(x: x, y: 308, width: w, height: dotSize))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = dotSize / 2
            dot.layer?.backgroundColor = (i == index
                ? NSColor.controlAccentColor
                : NSColor.labelColor.withAlphaComponent(0.18)).cgColor
            content.addSubview(dot)
            x += w + gap
        }

        // Buttons: [Skip]                 [Back] [Next]
        let buttonY = size.height - inset - 28

        let nextTitle = isFirst ? "Start Tour" : (isLast ? "Start Using Floebin" : "Next")
        let nextButton = PillButton(title: nextTitle, symbol: isLast ? "checkmark" : "arrow.right", style: .prominent, height: 28)
        nextButton.frame.origin = NSPoint(x: size.width - inset - nextButton.frame.width, y: buttonY)
        nextButton.onPress = { [weak self] in
            self?.next()
        }
        content.addSubview(nextButton)

        if index > 0 {
            let backButton = PillButton(title: "Back", symbol: nil, style: .normal, height: 28)
            backButton.frame.origin = NSPoint(x: nextButton.frame.minX - 8 - backButton.frame.width, y: buttonY)
            backButton.onPress = { [weak self] in
                self?.back()
            }
            content.addSubview(backButton)
        }

        if !isLast {
            let skipButton = PillButton(title: isFirst ? "Skip" : "Skip Tour", symbol: nil, style: .subtle, height: 28)
            skipButton.frame.origin = NSPoint(x: inset - 6, y: buttonY)
            skipButton.toolTip = "You can replay the tour from the menu bar"
            skipButton.onPress = { [weak self] in
                self?.finish()
            }
            content.addSubview(skipButton)
        }

        return root
    }
}
