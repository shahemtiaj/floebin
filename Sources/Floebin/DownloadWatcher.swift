import Foundation

/// Watches a folder (normally ~/Downloads) and reports files that have
/// *finished* downloading. Browsers write to a temporary name while a download
/// is in progress and rename it when done, so we ignore partial files and only
/// report a path the first time it shows up in its final form.
@MainActor
final class DownloadWatcher {
    let folder: URL

    /// Called once per finished download, oldest first.
    var onNewFile: ((URL) -> Void)?
    /// Called when the folder can't be read (usually: macOS privacy permission not granted yet).
    var onAccessDenied: (() -> Void)?
    /// Called once the folder is readable and watching has started.
    var onStarted: (() -> Void)?
    /// Called when a download starts or the last one finishes.
    var onDownloadingChanged: ((Bool) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var seen = Set<String>()
    private var isDownloading = false
    /// True while a file in this folder is still downloading.
    var isDownloadingNow: Bool { isDownloading }
    private var recheckScheduled = false
    private var stabilityRecheckScheduled = false

    /// Temporary extensions used while downloading:
    /// Chrome/Edge/Arc/Brave: .crdownload · Firefox: .part · Safari: .download · Opera: .opdownload
    private static let partialExtensions: Set<String> = [
        "crdownload", "part", "download", "partial", "opdownload", "tmp"
    ]

    init(folder: URL) {
        self.folder = folder
    }

    func start() {
        guard source == nil else { return }

        guard let files = try? listFiles() else {
            onAccessDenied?()
            // Try again in a few seconds — the user may be answering the
            // "Floebin would like to access files in your Downloads folder" prompt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.start() }
            }
            return
        }

        // Everything already in the folder at launch is "old".
        seen = Set(files.map { $0.path })

        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            onAccessDenied?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.start() }
            }
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .link, .extend],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        src.setCancelHandler {
            close(fd)
        }
        src.resume()
        source = src
        onStarted?()
        updateDownloading(files)
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// The newest finished files already in the folder, newest first.
    /// Fast even with thousands of files: dates are read once, newest first,
    /// and checking stops as soon as there are enough.
    func latestFiles(limit: Int, excluding: (URL) -> Bool = { _ in false }) -> [URL] {
        guard limit > 0, let files = try? listFiles() else { return [] }
        let names = Set(files.map { $0.lastPathComponent })
        let dated = files
            .map { (url: $0, date: addedDate($0)) }
            .sorted { $0.date > $1.date }
        var result: [URL] = []
        for entry in dated {
            if isReady(entry.url, siblingNames: names) && !excluding(entry.url) {
                result.append(entry.url)
                if result.count >= limit {
                    break
                }
            }
        }
        return result
    }

    // MARK: - Scanning

    /// Folder events come in bursts, so scan shortly after, and once more a
    /// bit later to catch files whose size was still 0 on the first pass.
    private func scheduleScan() {
        for delay in [0.4, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.scan() }
            }
        }
    }

    private func scan() {
        guard let files = try? listFiles() else { return }

        // Forget files that were deleted, so a re-download with the same name counts as new.
        seen.formIntersection(Set(files.map { $0.path }))

        let names = Set(files.map { $0.lastPathComponent })
        let now = Date()
        var stillWriting = false
        let fresh = files
            .filter { !seen.contains($0.path) && isReady($0, siblingNames: names) }
            .filter { url in
                // Written to a moment ago? It may still be saving (some apps write in place
                // without a temporary name) — look again shortly instead of grabbing half a file.
                if let written = latestWrite(url), now.timeIntervalSince(written) < 1.5 {
                    stillWriting = true
                    return false
                }
                return true
            }
            .map { (url: $0, date: addedDate($0)) }
            .sorted { $0.date < $1.date }
            .map { $0.url }

        for url in fresh {
            seen.insert(url.path)
            onNewFile?(url)
        }
        updateDownloading(files)

        if stillWriting && !stabilityRecheckScheduled {
            stabilityRecheckScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                MainActor.assumeIsolated {
                    self?.stabilityRecheckScheduled = false
                    self?.scan()
                }
            }
        }
    }

    /// Last time a file was written. For folders (Safari's ".download" bundles, unzipped folders)
    /// that's the newest file inside, because writing a file doesn't touch its folder's date.
    private func latestWrite(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
        var latest = values?.contentModificationDate
        if values?.isDirectory == true,
           let inner = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for item in inner {
                if let date = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date > (latest ?? .distantPast) {
                    latest = date
                }
            }
        }
        return latest
    }

    // MARK: - In-progress downloads

    /// A partial file that was written to in the last minute counts as "downloading".
    /// (Abandoned .crdownload files left over from old sessions are ignored.)
    private func updateDownloading(_ files: [URL]) {
        let now = Date()
        let active = files.contains { url in
            guard Self.partialExtensions.contains(url.pathExtension.lowercased()) else { return false }
            guard let modified = latestWrite(url) else { return false }
            return now.timeIntervalSince(modified) < 60
        }

        if active != isDownloading {
            isDownloading = active
            onDownloadingChanged?(active)
        }

        // Writing inside a file doesn't notify the folder, so keep checking while downloading.
        if active && !recheckScheduled {
            recheckScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated {
                    self?.recheckScheduled = false
                    self?.scan()
                }
            }
        }
    }

    private func isReady(_ url: URL, siblingNames: Set<String>) -> Bool {
        let name = url.lastPathComponent

        if Self.partialExtensions.contains(url.pathExtension.lowercased()) {
            return false
        }
        // Firefox creates an empty placeholder with the final name next to "name.part".
        if siblingNames.contains(name + ".part") || siblingNames.contains(name + ".crdownload") {
            return false
        }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            return true // e.g. a folder Safari unzipped
        }
        return (values?.fileSize ?? 0) > 0
    }

    private func addedDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
        return values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast
    }

    private func listFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .addedToDirectoryDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
    }
}
