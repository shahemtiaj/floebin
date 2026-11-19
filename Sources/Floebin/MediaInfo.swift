import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ImageIO

/// Duration, resolution, frame rate and sample rate for media files.
struct MediaInfo {
    var duration: Double?
    var width: Int?
    var height: Int?
    var fps: Double?
    var sampleRate: Double?

    /// "0:12 · 1920×1080 · 25fps" for video, "0:03 · 48kHz" for audio, "4000×2667" for images.
    var summary: String {
        var parts: [String] = []
        if let duration {
            parts.append(MediaInfo.format(duration: duration))
        }
        if let width, let height {
            parts.append("\(width)×\(height)")
        }
        if let fps {
            parts.append(MediaInfo.format(fps: fps))
        }
        if width == nil, let sampleRate {
            parts.append(MediaInfo.format(sampleRate: sampleRate))
        }
        return parts.joined(separator: " · ")
    }

    static func format(duration: Double) -> String {
        let total = max(1, Int(duration.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func format(fps: Double) -> String {
        let rounded = (fps * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "\(Int(rounded))fps"
        }
        return String(format: "%.2ffps", rounded)
    }

    static func format(sampleRate: Double) -> String {
        let k = sampleRate / 1000
        return k == k.rounded() ? "\(Int(k))kHz" : String(format: "%.1fkHz", k)
    }
}

@MainActor
enum MediaInfoLoader {
    private static var cache: [String: MediaInfo] = [:]

    /// Calls `completion` with the file's media info (right away if cached). Not called for non-media files.
    static func load(_ url: URL, kind: FileKind, completion: @escaping (MediaInfo) -> Void) {
        if let cached = MediaInfoLoader.cache[url.path] {
            completion(cached)
            return
        }
        guard kind == .video || kind == .audio || kind == .image else { return }

        Task { @MainActor in
            let info = await compute(url, kind: kind)
            MediaInfoLoader.cache[url.path] = info
            completion(info)
        }
    }

    private static func compute(_ url: URL, kind: FileKind) async -> MediaInfo {
        var info = MediaInfo()

        if kind == .image {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                info.width = props[kCGImagePropertyPixelWidth] as? Int
                info.height = props[kCGImagePropertyPixelHeight] as? Int
            }
            return info
        }

        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            let seconds = duration.seconds
            if seconds.isFinite && seconds > 0 {
                info.duration = seconds
            }
        }

        if kind == .video, let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let loaded = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate) {
                // Apply the rotation so vertical videos read 1080×1920.
                let rect = CGRect(origin: .zero, size: loaded.0).applying(loaded.1)
                info.width = Int(abs(rect.width).rounded())
                info.height = Int(abs(rect.height).rounded())
                if loaded.2 > 0 {
                    info.fps = Double(loaded.2)
                }
            }
        }

        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let descriptions = try? await track.load(.formatDescriptions),
           let first = descriptions.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first) {
            info.sampleRate = asbd.pointee.mSampleRate
        }
        return info
    }
}

/// Which website a download came from. macOS stores this on every downloaded file
/// (the "Where from" field in Finder's Get Info), plus a copy in the download's quarantine info.
///
/// Only *found* answers are cached: browsers often add these details a moment after the file
/// appears, so a "nothing yet" answer is checked again next time instead of being remembered.
@MainActor
enum DownloadSource {
    private static var cache: [String: URL] = [:]

    /// The page the file was downloaded from (falls back to the file's own URL).
    static func pageURL(for url: URL) -> URL? {
        if let cached = DownloadSource.cache[url.path] {
            return cached
        }
        guard let found = readWhereFroms(url) ?? readQuarantineOrigin(url) else { return nil }
        DownloadSource.cache[url.path] = found
        return found
    }

    /// "pexels.com", "envato.com"…
    static func host(for url: URL) -> String? {
        guard let host = pageURL(for: url)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func readWhereFroms(_ url: URL) -> URL? {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }

        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(url.path, name, buffer.baseAddress, size, 0, 0)
        }
        guard read > 0 else { return nil }

        guard let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] else {
            return nil
        }
        let urls = list
            .compactMap { URL(string: $0) }
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        // [download URL, page URL] — the page is the more useful one.
        return urls.count > 1 ? urls[1] : urls.first
    }

    private static func readQuarantineOrigin(_ url: URL) -> URL? {
        guard let props = (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties else {
            return nil
        }
        for key in ["LSQuarantineOriginURL", "LSQuarantineDataURL"] {
            if let found = props[key] as? URL, ["http", "https"].contains(found.scheme?.lowercased() ?? "") {
                return found
            }
            if let text = props[key] as? String, let found = URL(string: text),
               ["http", "https"].contains(found.scheme?.lowercased() ?? "") {
                return found
            }
        }
        return nil
    }
}

/// Which browser downloaded a file.
///
/// macOS records the downloading app on every download ("quarantine" info): its exact app ID
/// (e.g. com.google.Chrome) and its name. The app ID is the reliable part — it finds the real app
/// even for Chrome-family browsers whose helper processes write the file (com.google.Chrome.helper).
@MainActor
enum DownloadBrowser {
    private struct Agent {
        let name: String?
        let bundleID: String?
    }

