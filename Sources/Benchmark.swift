import Cocoa
import Photos
import Vision
import ImageIO

// Apple Vision feature prints run on-device. They support similarity, not text search.
final class Benchmark {
    static func run(recent: Bool = false, randomFaces: Bool = false, progress: @escaping (String) -> Void) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoSignal")
        let started = Date()
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !recent)]
            options.includeHiddenAssets = false
            let endDate = Date()
            let startDate = Calendar.current.date(byAdding: .day, value: -30, to: endDate)!
            if recent { options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", startDate as NSDate, endDate as NSDate) }
            let assets = PHAsset.fetchAssets(with: .image, options: options)
            // Twenty contiguous windows spread across the timeline: preserves neighbors for grouping.
            var indexes = Set<Int>()
            for block in 0..<20 {
                let start = Int(Double(max(0, assets.count - 50)) * Double(block) / 19.0)
                for index in start..<min(start + 50, assets.count) { indexes.insert(index) }
            }
            if recent { indexes = Set(0..<min(1000, assets.count)) }
            if randomFaces { indexes = Set(Array(0..<assets.count).shuffled().prefix(100)) }
            progress("Starting local preview requests for \(indexes.count) photos…")
            let manager = PHImageManager.default()
            var rows = [[String: Any]]()
            var previous: (PHAsset, VNFeaturePrintObservation)?
            var edges = [[String: Any]]()
            var available = 0, unavailable = 0, failed = 0
            var peakBytes: UInt64 = 0
            let total = indexes.count
            for (number, index) in indexes.sorted().enumerated() {
                autoreleasepool {
                    let asset = assets.object(at: index)
                    let tick = Date()
                    let request = PHImageRequestOptions()
                    request.isNetworkAccessAllowed = false
                    request.isSynchronous = false
                    request.deliveryMode = .highQualityFormat
                    request.resizeMode = .fast
                    request.version = .current
                    var received: NSImage?
                    var inCloud = false
                    var errorDescription: String?
                    let resultLock = NSLock()
                    let ready = DispatchSemaphore(value: 0)
                    let requestID = manager.requestImage(for: asset, targetSize: NSSize(width: 384, height: 384), contentMode: .aspectFit, options: request) { image, info in
                        if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                        resultLock.lock(); defer { resultLock.unlock() }
                        received = image
                        inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                        errorDescription = (info?[PHImageErrorKey] as? Error)?.localizedDescription
                        ready.signal()
                    }
                    if ready.wait(timeout: .now() + 3) == .timedOut {
                        manager.cancelImageRequest(requestID)
                        resultLock.lock()
                        errorDescription = "preview_request_timeout"
                        resultLock.unlock()
                    }
                    resultLock.lock()
                    let finalImage = received, finalCloud = inCloud, finalError = errorDescription
                    resultLock.unlock()
                    var row: [String: Any] = ["asset_id": asset.localIdentifier, "fetch_seconds": Date().timeIntervalSince(tick), "in_cloud": finalCloud]
                    if recent {
                        row["metadata"] = metadata(asset)
                        row["camera_metadata"] = cameraMetadata(asset)
                    }
                    var rect = CGRect.zero
                    if let cg = finalImage?.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                        available += 1
                        row["preview_width"] = cg.width; row["preview_height"] = cg.height
                        let analysisStart = Date()
                        if randomFaces {
                            do {
                                let faces = VNDetectFaceRectanglesRequest()
                                try VNImageRequestHandler(cgImage: cg).perform([faces])
                                let observations = faces.results ?? []
                                row["face_count"] = observations.count
                                row["face_detector_revision"] = faces.revision
                                row["face_boxes"] = observations.map { face -> [String: Any] in
                                    let b = face.boundingBox
                                    return ["x": b.origin.x, "y": b.origin.y, "width": b.width, "height": b.height, "confidence": face.confidence]
                                }
                            } catch { row["face_detection_error"] = error.localizedDescription }
                        }
                        let metrics = quality(cg)
                        row["mean_luminance"] = metrics.0
                        row["clipped_pixel_fraction"] = metrics.1
                        row["edge_energy"] = metrics.2
                        do {
                            let feature = VNGenerateImageFeaturePrintRequest()
                            try VNImageRequestHandler(cgImage: cg).perform([feature])
                            if let print = feature.results?.first as? VNFeaturePrintObservation {
                                row["feature_revision"] = feature.revision
                                if let prior = previous, let a = prior.0.creationDate, let b = asset.creationDate, abs(b.timeIntervalSince(a)) <= 120 {
                                    var distance: Float = 0
                                    try print.computeDistance(&distance, to: prior.1)
                                    // Preserve raw distances; do not claim a calibrated duplicate threshold.
                                    edges.append(["asset_a": prior.0.localIdentifier, "asset_b": asset.localIdentifier, "distance": distance])
                                }
                                previous = (asset, print)
                            }
                        } catch { row["analysis_error"] = error.localizedDescription; failed += 1; previous = nil }
                        row["analysis_seconds"] = Date().timeIntervalSince(analysisStart)
                    } else {
                        unavailable += 1; previous = nil
                        row["status"] = "no_local_preview"
                        if let error = finalError { row["fetch_error"] = error }
                    }
                    rows.append(row)
                    var usage = rusage()
                    getrusage(RUSAGE_SELF, &usage)
                    peakBytes = max(peakBytes, UInt64(usage.ru_maxrss))
                }
                if number % 25 == 0 || number + 1 == total {
                    progress("Benchmark: \(number + 1)/\(total); \(available) local previews, \(unavailable) unavailable. iCloud downloads disabled.")
                    let snapshot: [String: Any] = ["processed": number + 1, "total": total, "local_previews": available, "unavailable": unavailable, "elapsed_seconds": Date().timeIntervalSince(started)]
                    try save(snapshot, to: base.appendingPathComponent("benchmark-progress.json"))
                }
            }
            let elapsed = Date().timeIntervalSince(started)
            let report: [String: Any] = ["face_detection_enabled": randomFaces, "face_preview_target_pixels": 384, "sample_method": randomFaces ? "Uniform random sample without replacement, up to 100 photos from preceding 30 days; selected IDs recorded in rows" : recent ? "Newest up to 1000 photos captured in last 30 days" : "20 chronological windows of up to 50 photos", "matching_photo_count": assets.count, "date_start": recent ? ISO8601DateFormatter().string(from: startDate) : "all", "date_end": ISO8601DateFormatter().string(from: endDate), "requested": total, "local_previews": available, "unavailable": unavailable, "analysis_errors": failed, "elapsed_seconds": elapsed, "assets_per_second": Double(total) / max(elapsed, 0.001), "peak_resident_bytes": peakBytes, "network_access_allowed": false, "similarity": "Apple Vision feature print; raw temporal-neighbor distances, uncalibrated", "quality": "Preview luminance, clipping, edge energy; not a calibrated aesthetic or focus ranking", "rows": rows, "neighbor_distances": edges]
            let destination = base.appendingPathComponent("benchmark.json")
            if FileManager.default.fileExists(atPath: destination.path) {
                let archive = base.appendingPathComponent("benchmark-archive-\(Int(Date().timeIntervalSince1970)).json")
                try FileManager.default.copyItem(at: destination, to: archive)
            }
            try save(report, to: base.appendingPathComponent("benchmark.json"))
            progress("Benchmark complete: \(available)/\(total) local previews; \(unavailable) unavailable. \(Int(elapsed)) seconds; peak memory \(peakBytes / 1_048_576) MB. Report saved in Application Support/PhotoSignal/benchmark.json.")
        } catch { progress("Benchmark failed: \(error.localizedDescription)") }
    }
    static func metadata(_ asset: PHAsset) -> [String: Any] {
        var row: [String: Any] = ["media_type": asset.mediaType.rawValue, "duration": asset.duration, "asset_id": asset.localIdentifier, "width": asset.pixelWidth, "height": asset.pixelHeight, "favorite": asset.isFavorite, "media_subtypes": asset.mediaSubtypes.rawValue, "source_type": asset.sourceType.rawValue]
        if let date = asset.creationDate { row["created_at"] = ISO8601DateFormatter().string(from: date) }
        if let date = asset.modificationDate { row["modified_at"] = ISO8601DateFormatter().string(from: date) }
        return row
    }
    static func cameraMetadata(_ asset: PHAsset) -> [String: Any] {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = false
        let lock = NSLock(), ready = DispatchSemaphore(value: 0)
        var result: [String: Any] = ["status": "No locally accessible image metadata"]
        let id = asset.requestContentEditingInput(with: options) { input, _ in
            var extracted: [String: Any] = ["status": "No locally accessible image metadata"]
            if let url = input?.fullSizeImageURL,
               let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                extracted = ["status": "Read local image properties; GPS and filenames excluded"]
                let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
                let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
                for key in ["Make", "Model"] { if let value = tiff[key] { extracted[key] = value } }
                for key in ["LensModel", "FNumber", "ExposureTime", "ISOSpeedRatings", "FocalLength", "FocalLenIn35mmFilm", "DateTimeOriginal"] { if let value = exif[key] { extracted[key] = value } }
            }
            lock.lock(); result = extracted; lock.unlock(); ready.signal()
        }
        if ready.wait(timeout: .now() + 2) == .timedOut {
            asset.cancelContentEditingInputRequest(id)
            return ["status": "Local camera metadata request timed out"]
        }
        lock.lock(); defer { lock.unlock() }; return result
    }
    private static func save(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func quality(_ image: CGImage) -> (Double, Double, Double) {
        let w = 128, h = 128
        var bytes = [UInt8](repeating: 0, count: w * h)
        let drawn = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard drawn else { return (0, 0, 0) }
        var sum = 0.0, clipped = 0.0, energy = 0.0
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x, v = Double(bytes[i]); sum += v
            if v <= 3 || v >= 252 { clipped += 1 }
            if x > 0 { energy += pow(v - Double(bytes[i - 1]), 2) }
            if y > 0 { energy += pow(v - Double(bytes[i - w]), 2) }
        } }
        return (sum / Double(w * h) / 255, clipped / Double(w * h), energy / Double(2 * w * h - w - h))
    }
}
