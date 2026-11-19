import AppKit

/// Checks GitHub Releases for a newer Floebin and offers the download.
///
/// Publish a release at github.com/shahemtiaj/floebin with a tag like "v0.9.0"
/// (and Floebin.dmg attached); every copy of Floebin will see it within a day.
@MainActor
final class UpdateChecker {

    static let repository = "shahemtiaj/floebin"
    static let autoKey = "FloebinAutoUpdateCheck"
    private static let lastCheckKey = "FloebinLastUpdateCheck"

    /// Hide floating panels before an alert appears.
    var beforeAlert: (() -> Void)?

    var automaticChecks: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoKey) }
    }

    /// Quietly checks once a day (if turned on). Only speaks up when there's an update.
    func checkIfDue() {
        guard automaticChecks else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

        Task { @MainActor [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let self else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    if userInitiated {
                        self.alert(title: "No releases yet",
                                   text: "Couldn't find a published Floebin release on GitHub (\(Self.repository)).")
                    }
                    return
                }

                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                let page = (json["html_url"] as? String).flatMap { URL(string: $0) }

                if Self.isVersion(latest, newerThan: current) {
                    self.offerUpdate(latest: latest, current: current, page: page, notes: json["body"] as? String)
                } else if userInitiated {
                    self.alert(title: "You're up to date", text: "Floebin \(current) is the newest version.")
                }
            } catch {
                if userInitiated {
                    self?.alert(title: "Couldn't check for updates", text: error.localizedDescription)
                }
            }
        }
    }

    /// "0.10.0" is newer than "0.9.2".
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y {
                return x > y
            }
        }
        return false
    }

    private func offerUpdate(latest: String, current: String, page: URL?, notes: String?) {
        beforeAlert?()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Floebin \(latest) is available"
        var text = "You have \(current)."
        if let notes, !notes.isEmpty {
            text += "\n\n" + String(notes.prefix(600))
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let fallback = URL(string: "https://github.com/\(Self.repository)/releases/latest")
            if let target = page ?? fallback {
                NSWorkspace.shared.open(target)
            }
        }
    }

    private func alert(title: String, text: String) {
        beforeAlert?()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
