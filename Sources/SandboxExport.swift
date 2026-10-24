import Cocoa
import Photos

// Exports rendered derivatives. Network access is enabled only for an explicit missing-preview recovery.
enum SandboxExport {
    static func recoverMissing(month: String, base: URL, progress: @escaping (String) -> Void, shouldStop: () -> Bool = { false }) -> Bool {
        let started = Date(), fm = FileManager.default, formatter = ISO8601DateFormatter()
        let telemetryURL = base.appendingPathComponent("download-progress.json")
        var checked = 0, recovered = 0, finalized = false
        let telemetryLock = NSLock()
        func telemetry(_ status: String, _ total: Int, _ fraction: Double = 0, _ error: String = "") {
            telemetryLock.lock(); defer { telemetryLock.unlock() }
            if finalized { return }
            if status != "downloading" { finalized = true }
            let value: [String: Any] = ["status": status, "month": month, "total_missing": total, "checked": checked, "recovered": recovered, "remaining": total - recovered, "current_download_fraction": fraction, "elapsed_seconds": Date().timeIntervalSince(started), "updated_at": formatter.string(from: Date()), "network_access": true, "error": error]
            if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { try? bytes.write(to: telemetryURL, options: .atomic) }
        }
        do {
            let lockFD = open(base.appendingPathComponent("download.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0 else { throw NSError(domain: "Download lock unavailable", code: 1) }
            defer { close(lockFD) }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "Preview recovery already running", code: 2) }
            let manifestURL = base.appendingPathComponent("manifest.jsonl")
            let original = try Data(contentsOf: manifestURL)
            var rows = try String(decoding: original, as: UTF8.self).split(separator: "\n").map { line -> [String: Any] in
                guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { throw NSError(domain: "Invalid manifest", code: 3) }
                return row
            }
            func hasPreview(_ row: [String: Any]) -> Bool {
                guard let path = (row["files"] as? [String: String])?["768"] else { return false }
                return fm.fileExists(atPath: base.appendingPathComponent(path).path)
            }
            let missing = rows.indices.filter { !hasPreview(rows[$0]) }
            if !fm.fileExists(atPath: base.appendingPathComponent("manifest-before-icloud.jsonl").path) { try original.write(to: base.appendingPathComponent("manifest-before-icloud.jsonl"), options: .atomic) }
            telemetry("downloading", missing.count)
            for index in missing {
                if shouldStop() { telemetry("paused", missing.count); return false }
                let disk = try fm.attributesOfFileSystem(forPath: base.path)
                if (disk[.systemFreeSize] as? NSNumber)?.int64Value ?? 0 < 2_147_483_648 { throw NSError(domain:"PhotoSignal.Space",code:1,userInfo:[NSLocalizedDescriptionKey:"Less than 2 GB free disk space; recovery paused."]) }
                try autoreleasepool {
                    guard let aid = rows[index]["asset_id"] as? String, let sid = rows[index]["sample_id"] as? String else { throw NSError(domain: "Missing asset identity", code: 4) }
                    let options = PHFetchOptions(); options.includeHiddenAssets = false
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [aid], options: options)
                    var error = "Photo unavailable or deleted"
                    if let asset = assets.firstObject {
                        let request = PHImageRequestOptions()
                        request.isNetworkAccessAllowed = true
                        request.deliveryMode = .highQualityFormat; request.resizeMode = .fast; request.version = .current
                        request.progressHandler = { fraction, _, _, _ in telemetry("downloading", missing.count, fraction) }
                        let ready = DispatchSemaphore(value: 0), lock = NSLock()
                        var image: NSImage?, callbackError: String?
                        let requestID = PHImageManager.default().requestImage(for: asset, targetSize: NSSize(width: 768, height: 768), contentMode: .aspectFit, options: request) { result, info in
                            if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                            lock.lock(); image = result; callbackError = (info?[PHImageErrorKey] as? Error)?.localizedDescription; lock.unlock(); ready.signal()
                        }
                        let timedOut = ready.wait(timeout: .now() + 120) == .timedOut
                        if timedOut { PHImageManager.default().cancelImageRequest(requestID) }
                        lock.lock(); let received = image, receivedError = callbackError; lock.unlock()
                        error = timedOut ? "Preview request timed out after 120 seconds" : (receivedError ?? "No preview returned")
                        if let image = received, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                            var files = rows[index]["files"] as? [String: String] ?? [:]
                            for size in [768, 1536] {
                                let scale = min(1, Double(size) / Double(max(cg.width, cg.height)))
                                let w = max(1, Int(Double(cg.width) * scale)), h = max(1, Int(Double(cg.height) * scale))
                                guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
                                context.interpolationQuality = .high; context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                                guard let output = context.makeImage(), let data = NSBitmapImageRep(cgImage: output).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { continue }
                                let path = "images-\(size)/\(sid).jpg"
                                try data.write(to: base.appendingPathComponent(path), options: .atomic)
                                files[String(size)] = path; rows[index]["dimensions_\(size)"] = [w, h]
                            }
                            rows[index]["files"] = files
                            if hasPreview(rows[index]) {
                                for (key, value) in Benchmark.metadata(asset) { rows[index][key] = value }
                                rows[index]["status"] = "exported"; rows[index]["preview_source"] = "PhotoKit network-enabled missing-preview recovery"
                                rows[index]["preview_recovered_at"] = formatter.string(from: Date())
                                recovered += 1; error = ""
                            }
                        }
                    }
                    rows[index]["recovery_error"] = error
                    var lines = Data()
                    for row in rows { lines.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); lines.append(10) }
                    try lines.write(to: manifestURL, options: .atomic)
                }
                checked += 1; telemetry("downloading", missing.count)
                progress("iCloud previews: \(recovered)/\(missing.count) recovered; \(checked) checked.")
            }
            let available = rows.filter(hasPreview).count
            let summary: [String: Any] = ["month": month, "timezone": TimeZone.current.identifier, "eligible_photos": rows.count, "exported": available, "skipped": rows.count - available, "network_access": true, "status": "complete", "recovered_from_missing": recovered]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: base.appendingPathComponent("summary.json"), options: .atomic)
            telemetry(recovered == missing.count ? "complete" : "complete_with_gaps", missing.count)
            return true
        } catch {
            telemetry("failed", 0, 0, error.localizedDescription)
            progress("iCloud preview recovery failed: \(error.localizedDescription)")
            return false
        }
    }
    static func run(progress: @escaping (String) -> Void) {
        let args = CommandLine.arguments
        let month = args.firstIndex(of: "--month").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "2026-09"
        let base = args.contains("--local-cache") ? CatalogScan.base.appendingPathComponent("sandbox-cache/\(month)") : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/PhotoSignal-Sandbox/\(month)")
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone.current
            let parts = month.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2, (1...12).contains(parts[1]), let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)), let end = calendar.date(byAdding: .month, value: 1, to: start) else { throw NSError(domain: "Invalid month", code: 1) }
            let fm = FileManager.default
            for folder in ["images-768", "images-1536"] {
                try fm.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
            let options = PHFetchOptions()
            options.includeHiddenAssets = false
            options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate < %@", PHAssetMediaType.image.rawValue, start as NSDate, end as NSDate)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let assets = PHAsset.fetchAssets(with: options)
            let allCount = PHAsset.fetchAssets(with: nil).count
            let started = Date()
            func telemetry(_ checked: Int, _ exported: Int, _ state: String) {
                let value: [String: Any] = ["month": month, "eligible_photos": assets.count, "library_assets": allCount, "authorization_raw": PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue, "checked": checked, "exported": exported, "unavailable": checked - exported, "status": state, "elapsed_seconds": Date().timeIntervalSince(started), "updated_at": ISO8601DateFormatter().string(from: Date()), "network_access": false]
                if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { try? data.write(to: base.appendingPathComponent("export-progress.json"), options: .atomic) }
            }
            telemetry(0, 0, "exporting")
            let manifestURL = base.appendingPathComponent("manifest.jsonl")
            fm.createFile(atPath: manifestURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: manifestURL)
            defer { try? handle.close() }
            var exported = 0
            for index in 0..<assets.count {
                try autoreleasepool {
                    let asset = assets.object(at: index)
                    let key = String(format: "%05d", index + 1)
                    var row = Benchmark.metadata(asset)
                    row["sample_id"] = key
                    var image: NSImage?
                    for target in [1536, 512] {
                        let request = PHImageRequestOptions()
                        request.isNetworkAccessAllowed = false
                        request.deliveryMode = .highQualityFormat
                        request.resizeMode = .fast
                        request.version = .current
                        let ready = DispatchSemaphore(value: 0), lock = NSLock()
                        var received: NSImage?
                        let id = PHImageManager.default().requestImage(for: asset, targetSize: NSSize(width: target, height: target), contentMode: .aspectFit, options: request) { result, info in
                            if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                            lock.lock(); received = result; lock.unlock(); ready.signal()
                        }
                        if ready.wait(timeout: .now() + 3) == .timedOut { PHImageManager.default().cancelImageRequest(id) }
                        lock.lock(); image = received; lock.unlock()
                        if image != nil { row["requested_preview_size"] = target; break }
                    }
                    var files: [String: String] = [:]
                    if let image = image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        for size in [768, 1536] {
                            let scale = min(1, Double(size) / Double(max(cg.width, cg.height)))
                            let w = max(1, Int(Double(cg.width) * scale)), h = max(1, Int(Double(cg.height) * scale))
                            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
                            context.interpolationQuality = .high
                            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                            guard let output = context.makeImage(), let data = NSBitmapImageRep(cgImage: output).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { continue }
                            let path = "images-\(size)/\(key).jpg"
                            try data.write(to: base.appendingPathComponent(path), options: .atomic)
                            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: base.appendingPathComponent(path).path)
                            files[String(size)] = path
                            row["dimensions_\(size)"] = [w, h]
                        }
                    }
                    row["files"] = files
                    row["status"] = files.count == 2 ? "exported" : "unavailable_or_incomplete"
                    if files.count == 2 { exported += 1 }
                    var line = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    line.append(10); try handle.write(contentsOf: line)
                }
                if index % 25 == 0 { progress("Sandbox: \(index + 1)/\(assets.count) checked; \(exported) exported. Local images only.") }
                telemetry(index + 1, exported, "exporting")
            }
            let summary: [String: Any] = ["month": month, "timezone": TimeZone.current.identifier, "eligible_photos": assets.count, "exported": exported, "skipped": assets.count - exported, "network_access": false, "status": "complete"]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: base.appendingPathComponent("summary.json"), options: .atomic)
            telemetry(assets.count, exported, "complete")
            progress("Sandbox complete: \(exported)/\(assets.count) photos exported. Folder: \(base.path)")
            DispatchQueue.main.async { NSWorkspace.shared.open(base) }
        } catch { progress("Sandbox export failed: \(error.localizedDescription)") }
    }
}
