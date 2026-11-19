import AppKit
import QuickLookThumbnailing

/// Loads Quick Look thumbnails (video frames, images, PDF pages…) with a small cache.
/// Calls `apply` immediately with a placeholder, then again with the real thumbnail if there is one.
@MainActor
enum Thumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    static func load(_ url: URL, side: CGFloat, scale: CGFloat, placeholder: NSImage? = nil, apply: @escaping (NSImage) -> Void) {
        // Cache per size, so the small row thumbnail never stands in for the big preview.
        // …and per file version, so a re-download with the same name gets a fresh thumbnail.
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let stamp = Int(modified?.timeIntervalSinceReferenceDate ?? 0)
        let key = "\(url.path)|\(Int(side))|\(stamp)" as NSString
        if let cached = Thumbnails.cache.object(forKey: key) {
            apply(cached)
            return
        }
        apply(placeholder ?? NSWorkspace.shared.icon(forFile: url.path))

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail
        )
        Task { @MainActor in
            guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return }
            Thumbnails.cache.setObject(rep.nsImage, forKey: key)
            apply(rep.nsImage)
        }
    }

    /// A colored tile with the file type's symbol, for files without a preview.
    static func kindTile(_ kind: FileKind, side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            kind.color.withAlphaComponent(0.18).setFill()
            rect.fill()

            let config = NSImage.SymbolConfiguration(pointSize: side * 0.4, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [kind.color]))
            if let symbol = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
    }

    /// Scales an image to fill a square, cropping the edges.
    static func aspectFill(_ image: NSImage, side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let s = image.size
            guard s.width > 0, s.height > 0 else { return false }
            let scale = max(rect.width / s.width, rect.height / s.height)
            let w = s.width * scale
            let h = s.height * scale
            image.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
            return true
        }
    }
}
