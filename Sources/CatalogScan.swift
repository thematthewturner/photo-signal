import Cocoa
import Photos
import Vision

final class CatalogScan {
    static let version = "vision-local-v2-ocr-isolated"
    static var base: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoSignal") }
    static func run(progress: @escaping (String) -> Void) {
        let logURL = base.appendingPathComponent("analysis.jsonl")
        let stopURL = base.appendingPathComponent("pause-indexing")
        do {
            try? FileManager.default.removeItem(at: stopURL)
            var completed = [String: String]()
            var previouslyUnavailable = [String: String]()
            if let source = try? String(contentsOf: logURL, encoding: .utf8) {
                source.enumerateLines { line, _ in
                    autoreleasepool {
                        guard let data = line.data(using: .utf8), let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              ["vision-local-v1", version].contains(row["pipeline_version"] as? String ?? ""),
                              let id = row["asset_id"] as? String, let metadata = row["metadata"] as? [String: Any] else { return }
                        let modified = metadata["modified_at"] as? String ?? ""
                        if row["status"] as? String == "complete" { completed[id] = modified; previouslyUnavailable.removeValue(forKey: id) }
                        else if row["status"] as? String == "no_local_preview", completed[id] == nil { previouslyUnavailable[id] = modified }
                    }
                }
            }
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let file = try FileHandle(forWritingTo: logURL)
            defer { try? file.close() }
            try file.seekToEnd()
            // Make a previously interrupted partial line harmless to subsequent import.
            try file.write(contentsOf: Data("\n".utf8))
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.includeHiddenAssets = false
            let assets = PHAsset.fetchAssets(with: options)
            let manager = PHImageManager.default()
            let ocrWorker = OCRWorkerClient()
            var done = 0, skipped = 0, unavailable = 0, reusedUnavailable = 0, ocrFailures = 0
            let started = Date()
            func saveState(_ state: String, checked: Int) throws {
                let row: [String: Any] = ["checked": checked, "total": assets.count, "analyzed_this_run": done, "reused": skipped, "unavailable": unavailable + reusedUnavailable, "unavailable_this_run": unavailable, "reused_unavailable": reusedUnavailable, "ocr_failures_this_run": ocrFailures, "elapsed_seconds": Date().timeIntervalSince(started), "status": state]
                try JSONSerialization.data(withJSONObject: row).write(to: base.appendingPathComponent("index-progress.json"), options: .atomic)
            }
            try saveState("running", checked: 0)
            for index in 0..<assets.count {
                if FileManager.default.fileExists(atPath: stopURL.path) { try saveState("paused", checked: index); progress("Index paused. Saved results are searchable; resume skips completed unchanged assets."); return }
                let asset = assets.object(at: index)
                let modified = asset.modificationDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
                if completed[asset.localIdentifier] == modified {
                    skipped += 1
                    if index % 1000 == 0 { try saveState("running", checked: index + 1); progress("Resuming: \(index + 1)/\(assets.count) checked; \(skipped) saved results reused.") }
                    continue
                }
                if !CommandLine.arguments.contains("--retry-unavailable"), previouslyUnavailable[asset.localIdentifier] == modified {
                    reusedUnavailable += 1
                    continue
                }
                if index % 100 == 0 {
                    let free = try base.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? Int.max
                    if free < 2_000_000_000 { try saveState("paused_low_disk", checked: index); progress("Index paused: less than 2 GB disk space available. Results are saved."); return }
                }
                try autoreleasepool {
                    var row: [String: Any] = ["asset_id": asset.localIdentifier, "metadata": Benchmark.metadata(asset), "pipeline_version": version, "analyzed_at": ISO8601DateFormatter().string(from: Date()), "network_access_allowed": false]
                    let tick = Date()
                    if let image = localPreview(manager, asset) {
                        var rect = CGRect.zero
                        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                            row["preview_width"] = cg.width; row["preview_height"] = cg.height
                            let faces = VNDetectFaceRectanglesRequest()
                            let classes = VNClassifyImageRequest()
                            let feature = VNGenerateImageFeaturePrintRequest()
                            var errors = [String: String]()
                            let handler = VNImageRequestHandler(cgImage: cg)
                            // Run separately so a failed optional analysis doesn't discard others.
                            for (name, request) in [("faces", faces as VNRequest), ("labels", classes as VNRequest), ("feature_print", feature as VNRequest)] {
                                do { try handler.perform([request]) } catch { errors[name] = error.localizedDescription }
                            }
                            if errors["faces"] == nil {
                                let observations = faces.results ?? []
                                row["face_count"] = observations.count
                                row["face_boxes"] = observations.map { f -> [String: Any] in
                                    let b = f.boundingBox
                                    return ["x": b.origin.x, "y": b.origin.y, "width": b.width, "height": b.height, "confidence": f.confidence]
                                }
                                row["face_detector_revision"] = faces.revision
                            }
                            row["labels"] = (classes.results ?? []).filter { $0.confidence >= 0.1 }.prefix(15).map { ["label": $0.identifier, "confidence": $0.confidence] as [String: Any] }
                            row["classifier_revision"] = classes.revision
                            let ocr = ocrWorker.recognize(cg)
                            if let error = ocr["error"] as? String {
                                row["ocr_status"] = "failed_isolated"; row["ocr_error"] = error; ocrFailures += 1
                            } else {
                                row["ocr_text"] = ocr["text"] ?? ""; row["ocr_revision"] = ocr["revision"]; row["ocr_status"] = "complete"
                            }
                            if let vector = feature.results?.first as? VNFeaturePrintObservation {
                                row["feature_revision"] = feature.revision
                                row["feature_print_base64"] = try NSKeyedArchiver.archivedData(withRootObject: vector, requiringSecureCoding: true).base64EncodedString()
                            }
                            let metrics = Benchmark.quality(cg)
                            row["mean_luminance"] = metrics.0; row["clipped_pixel_fraction"] = metrics.1; row["edge_energy"] = metrics.2
                            row["camera_metadata"] = Benchmark.cameraMetadata(asset)
                            row["analysis_errors"] = errors
                            row["status"] = errors.isEmpty ? "complete" : "partial"
                            done += 1
                        } else { row["status"] = "preview_decode_failed"; unavailable += 1 }
                    } else { row["status"] = "no_local_preview"; unavailable += 1 }
                    row["analysis_seconds"] = Date().timeIntervalSince(tick)
                    var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(0x0a)
                    try file.write(contentsOf: data)
                }
                if (done + unavailable) % 50 == 0 || index + 1 == assets.count {
                    try file.synchronize()
                    let message = "Local index: \(index + 1)/\(assets.count) checked; \(done) analyzed, \(skipped) reused, \(unavailable + reusedUnavailable) unavailable; OCR failures isolated: \(ocrFailures). No iCloud downloads."
                    progress(message)
                    try saveState("running", checked: index + 1)
                    // Bounded incremental imports keep the catalog usable during a long scan.
                    _ = try? CatalogBackend.call(["sync"])
                }
            }
            _ = try CatalogBackend.call(["sync"])
            try saveState("complete", checked: assets.count)
            progress("Index complete: \(done) analyzed, \(skipped) reused, \(unavailable + reusedUnavailable) unavailable; \(ocrFailures) isolated OCR failures. Search is ready.")
        } catch {
            let url = base.appendingPathComponent("index-progress.json")
            var state = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            state["status"] = "failed"; state["error"] = error.localizedDescription
            try? JSONSerialization.data(withJSONObject: state).write(to: url, options: .atomic)
            progress("Index stopped: \(error.localizedDescription). Completed records are preserved.")
        }
    }
    private static func localPreview(_ manager: PHImageManager, _ asset: PHAsset) -> NSImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false; options.deliveryMode = .highQualityFormat; options.resizeMode = .fast
        let lock = NSLock(), ready = DispatchSemaphore(value: 0)
        var result: NSImage?
        let id = manager.requestImage(for: asset, targetSize: NSSize(width: 512, height: 512), contentMode: .aspectFit, options: options) { image, info in
            if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
            lock.lock(); result = image; lock.unlock(); ready.signal()
        }
        if ready.wait(timeout: .now() + 3) == .timedOut { manager.cancelImageRequest(id) }
        lock.lock(); defer { lock.unlock() }; return result
    }
}
