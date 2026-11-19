import AppKit
import UniformTypeIdentifiers

struct FloeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - File operations

@MainActor
enum FileOps {

    static func isFont(_ url: URL) -> Bool {
        ["ttf", "otf", "ttc", "otc"].contains(url.pathExtension.lowercased())
    }

    static func isZip(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }

    static func isLUT(_ url: URL) -> Bool {
        FileKind.of(url) == .lut
    }

    static func canConvert(_ url: URL, toPNG: Bool) -> Bool {
        guard FileKind.of(url) == .image else { return false }
        let ext = url.pathExtension.lowercased()
        if ext == "svg" || ext == "pdf" { return false }
        return toPNG ? ext != "png" : !["jpg", "jpeg"].contains(ext)
    }

    /// Project subfolder for a file type.
    static func projectSubfolder(for kind: FileKind) -> String {
        switch kind {
        case .video: return "Footage"
        case .audio: return "Audio"
        case .image: return "Images"
        case .font: return "Fonts"
        case .lut: return "LUTs"
        case .document: return "Documents"
        case .archive: return "Archives"
        case .folder, .other: return "Other"
        }
    }

    /// "name.mp4" → "name 2.mp4" if it already exists.
    static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            i += 1
        }
    }

    static func move(_ url: URL, into folder: URL) throws -> URL {
        // Already there (e.g. sent to the project before)? Leave it alone instead of renaming it "name 2".
        if url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path {
            return url
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = uniqueDestination(folder.appendingPathComponent(url.lastPathComponent))
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    static func copy(_ url: URL, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = uniqueDestination(folder.appendingPathComponent(url.lastPathComponent))
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Copies a font into ~/Library/Fonts (no password needed).
    static func installFont(_ url: URL) throws -> URL {
        let fonts = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts")
        let destination = fonts.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw FloeError("“\(url.lastPathComponent)” is already installed.")
        }
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Writes a PNG or JPG copy next to the original.
    static func convert(_ url: URL, toPNG: Bool) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FloeError("Couldn't read “\(url.lastPathComponent)” as an image.")
        }
        let ext = toPNG ? "png" : "jpg"
        let type: UTType = toPNG ? .png : .jpeg
        let destination = uniqueDestination(url.deletingPathExtension().appendingPathExtension(ext))

        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil) else {
            throw FloeError("Couldn't create “\(destination.lastPathComponent)”.")
        }
        let options: CFDictionary? = toPNG ? nil : [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        CGImageDestinationAddImage(writer, image, options)
        guard CGImageDestinationFinalize(writer) else {
            throw FloeError("Couldn't save “\(destination.lastPathComponent)”.")
        }
        return destination
    }

    /// Unzips into a folder next to the zip (in the background).
    static func unzip(_ url: URL, completion: @escaping (Bool) -> Void) {
        let destination = uniqueDestination(url.deletingPathExtension())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, destination.path]
        process.terminationHandler = { finished in
            let ok = finished.terminationStatus == 0
            DispatchQueue.main.async {
                completion(ok)
            }
        }
        do {
            try process.run()
        } catch {
            completion(false)
        }
    }
}

// MARK: - Actions you can run on files

enum FileAction: String {
    case open, reveal, copyPath, copyFiles, sendToProject
    case installFont, copyToLUTFolder, unzip, toPNG, toJPG
    case openSource, copySource, remove, pin, unpin
}

final class ActionPayload: NSObject {
    let action: FileAction
    let urls: [URL]
    init(_ action: FileAction, _ urls: [URL]) {
        self.action = action
        self.urls = urls
    }
}

/// Builds the file menus and runs file actions. Also owns the project-folder settings.
@MainActor
final class FileActionCenter: NSObject {

    var onMoved: ((URL, URL) -> Void)?
    /// Pin state (pinned files stay on top of the list).
    var isPinned: ((URL) -> Bool)?
    var onPin: (([URL], Bool) -> Void)?
    var onRemoveFromList: (([URL]) -> Void)?
    var onSuccess: (() -> Void)?
    /// Called when the project folder changes (so the list can update its footer).
    var onProjectChanged: (() -> Void)?
    /// Called before an open panel or alert appears (hide floating panels first).
    var beforeModal: (() -> Void)?

    static let projectKey = "FloeProjectPath"
    static let recentProjectsKey = "FloeRecentProjects"
    static let sortKey = "FloeSortByType"
    static let autoSendKey = "FloeAutoSend"
    static let lutFolderKey = "FloeLUTFolder"

    // MARK: Project settings

