import Cocoa

/// Reads durable worker telemetry; closing this window does not stop the worker.
final class CloudIndexWindow {
    private var window: NSWindow?
    private var timer: Timer?
    private var worker: Process?
    private var exporting = false
    private var month = "2026-10"
    private let heading = NSTextField(labelWithString: "October AI index")
    private let summary = NSTextField(wrappingLabelWithString: "Preparing…")
    private let meters = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let budget = NSProgressIndicator()
    private let detail = NSTextView()
    private var folder: URL { CatalogScan.base.appendingPathComponent("cloud-index/\(month)") }
    private var source: URL { CatalogScan.base.appendingPathComponent("sandbox-cache/\(month)") }

    func show(start: Bool = false) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--month"), i + 1 < args.count { month = args[i + 1] }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Photo Signal — AI Index Telemetry"; w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 850, height: 660)
            let content = w.contentView!
            heading.frame = NSRect(x: 24, y: 606, width: 800, height: 30); heading.font = .systemFont(ofSize: 24, weight: .semibold)
            summary.frame = NSRect(x: 24, y: 535, width: 800, height: 65); summary.font = .systemFont(ofSize: 14)
            progress.frame = NSRect(x: 24, y: 510, width: 800, height: 18); progress.isIndeterminate = false; progress.maxValue = 100
            meters.frame = NSRect(x: 24, y: 350, width: 800, height: 150); meters.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            budget.frame = NSRect(x: 24, y: 325, width: 800, height: 16); budget.isIndeterminate = false; budget.maxValue = 100
            for v in [heading, summary, progress, meters, budget] as [NSView] { content.addSubview(v) }
            let buttons: [(String, Selector)] = [("Start / Resume", #selector(resume)), ("Pause after active requests", #selector(pause)), ("Open run files", #selector(openFiles))]
            for (i, item) in buttons.enumerated() {
                let b = NSButton(title: item.0, target: self, action: item.1)
                b.frame = NSRect(x: 24 + i * 265, y: 278, width: 250, height: 34); content.addSubview(b)
            }
            let scroll = NSScrollView(frame: NSRect(x: 24, y: 24, width: 800, height: 242))
            scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
            detail.isEditable = false; detail.isSelectable = true; detail.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            scroll.documentView = detail; content.addSubview(scroll)
            w.center(); window = w
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        }
        window?.makeKeyAndOrderFront(nil); refresh()
        if start { resume() }
    }
    func downloadMissing() {
        guard !exporting, worker?.isRunning != true else { return }
        exporting = true
        DispatchQueue.global(qos: .utility).async {
            let ok = SandboxExport.recoverMissing(month: self.month, base: self.source) { _ in }
            DispatchQueue.main.async { self.exporting = false; if ok { self.launchWorker() } }
        }
    }
    @objc private func openFiles() { NSWorkspace.shared.open(folder) }
    @objc private func pause() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data().write(to: folder.appendingPathComponent("pause"))
        summary.stringValue = "Pause requested. Active requests finish and their usage is saved."
    }
    @objc private func resume() {
        guard worker?.isRunning != true, !exporting else { return }
        if !FileManager.default.fileExists(atPath: source.appendingPathComponent("summary.json").path) {
            exporting = true
            heading.stringValue = "\(month) · exporting local previews"
            DispatchQueue.global(qos: .utility).async {
                SandboxExport.run { _ in }
                DispatchQueue.main.async { self.exporting = false; self.launchWorker() }
            }
        } else { launchWorker() }
    }
    private func launchWorker() {
        do {
            guard let script = Bundle.main.url(forResource: "cloud_index", withExtension: "py") else { throw NSError(domain: "Cloud runner missing", code: 1) }
            let python = CatalogScan.base.appendingPathComponent("benchmark-venv/bin/python")
            guard FileManager.default.isExecutableFile(atPath: python.path) else { throw NSError(domain: "Python runtime missing", code: 2) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let log = folder.appendingPathComponent("worker.log")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
            let p = Process(); p.executableURL = python
            p.arguments = [script.path, "--month", month, "--budget", "2", "--concurrency", "2"]
            p.standardOutput = handle; p.standardError = handle
            p.terminationHandler = { _ in try? handle.close() }
            try p.run(); worker = p
            summary.stringValue = "Starting resumable worker. Previews go to Fireworks; names, GPS and dates stay local."
        } catch { summary.stringValue = "Could not start: \(error.localizedDescription)" }
    }
    private func object(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }
    private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    private func count(_ value: Any?) -> String { NumberFormatter.localizedString(from: NSNumber(value: number(value)), number: .decimal) }
    private func duration(_ value: Any?) -> String {
        let seconds = max(0, Int(number(value)))
        return String(format: "%dh %02dm %02ds", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
    private func refresh() {
        let p = object(folder.appendingPathComponent("progress.json"))
        if p.isEmpty {
            let e = object(source.appendingPathComponent("export-progress.json"))
            heading.stringValue = "\(month) · preparing local previews"
            summary.stringValue = "Checked \(count(e["checked"]))/\(count(e["eligible_photos"])) · exported \(count(e["exported"])) · unavailable \(count(e["unavailable"]))\nLocal Photos access only. Export time: \(duration(e["elapsed_seconds"]))"
            progress.doubleValue = number(e["checked"]) / max(1, number(e["eligible_photos"])) * 100
            meters.stringValue = "Fireworks requests: 0 · Tokens: 0 · Cost: $0\nConcurrency: 2 · Spending cap: $2\nOnly rendered previews are uploaded; iCloud downloads are disabled."
            return
        }
        let c = p["counts"] as? [String: Any] ?? [:], people = p["people"] as? [String: Any] ?? [:]
        let done = number(c["success"]), total = number(p["total"])
        let phase = p["phase"] as? String ?? "unknown"
        heading.stringValue = "\(month) · \(phase.replacingOccurrences(of: "_", with: " "))"
        var heartbeat = ""
        if let stamp = p["heartbeat_at"] as? String {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: stamp), Date().timeIntervalSince(date) > 10, ["indexing", "preparing", "apple_people", "pausing"].contains(phase) { heartbeat = " · HEARTBEAT STALE — worker may have stopped" }
        }
        summary.stringValue = "\(Int(done))/\(Int(total)) saved · active \(count(c["running"])) · waiting \(count(c["waiting"])) · failed \(count(c["failed"])) · unknown \(count(c["unknown"])) · unavailable \(count(c["unavailable"]))\n\(p["message"] as? String ?? "")\(heartbeat)"
        progress.doubleValue = done / max(1, total) * 100
        let spent = number(p["calculated_usd"]), reserved = number(p["reserved_usd"]), cap = number(p["budget_usd"])
        budget.doubleValue = (spent + reserved) / max(0.001, cap) * 100
        let median = p["median_request_seconds"] as? NSNumber
        meters.stringValue = "Input tokens: \(count(p["input_tokens"])) · Output: \(count(p["output_tokens"])) · Cached: \(count(p["cached_tokens"]))\nReasoning tokens: \(count(p["reasoning_tokens"])) · Requests: \(count(p["requests"])) · Unknown usage: \(count(p["usage_unknown_requests"]))\n" + String(format: "Calculated cost: $%.5f · Reserved: $%.5f · Cap: $%.2f\n", spent, reserved, cap) + "Active time: \(duration(p["active_seconds"])) · Request time (overlapping): \(duration(p["request_seconds_total"]))\nMedian request: \(median.map { String(format: "%.2fs", $0.doubleValue) } ?? "—") · ETA: \(p["eta_seconds"] is NSNull ? "—" : duration(p["eta_seconds"]))\nApple People: \(people["status"] as? String ?? "pending") · \(count(people["named_assets"])) photos with names\nCost is an estimate from token usage, not an invoice. Videos excluded."
        let recent = p["recent"] as? [[String: Any]] ?? []
        let phases = p["phase_seconds"] as? [String: Any] ?? [:]
        let phaseText = phases.keys.sorted().map { "\($0): \(duration(phases[$0]))" }.joined(separator: " · ")
        let recovery = p["icloud_recovery"] as? [String: Any] ?? [:]
        detail.string = "Export: \(duration(p["export_seconds"])) · iCloud recovery: \(duration(recovery["elapsed_seconds"])) · \(phaseText)\nRECENT PHOTOS — durable per-photo audit in run.sqlite\n\n" + recent.map { row in
            "\(row["sample_id"] as? String ?? "—")  \(row["status"] as? String ?? "—")  " + String(format: "%.2fs  $%.5f", number(row["wall_seconds"]), number(row["cost"])) + "  in:\(count(row["input_tokens"])) out:\(count(row["output_tokens"]))  \(row["error"] as? String ?? "")"
        }.joined(separator: "\n")
        let downloads = object(source.appendingPathComponent("download-progress.json"))
        if downloads["status"] as? String == "downloading" {
            heading.stringValue = "\(month) · downloading missing iCloud previews"
            summary.stringValue = "\(count(downloads["recovered"]))/\(count(downloads["total_missing"])) recovered · \(count(downloads["checked"])) checked · current download \(Int(number(downloads["current_download_fraction"]) * 100))%\nExisting GLM results are retained. Download time: \(duration(downloads["elapsed_seconds"]))"
            progress.doubleValue = number(downloads["checked"]) / max(1, number(downloads["total_missing"])) * 100
        } else if downloads["status"] as? String == "failed" {
            summary.stringValue += "\nPreview recovery failed: \(downloads["error"] as? String ?? "unknown error")"
        }
    }
}
