import Cocoa
import Vision
import ImageIO

// Isolate native OCR traps from the indexer. Protocol: one JSON line in/out per image.
enum OCRWorker {
    static func serve() {
        while let line = readLine() {
            autoreleasepool {
                var result: [String: Any]
                do {
                    guard let bytes = line.data(using: .utf8),
                          let input = try JSONSerialization.jsonObject(with: bytes) as? [String: String],
                          let encoded = input["image"], let imageData = Data(base64Encoded: encoded),
                          let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        throw NSError(domain: "PhotoSignal.OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid worker image"])
                    }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .fast; request.usesLanguageCorrection = false
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    result = ["text": (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"), "revision": request.revision]
                } catch { result = ["error": error.localizedDescription] }
                if var output = try? JSONSerialization.data(withJSONObject: result) {
                    output.append(0x0a); try? FileHandle.standardOutput.write(contentsOf: output)
                }
            }
        }
    }
}

final class OCRWorkerClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    deinit { stop() }
    private func start() throws {
        if process?.isRunning == true { return }
        stop()
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--ocr-worker"]
        child.standardInput = stdin; child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
    }
    private func stop() {
        try? input?.close()
        if let child = process, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        process?.waitUntilExit()
        try? output?.close()
        process = nil; input = nil; output = nil
    }
    func testRecovery() -> [String: Any] {
        do {
            var pixels = [UInt8](repeating: 255, count: 64 * 64)
            let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
                CGContext(data: buffer.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
            }
            guard let image else { return ["passed": false, "error": "Synthetic image failed"] }
            try start()
            let victim = process!
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                if victim.isRunning { kill(victim.processIdentifier, SIGKILL) }
            }
            let interrupted = recognize(image)
            let recovered = recognize(image)
            return ["passed": interrupted["error"] != nil && recovered["error"] == nil, "interrupted": interrupted, "recovered": recovered]
        } catch { return ["passed": false, "error": error.localizedDescription] }
    }
    func recognize(_ image: CGImage) -> [String: Any] {
        do {
            try start()
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else { throw NSError(domain: "PhotoSignal.OCR", code: 2) }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            guard CGImageDestinationFinalize(destination), let reader = output, let writer = input else { throw NSError(domain: "PhotoSignal.OCR", code: 3) }
            var packet = try JSONSerialization.data(withJSONObject: ["image": (encoded as Data).base64EncodedString()]); packet.append(0x0a)
            let ready = DispatchSemaphore(value: 0), lock = NSLock()
            var received: [String: Any]?
            // Drain stdout while writing, so long OCR responses cannot block the worker.
            DispatchQueue.global(qos: .utility).async {
                var bytes = Data()
                do {
                    while true {
                        let chunk = reader.availableData
                        if chunk.isEmpty { break }
                        bytes.append(chunk)
                        if bytes.contains(0x0a) { break }
                        if bytes.count > 2_000_000 { break }
                    }
                    let parsed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                    lock.lock(); received = parsed; lock.unlock()
                } catch { }
                ready.signal()
            }
            try writer.write(contentsOf: packet)
            guard ready.wait(timeout: .now() + 20) == .success else {
                stop(); return ["error": "OCR worker timed out; indexing continued"]
            }
            lock.lock(); let result = received; lock.unlock()
            guard let result else {
                let code = process?.isRunning == false ? (process?.terminationStatus ?? -1) : -1
                stop(); return ["error": "OCR worker exited or returned invalid data (status \(code)); indexing continued"]
            }
            return result
        } catch { stop(); return ["error": "OCR worker failed: \(error.localizedDescription)"] }
    }
}
