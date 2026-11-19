import AppKit

/// "About Floebin" — app icon, version and credits for the maker, with links.
@MainActor
final class AboutController: NSObject {

    private struct Link {
        let title: String
        let symbol: String
        let url: String
    }

    private let author = "Shah Emtiaj"
    private let links: [Link] = [
        Link(title: "shahemtiaj.com", symbol: "globe", url: "https://shahemtiaj.com"),
        Link(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", url: "https://github.com/shahemtiaj"),
        Link(title: "Facebook", symbol: "f.square", url: "https://www.facebook.com/shahemtiaj/"),
        Link(title: "X", symbol: "x.square", url: "https://x.com/shahemtiaj")
    ]

    private var panel: NSPanel?
    private var clickMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the card centered on the screen the button is on.
    func show(near anchor: NSRect) {
        let size = NSSize(width: 320, height: 438)
        let vf = FloatingPanels.visibleFrame(near: anchor)
        let origin = NSPoint(x: (vf.midX - size.width / 2).rounded(), y: (vf.midY - size.height / 2).rounded())

        let panel = self.panel ?? FloatingPanels.make()
        self.panel = panel
        FloatingPanels.show(panel, frame: NSRect(origin: origin, size: size), content: makeContent(size: size))

        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func makeContent(size: NSSize) -> NSView {
        let (root, content) = FloatingPanels.background(size: size)
        let inset: CGFloat = 16
        let fullWidth = size.width - inset * 2

        func centered(_ label: NSTextField, y: CGFloat, height: CGFloat) {
            label.alignment = .center
            label.frame = NSRect(x: inset, y: y, width: fullWidth, height: height)
            content.addSubview(label)
        }

        // App icon, name, version
        let icon = NSImageView(frame: NSRect(x: (size.width - 76) / 2, y: 22, width: 76, height: 76))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        centered(makeLabel("Floebin", size: 20, weight: .bold, color: .labelColor), y: 104, height: 26)

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        centered(makeLabel("Version \(version) (\(build))", size: 11.5, weight: .regular, color: .secondaryLabelColor), y: 131, height: 15)
        centered(makeLabel("Your downloads, one drag away.", size: 12, weight: .regular, color: .secondaryLabelColor), y: 149, height: 16)

        content.addSubview(FloatingPanels.divider(y: 178, width: size.width, inset: inset))

        // Credits
        centered(makeLabel("DESIGNED & BUILT BY", size: 10, weight: .semibold, color: .tertiaryLabelColor), y: 192, height: 13)
        centered(makeLabel(author, size: 16, weight: .semibold, color: .labelColor), y: 207, height: 21)

        // Links
        var y: CGFloat = 242
        for link in links {
            let button = PillButton(title: link.title, symbol: link.symbol, style: .normal, height: 30)
            button.frame = NSRect(x: inset, y: y, width: fullWidth, height: 30)
            button.toolTip = link.url
            let address = link.url
            button.onPress = { [weak self] in
                self?.hide()
                if let url = URL(string: address) {
                    NSWorkspace.shared.open(url)
                }
            }

            // Small "opens in browser" arrow on the right
            let arrow = NSImageView(frame: NSRect(x: fullWidth - 26, y: 8, width: 14, height: 14))
            arrow.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Open link")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            arrow.contentTintColor = .tertiaryLabelColor
            arrow.imageScaling = .scaleNone
            button.addSubview(arrow)

            content.addSubview(button)
            y += 36
        }

        // Footer
        let year = Calendar.current.component(.year, from: Date())
        let copyright = makeLabel("© \(year) \(author)", size: 11, weight: .regular, color: .tertiaryLabelColor)
        copyright.frame = NSRect(x: inset, y: size.height - 36, width: 180, height: 15)
        content.addSubview(copyright)

        let done = PillButton(title: "Done", symbol: nil, style: .prominent, height: 28)
        done.frame.origin = NSPoint(x: size.width - inset - done.frame.width, y: size.height - 16 - 28)
        done.onPress = { [weak self] in
            self?.hide()
        }
        content.addSubview(done)

        return root
    }
}