    var projectURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.projectKey) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path)
    }

    var projectName: String? { projectURL?.lastPathComponent }

    private var sortsByType: Bool { UserDefaults.standard.bool(forKey: Self.sortKey) }
    private var autoSends: Bool { UserDefaults.standard.bool(forKey: Self.autoSendKey) }

    private var recentProjects: [String] {
        (UserDefaults.standard.stringArray(forKey: Self.recentProjectsKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func setProject(_ url: URL?) {
        defer { onProjectChanged?() }
        guard let url else {
            UserDefaults.standard.removeObject(forKey: Self.projectKey)
            return
        }
        UserDefaults.standard.set(url.path, forKey: Self.projectKey)
        var recents = recentProjects.filter { $0 != url.path }
        recents.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(5)), forKey: Self.recentProjectsKey)
    }

    private func destination(for url: URL, in project: URL) -> URL {
        sortsByType ? project.appendingPathComponent(FileOps.projectSubfolder(for: FileKind.of(url))) : project
    }

    /// For new downloads: moves the file into the project if Auto-Send is on. Returns the new location.
    func autoSendIfEnabled(_ url: URL) -> URL? {
        guard autoSends, let project = projectURL else { return nil }
        return try? FileOps.move(url, into: destination(for: url, in: project))
    }

    // MARK: For the Settings window

    var sortsByTypeSetting: Bool {
        get { sortsByType }
        set { UserDefaults.standard.set(newValue, forKey: Self.sortKey) }
    }

    var autoSendSetting: Bool {
        get { autoSends }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoSendKey) }
    }

    var lutFolderPath: String? {
        UserDefaults.standard.string(forKey: Self.lutFolderKey)
    }

    func chooseProjectFolderInteractively() {
        chooseProjectFolder()
    }

    func clearProjectFolder() {
        clearProject()
    }

    func chooseLUTFolderInteractively() {
        guard let url = chooseFolder(prompt: "Use for LUTs",
                                     message: "Choose the folder your editing app loads LUTs from.")
        else { return }
        UserDefaults.standard.set(url.path, forKey: Self.lutFolderKey)
        onProjectChanged?()
    }

    // MARK: Menus

    func menu(for urls: [URL]) -> NSMenu {
        let menu = NSMenu()
        guard !urls.isEmpty else { return menu }
        let single = urls.count == 1

        menu.addItem(header(single ? urls[0].lastPathComponent : "\(urls.count) files selected"))
        menu.addItem(item("Open", .open, urls, symbol: "arrow.up.forward.app"))
        menu.addItem(item("Show in Finder", .reveal, urls, symbol: "folder"))
        menu.addItem(item(single ? "Copy File" : "Copy \(urls.count) Files", .copyFiles, urls, symbol: "doc.on.clipboard"))
        menu.addItem(item(single ? "Copy Path" : "Copy Paths", .copyPath, urls, symbol: "doc.on.doc"))
        let allPinned = urls.allSatisfy { isPinned?($0) ?? false }
        menu.addItem(item(allPinned ? "Unpin" : "Pin to Top", allPinned ? .unpin : .pin, urls,
                          symbol: allPinned ? "pin.slash" : "pin"))
        menu.addItem(.separator())

        let sendTitle = projectName.map { "Send to “\($0)”" } ?? "Send to Project…"
        menu.addItem(item(sendTitle, .sendToProject, urls, symbol: "folder.badge.plus"))

        // Smart actions, only when they apply
        let fonts = urls.filter { FileOps.isFont($0) }
        if !fonts.isEmpty {
            menu.addItem(item(fonts.count == 1 ? "Install Font" : "Install \(fonts.count) Fonts", .installFont, fonts, symbol: "textformat"))
        }
        let luts = urls.filter { FileOps.isLUT($0) }
        if !luts.isEmpty {
            menu.addItem(item("Copy to LUT Folder", .copyToLUTFolder, luts, symbol: "camera.filters"))
        }
        let zips = urls.filter { FileOps.isZip($0) }
        if !zips.isEmpty {
            menu.addItem(item("Unzip", .unzip, zips, symbol: "doc.zipper"))
        }
        let pngable = urls.filter { FileOps.canConvert($0, toPNG: true) }
        if !pngable.isEmpty {
            menu.addItem(item("Convert to PNG", .toPNG, pngable, symbol: "photo"))
        }
        let jpgable = urls.filter { FileOps.canConvert($0, toPNG: false) }
        if !jpgable.isEmpty {
            menu.addItem(item("Convert to JPG", .toJPG, jpgable, symbol: "photo"))
        }

        if single, let host = DownloadSource.host(for: urls[0]) {
            menu.addItem(.separator())
            menu.addItem(item("Open Source Page (\(host))", .openSource, urls, symbol: "safari"))
            menu.addItem(item("Copy Source Link", .copySource, urls, symbol: "link"))
        }

        menu.addItem(.separator())
        menu.addItem(item(single ? "Remove from List" : "Remove \(urls.count) from List", .remove, urls, symbol: "xmark.circle"))
        return menu
    }

    func projectMenu() -> NSMenu {
        let menu = NSMenu()
        if let name = projectName {
            menu.addItem(header("Project: \(name)"))
        } else {
            menu.addItem(header("No project folder set"))
        }

        menu.addItem(plain("Choose Project Folder…", #selector(chooseProjectFromMenu), symbol: "folder.badge.plus"))

        let recents = recentProjects
        if !recents.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Recent Projects"))
            for path in recents {
                let entry = plain(URL(fileURLWithPath: path).lastPathComponent, #selector(selectRecentProject(_:)), symbol: "folder")
                entry.representedObject = path
                entry.toolTip = path
                entry.state = path == projectURL?.path ? .on : .off
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        if projectURL != nil {
            menu.addItem(plain("Open Project Folder", #selector(openProjectFolder), symbol: "arrow.up.forward.app"))
        }

        let sort = plain("Sort Into Type Folders", #selector(toggleSort))
        sort.state = sortsByType ? .on : .off
        sort.toolTip = "Footage, Audio, Images, Fonts, LUTs, Documents…"
        menu.addItem(sort)

        let auto = NSMenuItem(title: "Auto-Send New Downloads", action: projectURL == nil ? nil : #selector(toggleAutoSend), keyEquivalent: "")
        auto.target = self
        auto.state = autoSends ? .on : .off
        auto.toolTip = "Every new download goes straight into the project folder"
        menu.addItem(auto)

        if projectURL != nil {
            menu.addItem(.separator())
            menu.addItem(plain("Stop Using Project", #selector(clearProject), symbol: "xmark.circle"))
        }
        return menu
    }

    private func header(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func item(_ title: String, _ action: FileAction, _ urls: [URL], symbol: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = ActionPayload(action, urls)
        entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return entry
    }

    private func plain(_ title: String, _ selector: Selector, symbol: String? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        if let symbol {
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return entry
    }

    // MARK: Running actions

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ActionPayload else { return }
        perform(payload.action, on: payload.urls)
    }

    func perform(_ action: FileAction, on urls: [URL]) {
        guard !urls.isEmpty else { return }

        switch action {
        case .open:
            urls.forEach { NSWorkspace.shared.open($0) }

        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(urls)

        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map { $0.path }.joined(separator: "\n"), forType: .string)
            onSuccess?()

        case .copyFiles:
            // Paste into Finder, Slack, Mail… as real files
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
            onSuccess?()

        case .pin:
            onPin?(urls, true)

        case .unpin:
            onPin?(urls, false)

        case .sendToProject:
            guard let project = projectURL ?? chooseProjectFolder() else { return }
            run(urls) { url in
                let moved = try FileOps.move(url, into: self.destination(for: url, in: project))
                if moved.path != url.path {
                    self.onMoved?(url, moved)
                }
            }

        case .installFont:
            run(urls) { url in _ = try FileOps.installFont(url) }

        case .copyToLUTFolder:
            guard let folder = lutFolder() else { return }
            run(urls) { url in _ = try FileOps.copy(url, into: folder) }

        case .unzip:
            for url in urls {
                FileOps.unzip(url) { [weak self] ok in
                    if ok {
                        self?.onSuccess?()
                    } else {
                        self?.showError("Couldn't unzip “\(url.lastPathComponent)”.")
                    }
                }
            }

        case .toPNG, .toJPG:
            run(urls) { url in _ = try FileOps.convert(url, toPNG: action == .toPNG) }

        case .openSource:
            if let page = DownloadSource.pageURL(for: urls[0]) {
                NSWorkspace.shared.open(page)
            }

        case .copySource:
            if let page = DownloadSource.pageURL(for: urls[0]) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(page.absoluteString, forType: .string)
                onSuccess?()
            }

        case .remove:
            onRemoveFromList?(urls)
        }
    }

    /// Runs `work` for each file; one success pulse, or one alert listing what failed.
    private func run(_ urls: [URL], _ work: (URL) throws -> Void) {
        var failures: [String] = []
        for url in urls {
            do {
                try work(url)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if failures.isEmpty {
            onSuccess?()
        } else {
            showError(failures.joined(separator: "\n"))
        }
    }

    private func showError(_ message: String) {
        beforeModal?()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Floebin couldn't finish that"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: Choosing folders

    private func chooseFolder(prompt: String, message: String) -> URL? {
        beforeModal?()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    @discardableResult
    private func chooseProjectFolder() -> URL? {
        guard let url = chooseFolder(prompt: "Use as Project",
                                     message: "Downloads you send will go into this folder (sorted into Footage, Audio, Images… if that's turned on).")
        else { return nil }
        setProject(url)
        return url
    }

    private func lutFolder() -> URL? {
        if let path = UserDefaults.standard.string(forKey: Self.lutFolderKey),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let url = chooseFolder(prompt: "Use for LUTs",
                                     message: "Choose the folder your editing app loads LUTs from. Floebin will remember it.")
        else { return nil }
        UserDefaults.standard.set(url.path, forKey: Self.lutFolderKey)
        return url
    }

    @objc private func chooseProjectFromMenu() {
        chooseProjectFolder()
    }

    @objc private func selectRecentProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        setProject(URL(fileURLWithPath: path))
    }

    @objc private func openProjectFolder() {
        if let url = projectURL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleSort() {
        UserDefaults.standard.set(!sortsByType, forKey: Self.sortKey)
        onProjectChanged?()
    }

    @objc private func toggleAutoSend() {
        UserDefaults.standard.set(!autoSends, forKey: Self.autoSendKey)
        onProjectChanged?()
    }

    @objc private func clearProject() {
        setProject(nil)
        UserDefaults.standard.set(false, forKey: Self.autoSendKey)
    }
}
