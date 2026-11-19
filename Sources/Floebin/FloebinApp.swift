import AppKit

/// Entry point. Floebin runs as an "accessory" app: no Dock icon, no main menu,
/// just the floating button and a menu bar icon.
@main
@MainActor
enum FloebinApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
