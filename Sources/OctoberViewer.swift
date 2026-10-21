import Cocoa
import Photos
import WebKit

final class OctoberViewer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var window: NSWindow?
    private var highlightsWindow: NSWindow?
    private var web: WKWebView?
    private var allowed = Set<String>()
    private let folder = CatalogScan.base.appendingPathComponent("october-viewer")
    private var creating = false
    private var searching = false
    private var refreshing = false

    func show() {
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.html").path), !refreshing {
            let runs = (try? FileManager.default.contentsOfDirectory(at: CatalogScan.base.appendingPathComponent("cloud-index"), includingPropertiesForKeys: nil)) ?? []
            if let month = runs.filter({ FileManager.default.fileExists(atPath: $0.appendingPathComponent("run.sqlite").path) }).map({ $0.lastPathComponent }).sorted().last {
                refreshing = true
                DispatchQueue.global(qos: .userInitiated).async {
                    var built = false
                    do {
                        let p = Process(); p.executableURL = CatalogScan.base.appendingPathComponent("benchmark-venv/bin/python")
                        p.arguments = [Bundle.main.url(forResource: "build_october_viewer", withExtension: "py")!.path, "--month", month]
                        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                        try p.run(); p.waitUntilExit(); built = p.terminationStatus == 0
                    } catch { }
                    let success = built
                    DispatchQueue.main.async {
                        self.refreshing = false
                        if success { self.show() } else { let alert = NSAlert(); alert.messageText = "Snapshot needs attention"; alert.informativeText = "Check the Python runtime and indexed results, then reopen Photo Signal."; alert.runModal() }
                    }
                }
                return
            }
        }
        if let window { window.makeKeyAndOrderFront(nil); return }
        do {
            let bytes = try Data(contentsOf: folder.appendingPathComponent("allowed-assets.json"))
            allowed = Set(try JSONDecoder().decode([String].self, from: bytes))
            let config = WKWebViewConfiguration()
            config.userContentController.add(self, name: "photoSignal")
            let view = WKWebView(frame: .zero, configuration: config)
            view.navigationDelegate = self
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Photo Signal — Library"; w.isReleasedWhenClosed = false; w.minSize = NSSize(width: 720, height: 580)
            w.contentView = view; web = view; window = w
            view.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder)
            w.center(); w.makeKeyAndOrderFront(nil)
        } catch {
            let alert = NSAlert(); alert.messageText = "Your library is getting ready"
            alert.informativeText = "Open Photo Signal Indexer and index your first month. Then reopen Browse indexed photos to build its local snapshot. \(error.localizedDescription)"
            alert.runModal()
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let expected = folder.appendingPathComponent("index.html").standardizedFileURL.path
        decisionHandler(action.request.url?.isFileURL == true && action.request.url?.standardizedFileURL.path == expected ? .allow : .cancel)
    }
    private func reply(_ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result), let text = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.nativeAlbumResult(\(text));", completionHandler: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.frameInfo.isMainFrame, message.webView === web,
           message.webView?.url?.standardizedFileURL.path == folder.appendingPathComponent("index.html").standardizedFileURL.path,
           let body = message.body as? [String: Any], body["action"] as? String == "refreshViewer",
           let month = body["month"] as? String, month.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil,
           !searching, !creating, !refreshing {
            refreshing = true
            DispatchQueue.global(qos: .userInitiated).async {
                var success = false
                do {
                    let p = Process()
                    p.executableURL = CatalogScan.base.appendingPathComponent("benchmark-venv/bin/python")
                    p.arguments = [Bundle.main.url(forResource: "build_october_viewer", withExtension: "py")!.path, "--month", month]
                    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                    try p.run(); p.waitUntilExit(); success = p.terminationStatus == 0
                } catch { }
                let completed = success
                DispatchQueue.main.async {
                    self.refreshing = false
                    if completed, let data = try? Data(contentsOf: self.folder.appendingPathComponent("allowed-assets.json")), let ids = try? JSONDecoder().decode([String].self, from: data) {
                        self.allowed = Set(ids); self.web?.reload()
                    } else { self.web?.evaluateJavaScript("window.nativeRefreshResult({error:'Could not rebuild this month. Check the local Python runtime and indexed results.'});", completionHandler: nil) }
                }
            }
            return
        }
        if message.frameInfo.isMainFrame, message.webView === web,
           message.webView?.url?.standardizedFileURL.path == folder.appendingPathComponent("index.html").standardizedFileURL.path,
           let body = message.body as? [String: Any], body["action"] as? String == "openTop25" {
            if let highlightsWindow { highlightsWindow.makeKeyAndOrderFront(nil); return }
            let target = CatalogScan.base.appendingPathComponent("top25-2026/index.html")
            guard FileManager.default.fileExists(atPath: target.path) else { return }
            let view = WKWebView(frame: .zero)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Photo Signal — Top 25 of 2026"; w.isReleasedWhenClosed = false
            w.contentView = view; highlightsWindow = w
            view.loadFileURL(target, allowingReadAccessTo: target.deletingLastPathComponent())
            w.center(); w.makeKeyAndOrderFront(nil); return
        }
        if message.frameInfo.isMainFrame, message.webView === web,
           message.webView?.url?.standardizedFileURL.path == folder.appendingPathComponent("index.html").standardizedFileURL.path,
           let body = message.body as? [String: Any], ["search", "dreamAlbum"].contains(body["action"] as? String ?? ""),
           let query = body["query"] as? String, !query.isEmpty, query.count <= 1000, !searching, !refreshing {
            searching = true
            let mode = body["action"] as? String == "dreamAlbum" ? "album" : "search"
            DispatchQueue.global(qos: .userInitiated).async {
                var response: [String: Any] = ["ok": false, "query": query, "error": "Search interpreter unavailable."]
                do {
                    let process = Process(), input = Pipe(), output = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = [Bundle.main.url(forResource: "interpret_search", withExtension: "py")!.path]
                    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                    try process.run()
                    input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: ["query": query, "mode": mode]))
                    try input.fileHandleForWriting.close()
                    let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                    response = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? response
                    response["query"] = query
                    response["mode"] = mode
                } catch { }
                let result = response
                DispatchQueue.main.async {
                    self.searching = false
                    if let data = try? JSONSerialization.data(withJSONObject: result), let text = String(data: data, encoding: .utf8) {
                        self.web?.evaluateJavaScript("window.nativeSearchResult(\(text));", completionHandler: nil)
                    }
                }
            }
            return
        }
        if message.frameInfo.isMainFrame, message.webView === web,
           message.webView?.url?.standardizedFileURL.path == folder.appendingPathComponent("index.html").standardizedFileURL.path,
           let body = message.body as? [String: Any], body["action"] as? String == "curatePhotos",
           let query = body["query"] as? String, !query.isEmpty, query.count <= 1000,
           let ids = body["ids"] as? [String], !ids.isEmpty, ids.count <= 60,
           Set(ids).count == ids.count, Set(ids).isSubset(of: allowed),
           let limit = body["limit"] as? Int, (1...25).contains(limit), !searching, !refreshing {
            searching = true
            DispatchQueue.global(qos: .userInitiated).async {
                var response: [String: Any] = ["ok": false, "mode": "curation", "error": "Visual review unavailable. Your selection is unchanged."]
                do {
                    let process = Process(), input = Pipe(), output = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = [Bundle.main.url(forResource: "curate_photos", withExtension: "py")!.path]
                    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                    try process.run()
                    input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: ["query": query, "ids": ids, "limit": limit]))
                    try input.fileHandleForWriting.close()
                    let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                    response = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? response
                } catch { }
                let result = response
                DispatchQueue.main.async {
                    self.searching = false
                    if let data = try? JSONSerialization.data(withJSONObject: result), let text = String(data: data, encoding: .utf8) {
                        self.web?.evaluateJavaScript("window.nativeCurationResult(\(text));", completionHandler: nil)
                    }
                }
            }
            return
        }
        guard message.frameInfo.isMainFrame, message.webView === web,
              message.webView?.url?.standardizedFileURL.path == folder.appendingPathComponent("index.html").standardizedFileURL.path,
              let body = message.body as? [String: Any], body["action"] as? String == "createAlbum",
              let name = body["name"] as? String, let ids = body["ids"] as? [String],
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              !ids.isEmpty, ids.count <= allowed.count, Set(ids).count == ids.count, Set(ids).isSubset(of: allowed), !creating, !refreshing else {
            reply(["ok": false, "error": "Invalid album selection."]); return
        }
        creating = true
        DispatchQueue.global(qos: .utility).async {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { auth in
                guard auth == .authorized || auth == .limited else {
                    DispatchQueue.main.async { self.creating = false; self.reply(["ok": false, "error": "Photos access is required to create this album."]) }; return
                }
                let options = PHFetchOptions(); options.includeHiddenAssets = false
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
                guard assets.count == ids.count else {
                    DispatchQueue.main.async { self.creating = false; self.reply(["ok": false, "error": "Some selected photos are no longer accessible."]) }; return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name).addAssets(assets)
                }) { success, error in
                    DispatchQueue.main.async {
                        self.creating = false
                        self.reply(success ? ["ok": true, "name": name, "count": ids.count] : ["ok": false, "error": error?.localizedDescription ?? "Could not create album."])
                    }
                }
            }
        }
    }
}