    private static var agentCache: [String: Agent] = [:]
    private static var iconCache: [String: NSImage] = [:]

    /// Fallback when only a name is known.
    private static let bundleIDs: [String: String] = [
        "Google Chrome": "com.google.Chrome",
        "Google Chrome Beta": "com.google.Chrome.beta",
        "Google Chrome Canary": "com.google.Chrome.canary",
        "Chrome": "com.google.Chrome",
        "Safari": "com.apple.Safari",
        "Safari Technology Preview": "com.apple.SafariTechnologyPreview",
        "Firefox": "org.mozilla.firefox",
        "Firefox Developer Edition": "org.mozilla.firefoxdeveloperedition",
        "Microsoft Edge": "com.microsoft.edgemac",
        "Arc": "company.thebrowser.Browser",
        "Brave Browser": "com.brave.Browser",
        "Brave": "com.brave.Browser",
        "Opera": "com.operasoftware.Opera",
        "Opera GX": "com.operasoftware.OperaGX",
        "Vivaldi": "com.vivaldi.Vivaldi",
        "Chromium": "org.chromium.Chromium",
        "Zen Browser": "app.zen-browser.zen",
        "Zen": "app.zen-browser.zen",
        "Orion": "com.kagi.kagimacOS",
        "DuckDuckGo": "com.duckduckgo.macos.browser",
        "Dia": "company.thebrowser.dia"
    ]

    /// "Google Chrome", "Safari"… (nil if unknown).
    static func name(for url: URL) -> String? {
        let agent = agentInfo(url)
        if let name = agent.name {
            return name
        }
        if let id = agent.bundleID, let app = appURL(bundleID: id) {
            return app.deletingPathExtension().lastPathComponent
        }
        return nil
    }

    /// The downloading app's real icon, if that app is on this Mac.
    static func icon(for url: URL) -> NSImage? {
        let agent = agentInfo(url)
        let key = agent.bundleID ?? agent.name ?? ""
        guard !key.isEmpty else { return nil }
        if let cached = DownloadBrowser.iconCache[key] {
            return cached
        }
        var app: URL?
        if let id = agent.bundleID {
            app = appURL(bundleID: id)
        }
        if app == nil, let name = agent.name {
            app = appURL(named: name)
        }
        guard let found = app else { return nil } // e.g. "sharingd" for AirDrop — not an app we can show
        let icon = NSWorkspace.shared.icon(forFile: found.path)
        DownloadBrowser.iconCache[key] = icon
        return icon
    }

    private static func agentInfo(_ url: URL) -> Agent {
        if let cached = DownloadBrowser.agentCache[url.path] {
            return cached
        }

        var name: String?
        var bundleID: String?
        if let props = (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties {
            name = props["LSQuarantineAgentName"] as? String
            bundleID = props["LSQuarantineAgentBundleIdentifier"] as? String
        }
        if name == nil {
            name = readAgentName(url)
        }
        name = name.map { cleanName($0) }.flatMap { $0.isEmpty ? nil : $0 }
        bundleID = bundleID.map { cleanBundleID($0) }.flatMap { $0.isEmpty ? nil : $0 }

        let agent = Agent(name: name, bundleID: bundleID)
        // Only remember real answers — the browser may not have stamped the file yet.
        if name != nil || bundleID != nil {
            DownloadBrowser.agentCache[url.path] = agent
        }
        return agent
    }

    /// "Google Chrome Helper (Renderer)" → "Google Chrome", "Arc.app" → "Arc"
    private static func cleanName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if let helper = name.range(of: " Helper") {
            name = String(name[..<helper.lowerBound])
        }
        if name.hasSuffix(".app") {
            name = String(name.dropLast(4))
        }
        return name
    }

    /// "com.google.Chrome.helper.renderer" → "com.google.Chrome"
    private static func cleanBundleID(_ raw: String) -> String {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        if let index = parts.firstIndex(where: { $0.lowercased().hasPrefix("helper") }), index > 0 {
            return parts[..<index].joined(separator: ".")
        }
        return parts.joined(separator: ".")
    }

    private static func appURL(bundleID: String) -> URL? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return outermostApp(url)
    }

    private static func appURL(named name: String) -> URL? {
        if let id = bundleIDs[name], let url = appURL(bundleID: id) {
            return url
        }
        for folder in ["/Applications", "/System/Applications", "/System/Volumes/Preboot/Cryptexes/App/System/Applications", NSHomeDirectory() + "/Applications"] {
            let path = "\(folder)/\(name).app"
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// A helper app inside Chrome.app/Contents/Frameworks/… → Chrome.app itself.
    private static func outermostApp(_ url: URL) -> URL {
        let components = url.pathComponents
        if let index = components.firstIndex(where: { $0.hasSuffix(".app") }) {
            return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])))
        }
        return url
    }

    /// Older fallback: the plain quarantine tag "flags;timestamp;AppName;UUID".
    private static func readAgentName(_ url: URL) -> String? {
        let attribute = "com.apple.quarantine"
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }

        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(url.path, attribute, buffer.baseAddress, size, 0, 0)
        }
        guard read > 0, let text = String(data: data, encoding: .utf8) else { return nil }

        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let agent = String(parts[2])
        return agent.isEmpty ? nil : agent
    }
}
