import AppKit

/// A newer Floebin published on GitHub Releases.
struct UpdateInfo {
    let version: String
    let notes: String
    let pageURL: URL
    /// The .dmg attached to the release (nil if the release has none).
    let dmgURL: URL?
}

/// Checks GitHub Releases for a newer Floebin.
///
/// Publish a release at github.com/shahemtiaj/floebin with a tag like "v1.0.1" and the DMG attached;
/// every copy of Floebin sees it within a few hours and offers to install it.
@MainActor
final class UpdateChecker {

    static let repository = "shahemtiaj/floebin"
    static let autoKey = "FloebinAutoUpdateCheck"
    static let lastCheckKey = "FloebinLastUpdateCheck"
    static let skippedKey = "FloebinSkippedVersion"

    /// A newer version was found (and wasn't skipped, unless you asked).
    var onUpdateAvailable: ((UpdateInfo) -> Void)?
    /// Hide floating panels before an alert appears.
    var beforeAlert: (() -> Void)?
    /// Any check finished (Settings shows "Last checked …").
    var onChecked: (() -> Void)?

    private var isChecking = false
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var automaticChecks: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoKey) }
    }

    static var lastCheck: Date? {
        UserDefaults.standard.object(forKey: lastCheckKey) as? Date
    }

    /// Checks shortly after launch, then looks every few hours whether a daily check is due
    /// (Floebin often runs for days without restarting).
    func startAutomaticChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    /// Quietly checks once a day (if turned on). Only speaks up when there's an update.
    func checkIfDue() {
        guard automaticChecks else { return }
        guard Date().timeIntervalSince(Self.lastCheck ?? .distantPast) > 20 * 3600 else { return }
        check(userInitiated: false)
    }

    func skip(_ version: String) {
        UserDefaults.standard.set(version, forKey: Self.skippedKey)
    }

    func check(userInitiated: Bool) {
        guard !isChecking else { return }
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Floebin/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        isChecking = true

        Task { @MainActor [weak self] in
            let result: Result<UpdateInfo?, Error>
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                result = .success(try Self.parse(data: data, response: response))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.isChecking = false
            defer { self.onChecked?() }

            switch result {
            case .success(let info):
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                guard let info else {
                    if userInitiated {
                        self.alert(title: "No releases yet",
                                   text: "Couldn't find a published Floebin release on GitHub.")
                    }
                    return
                }
                let current = Self.currentVersion
                let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
                if Self.isVersion(info.version, newerThan: current), userInitiated || skipped != info.version {
                    self.onUpdateAvailable?(info)
                } else if userInitiated {
                    self.alert(title: "You're up to date", text: "Floebin \(current) is the newest version.")
                }
            case .failure(let error):
                if userInitiated {
                    self.alert(title: "Couldn't check for updates",
                               text: "Check your internet connection and try again.\n\n\(error.localizedDescription)")
                }
            }
        }
    }

    private static func parse(data: Data, response: URLResponse) throws -> UpdateInfo? {
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 {
            return nil
        }
        guard http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw URLError(.badServerResponse)
        }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let page = (json["html_url"] as? String).flatMap { URL(string: $0) }
            ?? URL(string: "https://github.com/\(repository)/releases/latest")!
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets
            .first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap { URL(string: $0) }
        return UpdateInfo(version: version, notes: json["body"] as? String ?? "", pageURL: page, dmgURL: dmg)
    }

    /// "1.0.10" is newer than "1.0.9".
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y {
                return x > y
            }
        }
        return false
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

// MARK: - Installing an update

enum UpdateError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// Downloads the release DMG with progress.
final class UpdateDownload: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Double) -> Void
    private let onFinish: @Sendable (Result<URL, Error>) -> Void
    private var session: URLSession?
    private var finished = false

    init(onProgress: @escaping @Sendable (Double) -> Void, onFinish: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func start(_ url: URL) {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func cancel() {
        finished = true
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !finished else { return }
        finished = true
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            onFinish(.failure(UpdateError.message("The download failed (error \(http.statusCode)).")))
            session.finishTasksAndInvalidate()
            return
        }
        // The file at `location` is deleted when this method returns, so move it first.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Floebin-update-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            onFinish(.success(destination))
        } catch {
            onFinish(.failure(error))
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !finished else { return }
        finished = true
        onFinish(.failure(error))
    }
}

/// Unpacks the downloaded DMG and swaps the new Floebin in place of this one.
/// Runs the slow parts off the main thread.
enum UpdateInstaller {

    /// Where this copy of Floebin lives, if Floebin can replace it there.
    static func replaceableAppURL() -> URL? {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return nil }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path),
              fm.isWritableFile(atPath: app.path) else { return nil }
        return app
    }

    /// Mounts the DMG, checks it really is Floebin, and copies the app out. Returns the copied app.
    static func stage(dmg: URL, bundleID: String) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("FloebinUpdate-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)

        let attach = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        guard attach.status == 0 else {
            throw UpdateError.message("Couldn't open the downloaded update.")
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"])
            try? fm.removeItem(at: dmg)
        }

        let items = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.message("The update doesn't contain Floebin.app.")
        }
        guard Bundle(url: app)?.bundleIdentifier == bundleID else {
            throw UpdateError.message("The downloaded app isn't Floebin, so it wasn't installed.")
        }

        let staged = work.appendingPathComponent(app.lastPathComponent)
        let copy = run("/usr/bin/ditto", [app.path, staged.path])
        guard copy.status == 0 else {
            throw UpdateError.message("Couldn't copy the new version.")
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// Starts a tiny helper that waits for Floebin to quit, swaps the app, and opens the new one.
    /// If the swap fails, the old version is put back.
    static func scheduleSwapAndRelaunch(staged: URL, target: URL, pid: Int32) throws {
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        TARGET=\(quote(target.path))
        NEW=\(quote(staged.path))
        rm -rf "$TARGET.old"
        if mv "$TARGET" "$TARGET.old" && /usr/bin/ditto "$NEW" "$TARGET"; then
          rm -rf "$TARGET.old"
        else
          rm -rf "$TARGET"
          mv "$TARGET.old" "$TARGET"
        fi
        rm -rf "$NEW"
        /usr/bin/open "$TARGET"
        """
        let scriptURL = staged.deletingLastPathComponent().appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup /bin/sh \(quote(scriptURL.path)) >/dev/null 2>&1 &"]
        try process.run()
        process.waitUntilExit()
    }

    private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
