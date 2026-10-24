import Cocoa
import Photos

final class CatalogBackend {
    static func call(_ arguments: [String]) throws -> [String: Any] {
        guard let script = Bundle.main.url(forResource: "catalog", withExtension: "py") else { throw NSError(domain: "PhotoSignal", code: 2, userInfo: [NSLocalizedDescriptionKey: "Catalog backend missing"]) }
        let task = Process(), output = Pipe(), errors = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [script.path] + arguments; task.standardOutput = output; task.standardError = errors
        try task.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw NSError(domain: "PhotoSignal", code: 3) }
        if let error = result["error"] as? String { throw NSError(domain: "PhotoSignal", code: 4, userInfo: [NSLocalizedDescriptionKey: error]) }
        return result
    }
}

final class SearchWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private let query = NSSearchField()
    private let localAI = NSButton(checkboxWithTitle: "Interpret with local LLM", target: nil, action: nil)
    private let searchButton = NSButton(title: "Search", target: nil, action: nil)
    private let albumButton = NSButton(title: "Create Photos Album from Results", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save Collection", target: nil, action: nil)
    private let name = NSTextField(string: "Photo Signal Selection")
    private let status = NSTextField(wrappingLabelWithString: "Search the local catalog. People queries use only user-confirmed tags.")
    private let planView = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private var rows = [[String: Any]]()
    private var plan = [String: Any]()
    private var total = 0
    var openAsset: (([String: Any]) -> Void)?
    func show() {
        if window != nil { window.makeKeyAndOrderFront(nil); return }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "Photo Signal — Search Catalog"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 850, height: 600)
        let content = window.contentView!
        query.placeholderString = "e.g. Riley and Jordan · or beach · or {\"min_faces\":4}"
        query.target = self; query.action = #selector(search)
        searchButton.target = self; searchButton.action = #selector(search)
        saveButton.target = self; saveButton.action = #selector(saveCollection)
        albumButton.target = self; albumButton.action = #selector(createAlbum)
        localAI.state = .on
        let heading = NSTextField(labelWithString: "Your library, searchable locally")
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        status.textColor = .secondaryLabelColor; planView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        planView.maximumNumberOfLines = 4
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        for (id,title,width) in [("created_at","Captured",190.0),("people","People labels",180.0),("face_count","Faces",65.0),("camera_model","Camera",150.0),("asset_id","Photo identifier",320.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.usesAlternatingRowBackgroundColors = true
        let note = NSTextField(wrappingLabelWithString: "Double-click a result to inspect it. LLM interpretation can be wrong: inspect the filter below. Albums contain the displayed result set (maximum 200 by default); originals are not copied.")
        note.textColor = .secondaryLabelColor
        for view in [heading,query,localAI,searchButton,status,planView,scroll,name,saveButton,albumButton,note] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            query.leadingAnchor.constraint(equalTo: heading.leadingAnchor), query.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18), query.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor, constant: -12),
            searchButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), searchButton.centerYAnchor.constraint(equalTo: query.centerYAnchor), searchButton.widthAnchor.constraint(equalToConstant: 100),
            localAI.leadingAnchor.constraint(equalTo: query.leadingAnchor), localAI.topAnchor.constraint(equalTo: query.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: query.leadingAnchor), status.trailingAnchor.constraint(equalTo: searchButton.trailingAnchor), status.topAnchor.constraint(equalTo: localAI.bottomAnchor, constant: 10), status.heightAnchor.constraint(equalToConstant: 38),
            planView.leadingAnchor.constraint(equalTo: query.leadingAnchor), planView.trailingAnchor.constraint(equalTo: searchButton.trailingAnchor), planView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6), planView.heightAnchor.constraint(equalToConstant: 58),
            scroll.leadingAnchor.constraint(equalTo: query.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: searchButton.trailingAnchor), scroll.topAnchor.constraint(equalTo: planView.bottomAnchor, constant: 10), scroll.bottomAnchor.constraint(equalTo: name.topAnchor, constant: -16),
            name.leadingAnchor.constraint(equalTo: query.leadingAnchor), name.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -10), name.widthAnchor.constraint(equalToConstant: 240),
            saveButton.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 12), saveButton.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            albumButton.trailingAnchor.constraint(equalTo: searchButton.trailingAnchor), albumButton.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            note.leadingAnchor.constraint(equalTo: query.leadingAnchor), note.trailingAnchor.constraint(equalTo: searchButton.trailingAnchor), note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18), note.heightAnchor.constraint(equalToConstant: 42)
        ])
        saveButton.isEnabled = false; albumButton.isEnabled = false
        window.center(); window.makeKeyAndOrderFront(nil)
        DispatchQueue.global(qos: .utility).async {
            do { let stats = try CatalogBackend.call(["stats"]); DispatchQueue.main.async { self.status.stringValue = "Catalog: \(stats["assets"] ?? 0) assets · \(stats["enriched"] ?? 0) enriched · \(stats["vectors"] ?? 0) saved visual vectors. Unanalyzed content will not match image-label/OCR searches." } }
            catch { DispatchQueue.main.async { self.status.stringValue = error.localizedDescription } }
        }
    }
    @objc private func search() {
        let text = query.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let useAI = localAI.state == .on && !text.hasPrefix("{") && !text.isEmpty
        searchButton.isEnabled = false; saveButton.isEnabled = false; albumButton.isEnabled = false
        status.stringValue = useAI ? "Interpreting locally, then querying SQLite…" : "Searching local SQLite catalog…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let arguments: [String]
                if useAI { arguments = ["ask",text] }
                else {
                    let json = text.hasPrefix("{") ? text : String(data: try JSONSerialization.data(withJSONObject: text.isEmpty ? [:] : ["text":text]), encoding: .utf8)!
                    arguments = ["search","--plan",json]
                }
                let response = try CatalogBackend.call(arguments)
                DispatchQueue.main.async {
                    self.rows = response["results"] as? [[String: Any]] ?? []
                    self.plan = response["plan"] as? [String: Any] ?? [:]
                    self.total = response["total_matches"] as? Int ?? 0
                    self.table.reloadData(); self.searchButton.isEnabled = true
                    self.saveButton.isEnabled = !self.rows.isEmpty; self.albumButton.isEnabled = !self.rows.isEmpty
                    self.planView.stringValue = "Executed filter: " + (String(data: (try? JSONSerialization.data(withJSONObject: self.plan, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "")
                    self.status.stringValue = "\(self.total) matches · showing \(self.rows.count) · database \(response["query_ms"] ?? "?") ms" + (response["planner_seconds"].map { " · local interpretation + query \($0) seconds" } ?? "")
                }
            } catch { DispatchQueue.main.async { self.searchButton.isEnabled = true; self.status.stringValue = "Search failed: \(error.localizedDescription). Turn off local LLM for keyword search or enter JSON filters." } }
        }
    }
    @objc private func openSelected() {
        let n = table.clickedRow
        if n >= 0, n < rows.count { openAsset?(rows[n]) }
    }
    @objc private func saveCollection() {
        let title = name.stringValue, currentPlan = plan
        let snapshot = rows.compactMap { $0["asset_id"] as? String }
        saveButton.isEnabled = false
        DispatchQueue.global(qos: .utility).async {
            do {
                let json = String(data: try JSONSerialization.data(withJSONObject: currentPlan), encoding: .utf8)!
                let ids = String(data: try JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8)!
                let result = try CatalogBackend.call(["save","--name",title,"--plan",json,"--ids-json",ids])
                DispatchQueue.main.async { self.saveButton.isEnabled = true; self.status.stringValue = "Saved local collection #\(result["collection_id"] ?? "?"): \(result["saved_count"] ?? 0) items." }
            } catch { DispatchQueue.main.async { self.saveButton.isEnabled = true; self.status.stringValue = error.localizedDescription } }
        }
    }
    @objc private func createAlbum() {
        let ids = rows.compactMap { $0["asset_id"] as? String }, title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !ids.isEmpty else { status.stringValue = "Enter an album name and search first."; return }
        let alert = NSAlert()
        alert.messageText = "Create album ‘\(title)’ with \(ids.count) results?"
        alert.informativeText = "These are the displayed results out of \(total) matches. This creates a normal album in Photos and adds references to the photos. It does not move or duplicate originals."
        alert.addButton(withTitle: "Create Album"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            guard assets.count == ids.count else { self.status.stringValue = "Some results are no longer accessible. Refresh the search before creating an album."; return }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                request.addAssets(assets)
            }) { success,error in DispatchQueue.main.async { self.status.stringValue = success ? "Created Photos album: \(title) · \(ids.count) items." : "Album creation failed: \(error?.localizedDescription ?? "Unknown error")" } }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let key = tableColumn?.identifier.rawValue ?? ""
        let field = NSTextField(labelWithString: rows[row][key].flatMap { $0 is NSNull ? nil : String(describing: $0) } ?? "—")
        field.lineBreakMode = .byTruncatingMiddle; return field
    }
}
