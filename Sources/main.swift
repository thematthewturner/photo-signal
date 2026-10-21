import Cocoa
import Photos

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let viewer = MetadataViewer()
    let searchWindow = SearchWindow()
    let cloudWindow = CloudIndexWindow()
    let octoberViewer = OctoberViewer()
    private var indexing = false
    let status = NSTextField(wrappingLabelWithString: "Create a private inventory of photos and videos visible to PhotoKit. No images are downloaded or changed. Shared-library coverage will need comparison with Photos.")
    let button = NSButton(title: "Allow Photos Access & Inventory", target: nil, action: nil)
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), appMenu = NSMenu(), root = NSMenuItem()
        appMenu.addItem(withTitle: "Open Indexer", action: #selector(showIndexer), keyEquivalent: "i").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Photo Signal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu; menu.addItem(root); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 594), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Photo Signal"
        status.frame = NSRect(x: 24, y: 379, width: 602, height: 175)
        status.stringValue = "Your photos, easier to find. Browse indexed months, inspect what AI collected, and turn a prompt into an album proposal. Photo Signal Indexer handles background work separately. Start there if this is your first run."
        window.contentView?.addSubview(status)
        let controls: [(String, Selector)] = [
            ("Browse indexed photos", #selector(showOctober)),
            ("Open Photo Signal Indexer", #selector(showIndexer)),
            ("Search the full catalog", #selector(showSearch)),
            ("Library profile", #selector(showProfile))
        ]
        for (n, control) in controls.enumerated() {
            let item = NSButton(title: control.0, target: self, action: control.1)
            item.frame = NSRect(x: 24, y: 339 - n * 42, width: 390, height: 34)
            window.contentView?.addSubview(item)
        }
        searchWindow.openAsset = { row in self.viewer.showCatalogResult(row) }
        window.center(); window.makeKeyAndOrderFront(nil)
        if CommandLine.arguments.contains("--october-viewer") { showOctober() }
        else if CommandLine.arguments.contains("--download-missing") { startCloud(downloads: true) }
        else if CommandLine.arguments.contains("--cloud-index") { startCloud() }
        else if CommandLine.arguments.contains("--cloud-monitor") { showCloud() }
        else if CommandLine.arguments.contains("--export-sandbox") { exportSandbox() }
        else if CommandLine.arguments.contains("--benchmark") { benchmark() }
        else if CommandLine.arguments.contains("--index") { indexLibrary() }
        else if CommandLine.arguments.contains("--search") { showSearch() }
        else if CommandLine.arguments.contains("--profile") { showProfile() }
        else if FileManager.default.fileExists(atPath: CatalogScan.base.appendingPathComponent("october-viewer/index.html").path) { showOctober() }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showIndexer() {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Photo Signal Indexer.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
    @objc func showCloud() { cloudWindow.show() }
    @objc func showOctober() { octoberViewer.show() }
    func startCloud(downloads: Bool = false) {
        cloudWindow.show()
        DispatchQueue.global(qos: .utility).async {
            self.authorizePhotos { authorization in
                DispatchQueue.main.async {
                    if authorization == .authorized || authorization == .limited {
                        if downloads { self.cloudWindow.downloadMissing() }
                        else { self.cloudWindow.show(start: true) }
                    }
                    else { self.status.stringValue = "Photos access is required for October export." }
                }
            }
        }
    }
    private func authorizePhotos(_ completion: @escaping (PHAuthorizationStatus) -> Void) {
        let existing = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if existing == .authorized || existing == .limited { completion(existing) }
        else { PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: completion) }
    }
    func exportSandbox() {
        status.stringValue = "Preparing local sandbox export…"
        authorizePhotos { authorization in
            guard authorization == .authorized || authorization == .limited else {
                DispatchQueue.main.async { self.status.stringValue = "Photos access required for sandbox export." }; return
            }
            DispatchQueue.global(qos: .utility).async {
                SandboxExport.run { message in DispatchQueue.main.async { self.status.stringValue = message } }
            }
        }
    }
    @objc func showProfile() {
        status.stringValue = "Building a read-only library profile… This usually takes 15–30 seconds."
        DispatchQueue.global(qos: .utility).async {
            do {
                guard let script = Bundle.main.url(forResource: "profile_catalog", withExtension: "py"), let template = Bundle.main.url(forResource: "profile", withExtension: "html") else { throw NSError(domain: "PhotoSignal.Profile", code: 1) }
                let task = Process(), output = Pipe()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                task.arguments = [script.path, "--template", template.path]
                task.standardOutput = output; task.standardError = FileHandle.nullDevice
                try task.run()
                let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
                guard task.terminationStatus == 0, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], let path = result["output"] as? String else { throw NSError(domain: "PhotoSignal.Profile", code: 2, userInfo: [NSLocalizedDescriptionKey: "Profile generation failed"]) }
                DispatchQueue.main.async {
                    self.status.stringValue = "Library profile ready: \(result["assets"] ?? 0) assets, \(result["fields"] ?? 0) metadata fields. Snapshot generated locally."
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            } catch { DispatchQueue.main.async { self.status.stringValue = "Profile failed: \(error.localizedDescription)" } }
        }
    }
    @objc func showSearch() { searchWindow.show() }
    @objc func pauseIndex() {
        let url = CatalogScan.base.appendingPathComponent("pause-indexing")
        try? Data().write(to: url)
        status.stringValue = "Pause requested. The current photo will finish and saved results remain searchable."
    }
    @objc func indexLibrary() {
        guard !indexing else { status.stringValue = "Indexing is already running. Search can be used while it continues."; return }
        indexing = true
        status.stringValue = CommandLine.arguments.contains("--resume") ? "Resuming saved index; reading checkpoints… No image downloads." : "Refreshing public metadata across the library… No image downloads."
        authorizePhotos { authorization in
            guard authorization == .authorized || authorization == .limited else {
                DispatchQueue.main.async { self.indexing = false; self.status.stringValue = "Photos access is required for indexing." }; return
            }
            DispatchQueue.main.async { self.searchWindow.show() }
            let jobs = DispatchGroup()
            jobs.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { jobs.leave() }
                if CommandLine.arguments.contains("--resume"), FileManager.default.fileExists(atPath: CatalogScan.base.appendingPathComponent("inventory.jsonl").path) {
                    _ = try? CatalogBackend.call(["sync"])
                    return
                }
                guard self.inventory() else { return }
                do { _ = try CatalogBackend.call(["sync"]) }
                catch { DispatchQueue.main.async { self.status.stringValue = "Metadata import failed: \(error.localizedDescription)" }; return }
                self.scanAlbums()
            }
            jobs.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { jobs.leave() }
                CatalogScan.run { message in DispatchQueue.main.async { self.status.stringValue = message } }
            }
            jobs.notify(queue: .main) { self.indexing = false }
        }
    }
    @objc func showViewer() { viewer.show() }
    func benchmark() {
        button.isEnabled = false
        authorizePhotos { authorization in
            guard authorization == .authorized || authorization == .limited else {
                DispatchQueue.main.async { self.status.stringValue = "Photos access required for benchmark." }; return
            }
            DispatchQueue.global(qos: .utility).async {
                Benchmark.run(recent: CommandLine.arguments.contains("--recent"), randomFaces: CommandLine.arguments.contains("--faces")) { message in DispatchQueue.main.async { self.status.stringValue = message } }
                DispatchQueue.main.async { self.button.isEnabled = true; self.viewer.reload() }
            }
        }
    }
    @objc func start() {
        button.isEnabled = false
        authorizePhotos { authorization in
            guard authorization == .authorized || authorization == .limited else {
                DispatchQueue.main.async { self.status.stringValue = "Photos access was not granted. You can enable it in System Settings → Privacy & Security → Photos."; self.button.isEnabled = true }
                return
            }
            DispatchQueue.global(qos: .utility).async {
                if self.inventory() { _ = try? CatalogBackend.call(["sync"]) }
            }
        }
    }
    @discardableResult func inventory() -> Bool {
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoSignal", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let destination = base.appendingPathComponent("inventory.jsonl")
            let temporary = base.appendingPathComponent(UUID().uuidString + ".tmp")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw NSError(domain: "PhotoSignal", code: 1) }
            let file = try FileHandle(forWritingTo: temporary)
            defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
            let options = PHFetchOptions()
            options.includeHiddenAssets = false
            let assets = PHAsset.fetchAssets(with: options)
            var photos = 0, videos = 0
            for index in 0..<assets.count {
                try autoreleasepool {
                let asset = assets.object(at: index)
                if asset.mediaType == .image { photos += 1 }
                if asset.mediaType == .video { videos += 1 }
                var row: [String: Any] = ["asset_id": asset.localIdentifier, "media_type": asset.mediaType.rawValue, "width": asset.pixelWidth, "height": asset.pixelHeight, "duration": asset.duration, "favorite": asset.isFavorite, "media_subtypes": asset.mediaSubtypes.rawValue, "source_type": asset.sourceType.rawValue]
                if let date = asset.creationDate { row["created_at"] = ISO8601DateFormatter().string(from: date) }
                if let date = asset.modificationDate { row["modified_at"] = ISO8601DateFormatter().string(from: date) }
                row["albums"] = []
                row["resources"] = PHAssetResource.assetResources(for: asset).map { ["filename": $0.originalFilename, "uti": $0.uniformTypeIdentifier, "resource_type": $0.type.rawValue] as [String: Any] }
                row["burst_id"] = asset.burstIdentifier
                row["represents_burst"] = asset.representsBurst
                row["burst_selection_types"] = asset.burstSelectionTypes.rawValue
                row["playback_style"] = asset.playbackStyle.rawValue
                if let location = asset.location {
                    row["location"] = ["latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude, "altitude": location.altitude, "horizontal_accuracy": location.horizontalAccuracy, "vertical_accuracy": location.verticalAccuracy]
                }
                // Public PhotoKit metadata only. No private Photos database reads or credentials.
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                data.append(0x0a); try file.write(contentsOf: data)
                if index % 1000 == 0 {
                    let count = index
                    DispatchQueue.main.async { self.status.stringValue = "Indexed \(count) of \(assets.count) assets… No image downloads." }
                }
                }
            }
            try file.synchronize(); try file.close()
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: destination) }
            let message = "Inventory complete: \(photos) photos, \(videos) videos.\n\nSaved privately in Application Support/PhotoSignal. Hidden and recently deleted items are excluded. Compare these counts with Photos to validate coverage."
            DispatchQueue.main.async { self.status.stringValue = message; self.button.isEnabled = true }
            return true
        } catch {
            DispatchQueue.main.async { self.status.stringValue = "Inventory failed: \(error.localizedDescription)"; self.button.isEnabled = true }
            return false
        }
    }
    func scanAlbums() {
        // User albums only; broad system Smart Albums duplicate the whole library and are costly.
        var memberships = [String: [[String: String]]]()
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        let options = PHFetchOptions(); options.includeHiddenAssets = false
        for index in 0..<collections.count {
            let collection = collections.object(at: index)
            // This earlier experimental Smart Album has invalid/glitching criteria.
            if collection.localizedTitle == "Photo Signal — All Four (existing labels)" { continue }
            let members = PHAsset.fetchAssets(in: collection, options: options)
            for n in 0..<members.count {
                autoreleasepool {
                    let asset = members.object(at: n)
                    memberships[asset.localIdentifier, default: []].append(["id": collection.localIdentifier, "title": collection.localizedTitle ?? "Untitled"])
                }
            }
            if index + 1 == collections.count {
                do {
                    let data = try JSONSerialization.data(withJSONObject: memberships)
                    let url = CatalogScan.base.appendingPathComponent("album-membership.json")
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    _ = try CatalogBackend.call(["sync"])
                } catch { return }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

}
signal(SIGPIPE, SIG_IGN)
umask(0o077)
if CommandLine.arguments.contains("--ocr-worker") {
    OCRWorker.serve()
    exit(0)
}
if CommandLine.arguments.contains("--ocr-self-test") {
    let result = OCRWorkerClient().testRecovery()
    if let data = try? JSONSerialization.data(withJSONObject: result), let text = String(data: data, encoding: .utf8) { print(text) }
    exit((result["passed"] as? Bool) == true ? 0 : 1)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
