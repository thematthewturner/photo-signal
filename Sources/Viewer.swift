import Cocoa
import Photos

final class MetadataViewer: NSObject {
    private var window: NSWindow!
    private var catalogResult: [String: Any]?
    private let image = NSImageView()
    private let details = NSTextView()
    private let position = NSTextField(labelWithString: "")
    private let previewStatus = NSTextField(wrappingLabelWithString: "")
    private let previous = NSButton(title: "← Previous", target: nil, action: nil)
    private let access = NSButton(title: "Enable Local Previews", target: nil, action: nil)
    private let next = NSButton(title: "Next →", target: nil, action: nil)
    private var rows = [[String: Any]]()
    private var inventory = [String: [String: Any]]()
    private var edges = [[String: Any]]()
    private var index = 0
    private var allRows = [[String: Any]]()
    private let candidates = NSButton(checkboxWithTitle: "4+ faces only", target: nil, action: nil)
    private let bothOnly = NSButton(checkboxWithTitle: "Confirmed Riley + Jordan", target: nil, action: nil)
    private let confirmBoth = NSButton(title: "Confirm Riley + Jordan in this photo", target: nil, action: nil)
    private var annotations = [String: [String: Any]]()
    private var annotationsURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoSignal/people-tags.json") }
    private var generation = 0
    private var requestID: PHImageRequestID?
    private let manager = PHImageManager.default()

    func showCatalogResult(_ result: [String: Any]) {
        let metadata = (result["metadata_json"] as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var row = (result["analysis_json"] as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        row["asset_id"] = result["asset_id"]; row["metadata"] = metadata
        row["semantic_classification"] = (result["semantic_json"] as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        row["catalog_people"] = result["people"]
        row["people_sources"] = result["people_sources"]
        catalogResult = row
        if window == nil { show() }
        else { rows = [row]; allRows = [row]; index = 0; candidates.state = .off; bothOnly.state = .off; render(); window.makeKeyAndOrderFront(nil) }
    }
    func reload() {
        catalogResult = nil
        generation += 1
        if let requestID { manager.cancelImageRequest(requestID) }
        window?.close(); window = nil; index = 0; rows = []; inventory = [:]; edges = []
        show()
    }
    func show() {
        if window != nil { window.makeKeyAndOrderFront(nil); return }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Photo Signal — Metadata Viewer"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 620)
        let content = window.contentView!
        let heading = NSTextField(labelWithString: "Inside the local scan")
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Browse the saved benchmark one photo at a time. Previews stay on your Mac; iCloud downloads are disabled.")
        subtitle.textColor = .secondaryLabelColor
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true; image.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        previewStatus.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        details.isEditable = false; details.isSelectable = true
        details.font = .systemFont(ofSize: 13)
        details.textContainerInset = NSSize(width: 14, height: 14)
        details.isVerticallyResizable = true; details.isHorizontallyResizable = false
        details.autoresizingMask = [.width]
        details.textContainer?.widthTracksTextView = true
        scroll.documentView = details
        previous.target = self; previous.action = #selector(back)
        next.target = self; next.action = #selector(forward)
        previous.keyEquivalent = "\u{f702}"; next.keyEquivalent = "\u{f703}"
        bothOnly.target = self; bothOnly.action = #selector(filterCandidates)
        confirmBoth.target = self; confirmBoth.action = #selector(toggleConfirmedPair)
        candidates.target = self; candidates.action = #selector(filterCandidates)
        access.target = self; access.action = #selector(enablePreviews)
        position.alignment = .center
        for view in [heading, subtitle, image, previewStatus, scroll, previous, next, position, access, candidates, bothOnly, confirmBoth] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bothOnly.leadingAnchor.constraint(equalTo: heading.leadingAnchor), bothOnly.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            confirmBoth.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), confirmBoth.centerYAnchor.constraint(equalTo: bothOnly.centerYAnchor),
            candidates.trailingAnchor.constraint(equalTo: access.leadingAnchor, constant: -16), candidates.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            access.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), access.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor), subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8), subtitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            image.leadingAnchor.constraint(equalTo: heading.leadingAnchor), image.topAnchor.constraint(equalTo: bothOnly.bottomAnchor, constant: 14), image.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.43), image.bottomAnchor.constraint(equalTo: previewStatus.topAnchor, constant: -10),
            previewStatus.leadingAnchor.constraint(equalTo: image.leadingAnchor), previewStatus.widthAnchor.constraint(equalTo: image.widthAnchor), previewStatus.bottomAnchor.constraint(equalTo: previous.topAnchor, constant: -18), previewStatus.heightAnchor.constraint(equalToConstant: 42),
            scroll.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 20), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), scroll.topAnchor.constraint(equalTo: image.topAnchor), scroll.bottomAnchor.constraint(equalTo: previewStatus.bottomAnchor),
            previous.leadingAnchor.constraint(equalTo: image.leadingAnchor), previous.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20), previous.widthAnchor.constraint(equalToConstant: 130),
            next.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), next.centerYAnchor.constraint(equalTo: previous.centerYAnchor), next.widthAnchor.constraint(equalToConstant: 130),
            position.centerXAnchor.constraint(equalTo: content.centerXAnchor), position.centerYAnchor.constraint(equalTo: previous.centerYAnchor)
        ])
        window.center(); window.makeKeyAndOrderFront(nil)
        details.string = "Loading saved benchmark and inventory…"
        previous.isEnabled = false; next.isEnabled = false
        DispatchQueue.global(qos: .utility).async {
            do {
                let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoSignal")
                let data = try Data(contentsOf: base.appendingPathComponent("benchmark.json"))
                guard let report = try JSONSerialization.jsonObject(with: data) as? [String: Any], let loaded = report["rows"] as? [[String: Any]], !loaded.isEmpty else { throw NSError(domain: "PhotoSignal", code: 1, userInfo: [NSLocalizedDescriptionKey: "No benchmark results yet. Run the benchmark first."]) }
                let ids = Set(loaded.compactMap { $0["asset_id"] as? String })
                var metadata = [String: [String: Any]]()
                if let source = try? String(contentsOf: base.appendingPathComponent("inventory.jsonl"), encoding: .utf8) {
                    source.enumerateLines { line, _ in
                        if let bytes = line.data(using: .utf8), let row = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], let id = row["asset_id"] as? String, ids.contains(id) { metadata[id] = row }
                    }
                }
                let collected = metadata
                DispatchQueue.main.async {
                    self.rows = loaded; self.allRows = loaded; self.inventory = collected; self.edges = report["neighbor_distances"] as? [[String: Any]] ?? []
                    do {
                        if FileManager.default.fileExists(atPath: self.annotationsURL.path) {
                            self.annotations = try JSONSerialization.jsonObject(with: Data(contentsOf: self.annotationsURL)) as? [String: [String: Any]] ?? [:]
                        }
                    } catch { self.details.string = "Unable to load person tags: \(error.localizedDescription)"; return }
                    if let requested = CommandLine.arguments.firstIndex(of: "--asset"), requested + 1 < CommandLine.arguments.count,
                       let found = loaded.firstIndex(where: { ($0["asset_id"] as? String) == CommandLine.arguments[requested + 1] }) { self.index = found }
                    if let selected = self.catalogResult { self.rows = [selected]; self.allRows = [selected]; self.index = 0 }
                    self.render()
                }
            } catch { DispatchQueue.main.async { self.details.string = "Unable to load results: \(error.localizedDescription)" } }
        }
    }
    private func hasBoth(_ row: [String: Any]) -> Bool {
        let names = Set(annotations[row["asset_id"] as? String ?? ""]?["people"] as? [String] ?? [])
        return names.isSuperset(of: ["Riley", "Jordan"])
    }
    @objc private func filterCandidates() {
        let filtered = allRows.filter { row in
            (candidates.state != .on || (row["face_count"] as? Int ?? 0) >= 4) && (bothOnly.state != .on || hasBoth(row))
        }
        guard !filtered.isEmpty else {
            candidates.state = .off; bothOnly.state = .off
            rows = allRows; index = 0; render()
            previewStatus.stringValue = "No matches for those filters in the loaded sample. Showing all results."
            return
        }
        rows = filtered; index = 0; render()
    }
    @objc private func toggleConfirmedPair() {
        guard !rows.isEmpty, let id = rows[index]["asset_id"] as? String else { return }
        var updated = annotations
        if hasBoth(rows[index]) { updated.removeValue(forKey: id) }
        else { updated[id] = ["people": ["Riley", "Jordan"], "source": "user_confirmed", "confirmed_at": ISO8601DateFormatter().string(from: Date())] }
        do {
            let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: annotationsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: annotationsURL.path)
            annotations = updated
            if bothOnly.state == .on { filterCandidates() } else { render() }
        } catch { previewStatus.stringValue = "Tags were not saved: \(error.localizedDescription)" }
    }
    @objc private func enablePreviews() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
            DispatchQueue.main.async { if !self.rows.isEmpty { self.render() } }
        }
    }
    @objc private func back() { if index > 0 { index -= 1; render() } }
    @objc private func forward() { if index + 1 < rows.count { index += 1; render() } }
    private func render() {
        generation += 1
        let token = generation
        if let requestID { manager.cancelImageRequest(requestID) }
        image.image = nil
        let row = rows[index], id = row["asset_id"] as? String ?? ""
        let meta = row["metadata"] as? [String: Any] ?? inventory[id] ?? [:]
        let camera = row["camera_metadata"] as? [String: Any] ?? [:]
        let cameraText = camera.keys.sorted().map { "\($0): \(camera[$0]!)" }.joined(separator: "\n")
        position.stringValue = "Photo \(index + 1) of \(rows.count)"
        previous.isEnabled = index > 0; next.isEnabled = index + 1 < rows.count
        func value(_ key: String) -> String { meta[key].map { String(describing: $0) } ?? "Not recorded" }
        func metric(_ key: String, scale: Double = 1, suffix: String = "") -> String {
            guard let n = row[key] as? NSNumber else { return "Not recorded" }
            return String(format: "%.3f", n.doubleValue * scale) + suffix
        }
        let comparisons = edges.filter { ($0["asset_a"] as? String) == id || ($0["asset_b"] as? String) == id }
        let similarity = comparisons.map { edge -> String in
            let other = (edge["asset_a"] as? String) == id ? edge["asset_b"] : edge["asset_a"]
            let n = rows.firstIndex { ($0["asset_id"] as? String) == (other as? String) }
            return "Photo \(n.map { String($0 + 1) } ?? "unknown"): distance \(String(format: "%.4f", (edge["distance"] as? NSNumber)?.doubleValue ?? 0))"
        }.joined(separator: "\n")
        confirmBoth.title = hasBoth(row) ? "Remove confirmed Riley + Jordan tags" : "Confirm Riley + Jordan in this photo"
        let raw: [String: Any] = ["person_tags": annotations[id] ?? [:], "inventory": meta, "benchmark": row, "neighbor_distances": comparisons]
        let rawText = (try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "Unavailable"
        let faceText: String
        if let count = row["face_count"] as? Int {
            faceText = "Detected faces: \(count)\n" + (count >= 4 ? "REVIEW CANDIDATE · At least four faces detected." : "Fewer than four faces detected.") + "\nThis counts visible faces, not people’s identities. Small or obscured faces may be missed at this preview size."
        } else { faceText = "Not measured. " + (row["face_detection_error"] as? String ?? "") }
        details.string = """
        AI SEMANTIC METADATA · FIREWORKS GLM
        \((row["semantic_classification"] as? [String: Any])?["caption"] as? String ?? "Not indexed through GLM")
        People labels: \(row["catalog_people"] as? String ?? "None available")
        Label sources: \(row["people_sources"] as? String ?? "None")
        Full structured classification is included in the raw metadata below.

        PERSON TAGS · USER CONFIRMED
        \(hasBoth(row) ? "Riley + Jordan · Confirmed by you" : "Unreviewed · No confirmed pair tags")
        Tags are saved separately from face detection and are never copied automatically to other photos. This filter covers tagged photos in the loaded sample, not the whole library.

        FACE DETECTION · ON DEVICE
        \(faceText)

        WHAT RAN
        1. PhotoKit requested a small local preview (384 × 384 target, aspect fit).
        2. Pixel analysis measured brightness, clipping, and edge detail on a 128 × 128 grayscale image.
        Face detection, when recorded, used Apple Vision on the same small preview. Face boxes and detector confidence are saved; names are not inferred.
        3. Apple Vision generated a visual feature print. Nearby sampled photos taken within two minutes were compared.

        COLLECTED FROM PHOTOS · SAVED INVENTORY
        Capture date: \(value("created_at"))
        Modified: \(value("modified_at"))
        Original dimensions: \(value("width")) × \(value("height")) pixels
        Favorite: \((meta["favorite"] as? Bool).map { $0 ? "Yes" : "No" } ?? "Not recorded")
        Media: Photo · subtype flags: \(value("media_subtypes"))
        Source flags: \(value("source_type")) (not a personal/shared label)

        CAMERA METADATA · LOCAL FILE ONLY
        \(cameraText.isEmpty ? "Not collected in this benchmark." : cameraText)

        CONTENT LABELS · MACHINE SUGGESTED
        \((row["labels"] as? [[String: Any]] ?? []).map { "\($0["label"] ?? ""): \($0["confidence"] ?? "")" }.joined(separator: "\n"))

        OCR TEXT · MACHINE EXTRACTED
        \(row["ocr_text"] as? String ?? "Not collected")

        MEASURED FROM THE PREVIEW
        Actual preview: \(row["preview_width"] ?? "—") × \(row["preview_height"] ?? "—") pixels
        Mean brightness: \(metric("mean_luminance", scale: 100, suffix: "%"))
        Pixels near black or white: \(metric("clipped_pixel_fraction", scale: 100, suffix: "%"))
        Edge energy: \(metric("edge_energy"))
        Preview fetch: \(metric("fetch_seconds", scale: 1000, suffix: " ms"))
        Local analysis: \(metric("analysis_seconds", scale: 1000, suffix: " ms"))
        Vision feature-print revision: \(row["feature_revision"] ?? "Not recorded")
        Analysis error: \(row["analysis_error"] ?? "None recorded")
        Fetch error: \(row["fetch_error"] ?? "None recorded")

        SIMILARITY TO SAMPLED NEIGHBORS
        \(similarity.isEmpty ? "No comparison recorded for this photo." : similarity)
        Smaller distance means more visually similar. No duplicate threshold has been calibrated.

        HOW TO READ THESE RESULTS
        Brightness and clipping describe tone. Edge energy measures local contrast and texture; it is not a reliable focus or beauty score. These values do not yet identify the best photo.

        PRIVACY & LIMITS
        No automated identity recognition is performed. Named tags come only from your confirmation. Full-catalog indexing collects public metadata including filenames and GPS where available, plus machine labels and OCR. All remain local. Feature prints ran locally; only comparison distances were saved. Preview pixels were not saved. Metadata shown is saved from the scan or inventory. Camera fields are read only when locally available; camera model is not inferred from appearance.

        EXACT SAVED FIELDS
        \(rawText)
        """
        details.scrollToBeginningOfDocument(nil)
        previewStatus.stringValue = "Loading local preview…"
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { previewStatus.stringValue = "Photos access is required to display the preview. Saved metadata remains available."; return }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetch.firstObject, !asset.isHidden else { previewStatus.stringValue = "Photo is missing, hidden, or no longer accessible. Saved results are shown."; return }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false; options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast; options.version = .current
        requestID = manager.requestImage(for: asset, targetSize: NSSize(width: 384, height: 384), contentMode: .aspectFit, options: options) { preview, info in
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.image.image = preview
                self.previewStatus.stringValue = preview == nil ? "No local preview available. iCloud downloads are disabled." : "Current local preview • analyzed results above are from the saved benchmark."
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard self.generation == token, self.image.image == nil else { return }
            if let requestID = self.requestID { self.manager.cancelImageRequest(requestID) }
            self.previewStatus.stringValue = "Preview unavailable or timed out. Saved metadata is still available."
        }
    }
}
