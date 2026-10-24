import Cocoa
import Photos
import CryptoKit

/// Menu-bar coordinator. Durable manifests and monthly job databases own the checkpoints.
final class HistoryIndexer: NSObject {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var worker: Process?
    private var busy = false
    private var processLock: Int32 = -1
    private var ownsProcessLock = false
    private var quitCompletion: (() -> Void)?
    private var storedMode = "paused"
    private var mode: String { get { stateLock.lock(); defer { stateLock.unlock() }; return storedMode } set { stateLock.lock(); storedMode = newValue; stateLock.unlock() } }
    private var storedBackfill = false
    private var backfill: Bool { get { stateLock.lock(); defer { stateLock.unlock() }; return storedBackfill } set { stateLock.lock(); storedBackfill = newValue; stateLock.unlock() } }
    private var settingsURL: URL { folder.appendingPathComponent("settings.json") }
    private var nextScan = Date.distantPast
    private var stop = true
    private let stateLock = NSLock()
    private let dataLock = NSRecursiveLock()
    private var storedState: [String: Any] = [:]
    private var state: [String:Any] { get {dataLock.lock();defer{dataLock.unlock()};return storedState} set {dataLock.lock();storedState=newValue;dataLock.unlock()} _modify { dataLock.lock(); defer { dataLock.unlock() }; yield &storedState } }
    private let base = CatalogScan.base
    private var folder: URL { base.appendingPathComponent("history") }
    private var file: URL { folder.appendingPathComponent("state.json") }
    private let title = NSMenuItem(title: "Indexer · paused", action: nil, keyEquivalent: "")
    private let counts = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let usage = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let message = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var detailWindow: NSWindow?
    private let text = NSTextView()
    private let statusLine = NSTextField(wrappingLabelWithString: "")
    private let progressBar = NSProgressIndicator()
    var hasActiveWork: Bool { busy }
    var openViewer: (() -> Void)?
    func install() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        processLock = open(folder.appendingPathComponent("agent.lock").path, O_CREAT | O_RDWR, 0o600)
        guard processLock >= 0, flock(processLock, LOCK_EX | LOCK_NB) == 0 else { NSApp.terminate(nil); return }
        ownsProcessLock = true
        let settings = object(settingsURL)
        mode = settings["mode"] as? String ?? "paused"
        backfill = settings["backfill"] as? Bool ?? false
        state = object(file)
        if state.isEmpty { state = ["phase":"ready", "message":"Ready to index older photos. $35 cap · batches of 100 · one request at a time.", "downloads":true, "cap":35.0, "completed_months":[], "gaps":[]] }
        state["phase"] = "paused"; state["message"] = "Paused. Choose Watch latest photos or Backfill history from the menu bar."; save()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Index"
        item.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Photo Signal Indexer")
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        for entry in [title,counts,usage,message] { menu.addItem(entry) }
        menu.addItem(.separator())
        for (label, action) in [("Resume history",#selector(resumeHistory)),("Watch latest photos",#selector(watchLatest)),("Backfill history…",#selector(backfillHistory)),("Pause after current work",#selector(pause)),("Show indexing status",#selector(showStatus)),("Open Photo Signal",#selector(showViewer)),("Open checkpoint files",#selector(openFiles)),("Quit Indexer",#selector(quit))] {
            let entry=NSMenuItem(title:label,action:action,keyEquivalent:"");entry.target=self;menu.addItem(entry)
        }
        item.menu = menu
        timer=Timer.scheduledTimer(withTimeInterval:5,repeats:true) { [weak self] _ in self?.tick() }
        refresh()
        if mode == "watching" { resume() }
    }
    private func persistSettings() {
        if let data = try? JSONSerialization.data(withJSONObject: ["mode": mode, "backfill": backfill]) { try? data.write(to: settingsURL, options: .atomic) }
    }
    @objc private func resumeHistory() { mode = "watching"; backfill = true; persistSettings(); resume() }
    @objc private func watchLatest() { mode = "watching"; backfill = false; persistSettings(); resume() }
    @objc private func backfillHistory() {
        let alert = NSAlert(); alert.messageText = "Backfill older photos"
        alert.informativeText = "Enter the first year to include. Recent photos run first, then older months. The existing $35 lifetime estimated indexing cap and unknown-request reservations still apply. Small missing previews may download from iCloud and go to Fireworks."
        let field = NSTextField(string: state["backfill_start_year"] as? String ?? "2025")
        field.frame = NSRect(x: 0, y: 0, width: 180, height: 26); alert.accessoryView = field
        alert.addButton(withTitle: "Start backfill"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, let year = Int(field.stringValue), (1900...Calendar.current.component(.year, from: Date())).contains(year) else { return }
        state["backfill_start_year"] = String(year); save()
        mode = "watching"; backfill = true; persistSettings(); resume()
    }
    private func tick() {
        refresh()
        if mode == "watching", !busy, quitCompletion == nil, Date() >= nextScan { resume() }
    }
    func prepareToQuit(_ completion: @escaping () -> Void) {
        guard ownsProcessLock else { completion(); return }
        quitCompletion = completion
        // Preserve the user's watch preference across a normal quit, but drain all active work.
        requestStop()
        if !busy { quitCompletion = nil; completion() }
    }
    private func object(_ url: URL) -> [String:Any] { guard let d=try? Data(contentsOf:url),let v=try? JSONSerialization.jsonObject(with:d) as? [String:Any] else{return [:]};return v }
    private func save() { dataLock.lock();defer{dataLock.unlock()};state["updated_at"]=ISO8601DateFormatter().string(from:Date());if let d=try? JSONSerialization.data(withJSONObject:state,options:[.sortedKeys,.prettyPrinted]){try? d.write(to:file,options:.atomic)} }
    private func set(_ phase:String,_ message:String) { state["phase"]=phase;state["message"]=message;save();DispatchQueue.main.async{self.refresh()} }
    private func stopped() -> Bool { stateLock.lock();defer{stateLock.unlock()};return stop }
    @objc func resume() {
        guard !busy else{return}
        nextScan = Date().addingTimeInterval(900)
        if PHPhotoLibrary.authorizationStatus(for:.readWrite) == .notDetermined {
            set("authorizing","Waiting for macOS Photos access approval…")
            PHPhotoLibrary.requestAuthorization(for:.readWrite){auth in DispatchQueue.main.async {if auth == .authorized {self.resume()}else{self.set("attention","Full Photos access was not granted. Enable Photos access in System Settings, then Resume.")}}};return
        }
        busy=true;stateLock.lock();stop=false;stateLock.unlock()
        DispatchQueue.global(qos:.utility).async {
            defer { DispatchQueue.main.async {
                self.busy = false; self.refresh()
                if let completion = self.quitCompletion { self.quitCompletion = nil; completion() }
            } }
            let fd=open(self.folder.appendingPathComponent("coordinator.lock").path,O_CREAT|O_RDWR,0o600)
            guard fd>=0 else {self.set("failed","Could not open history lock");return};defer{close(fd)}
            guard flock(fd,LOCK_EX|LOCK_NB)==0 else {self.set("waiting","History is running in another Photo Signal instance");return}
            guard PHPhotoLibrary.authorizationStatus(for:.readWrite) == .authorized else {self.set("attention","Full Photos access is required for complete historical coverage. Open Photos privacy settings.");return}
            do {try self.run()} catch {self.mode = "paused";self.persistSettings();self.set("failed",error.localizedDescription)}
        }
    }
    @objc func pause() {
        mode = "paused"; persistSettings(); requestStop()
    }
    private func requestStop() {
        stateLock.lock();stop=true;stateLock.unlock()
        if let month=state["month"] as? String {let path=base.appendingPathComponent("cloud-index/\(month)/pause");try? Data().write(to:path)}
        state["phase"]=busy ? "pausing" : "paused";state["message"]=busy ? "Finishing current preview and active request; no new batch will start." : "Paused. No new photos or API requests will start.";save();refresh()
    }
    @objc private func quit(){NSApp.terminate(nil)}
    @objc private func showViewer(){NSApp.activate(ignoringOtherApps:true);openViewer?()}
    @objc private func openFiles(){NSWorkspace.shared.open(folder)}
    @objc func showStatus(){
        if detailWindow == nil {let w=NSWindow(contentRect:NSRect(x:0,y:0,width:840,height:620),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false);w.title="Photo Signal Indexer";w.isReleasedWhenClosed=false
            let heading = NSTextField(labelWithString: "Photo Signal Indexer")
            heading.font = .systemFont(ofSize: 26, weight: .semibold); heading.frame = NSRect(x: 24, y: 568, width: 792, height: 36); heading.autoresizingMask = [.minYMargin]; w.contentView?.addSubview(heading)
            statusLine.frame = NSRect(x: 24, y: 496, width: 792, height: 64); statusLine.font = .systemFont(ofSize: 14); statusLine.autoresizingMask = [.width, .minYMargin]; w.contentView?.addSubview(statusLine)
            progressBar.frame = NSRect(x: 24, y: 474, width: 792, height: 10); progressBar.isIndeterminate = false; progressBar.maxValue = 1; progressBar.autoresizingMask = [.width, .minYMargin]; w.contentView?.addSubview(progressBar)
            let scroll=NSScrollView(frame:NSRect(x:16,y:48,width:808,height:408));scroll.autoresizingMask=[.width,.height];scroll.hasVerticalScroller=true;text.isEditable=false;text.isSelectable=true;text.font = .monospacedSystemFont(ofSize:11,weight:.regular);scroll.documentView=text;w.contentView?.addSubview(scroll)
            for (i,control) in [("Resume history",#selector(resumeHistory)),("Watch latest",#selector(watchLatest)),("Backfill history…",#selector(backfillHistory)),("Pause",#selector(pause))].enumerated(){let button=NSButton(title:control.0,target:self,action:control.1);button.frame=NSRect(x:16+i*180,y:8,width:165,height:32);w.contentView?.addSubview(button)}
            w.center();detailWindow=w}
        refresh();detailWindow?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    private func refresh(){
        let month=state["month"] as? String ?? "—",phase=state["phase"] as? String ?? "ready"
        let dirs=(try? FileManager.default.contentsOfDirectory(at:base.appendingPathComponent("cloud-index"),includingPropertiesForKeys:nil)) ?? []
        let totals=dirs.map{object($0.appendingPathComponent("progress.json"))}
        let spent=totals.reduce(0.0){$0+(($1["calculated_usd"] as? NSNumber)?.doubleValue ?? 0)},reserved=totals.reduce(0.0){$0+(($1["reserved_usd"] as? NSNumber)?.doubleValue ?? 0)}
        let input=totals.reduce(0){$0+(($1["input_tokens"] as? NSNumber)?.intValue ?? 0)},output=totals.reduce(0){$0+(($1["output_tokens"] as? NSNumber)?.intValue ?? 0)}
        let progress=object(base.appendingPathComponent("cloud-index/\(month)/progress.json")),c=progress["counts"] as? [String:Any] ?? [:]
        let running = busy && !["paused", "watching", "attention_required", "failed", "budget_paused"].contains(phase)
        let label = running ? "RUNNING" : (phase == "watching" ? "WATCHING — no history running" : (phase == "pausing" ? "PAUSING" : "PAUSED — no indexing running"))
        let scope = backfill ? "History: \(state["backfill_start_year"] as? String ?? "2025") onward" : "Recent photos only"
        title.title="\(label) · \(month) · \(phase.replacingOccurrences(of: "_", with: " "))"
        counts.title="Month: \(c["success"] ?? 0)/\(progress["total"] ?? 0) saved · waiting \(c["waiting"] ?? 0) · unavailable \(c["unavailable"] ?? 0) · uncertain \(c["unknown"] ?? 0) · failed \(c["failed"] ?? 0)"
        usage.title=String(format:"Total estimated $%.4f + $%.4f reserved / $35 · ",spent,reserved)+"Batch: \(progress["batch_new_requests"] ?? 0)/100 new · month $\(progress["calculated_usd"] ?? 0) · total cap $35"
        message.title=String((state["message"] as? String ?? "").prefix(100))
        item.button?.title = running ? "Running" : (phase == "watching" ? "Watching" : "Paused")
        let needsReview = ["unknown", "failed", "unavailable"].reduce(0) { $0 + ((c[$1] as? NSNumber)?.intValue ?? 0) }
        let tooltip = "Photo Signal Indexer · \(phase.capitalized)\n\(month): \(c["success"] ?? 0)/\(progress["total"] ?? 0) saved · \(c["waiting"] ?? 0) waiting · \(needsReview) need review\n" + String(format: "Estimated $%.4f + $%.4f reserved / $35", spent, reserved) + "\nClick for status and controls."
        item.button?.toolTip = tooltip
        item.button?.setAccessibilityHelp(tooltip)
        statusLine.stringValue = "\(title.title)\n\(scope) · \(counts.title)\n\(message.title)"
        let total = (progress["total"] as? NSNumber)?.doubleValue ?? 0
        progressBar.isIndeterminate = running && phase != "indexing"
        if progressBar.isIndeterminate { progressBar.startAnimation(nil) } else { progressBar.stopAnimation(nil) }
        progressBar.doubleValue = total > 0 ? ((c["success"] as? NSNumber)?.doubleValue ?? 0) / total : 0
        let completed=state["completed_months"] as? [String] ?? [],gaps=state["gaps"] as? [String] ?? []
        text.string="PHOTO SIGNAL INDEXER\n\n\(title.title)\n\(counts.title)\n\(usage.title)\n\n\(state["message"] as? String ?? "")\n\nInput tokens: \(input) · Output tokens: \(output)\nCompleted months: \(completed.count)\nMonths with gaps: \(gaps.joined(separator:", "))\n\n100 new requests per batch · concurrency 1 · $35 cumulative indexing cap\nMissing previews download from iCloud. Rendered 768px previews go to Fireworks. Names, dates and GPS stay local. Videos excluded.\n\nClose this window to continue from the menu bar. Pause persists across restarts. Quit drains active requests. Watching checks every 15 minutes while awake. Login startup can be installed separately.\n\nSaved monthly telemetry:\n" + (String(data:(try? JSONSerialization.data(withJSONObject:progress,options:[.prettyPrinted,.sortedKeys])) ?? Data(),encoding:.utf8) ?? "—")
    }
    private func run() throws {
        set("scanning","Reading photo dates to prepare the remaining months…")
        let options=PHFetchOptions();options.includeHiddenAssets=false;options.predicate=NSPredicate(format:"mediaType == %d",PHAssetMediaType.image.rawValue)
        if !backfill, let cutoff = Calendar.current.date(byAdding: .month, value: -4, to: Date()) {
            options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@", PHAssetMediaType.image.rawValue, cutoff as NSDate)
        }
        let assets=PHAsset.fetchAssets(with:options);let formatter=DateFormatter();formatter.calendar=Calendar(identifier:.gregorian);formatter.dateFormat="yyyy-MM";formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone.current
        var byMonth:[String:[PHAsset]]=[:]
        let now = Date(), currentMonth = formatter.string(from: Date())
        let recentFloor = formatter.string(from: Calendar.current.date(byAdding: .day, value: -90, to: now)!)
        for i in 0..<assets.count {let a=assets.object(at:i);if let date=a.creationDate {let m=formatter.string(from:date);if m <= currentMonth {byMonth[m,default:[]].append(a)}}}
        var done=Set(state["completed_months"] as? [String] ?? []),gaps=Set(state["gaps"] as? [String] ?? [])
        let earliest = backfill ? (state["backfill_start_year"] as? String ?? "2025") + "-01" : recentFloor
        let months=byMonth.keys.filter{$0>=earliest}.sorted(by:>);state["earliest_month"]=earliest;state["total_months"]=months.count;state["eligible_photos"]=months.reduce(0){$0+(byMonth[$1]?.count ?? 0)};save()
        var fingerprints = state["month_fingerprints"] as? [String: String] ?? [:]
        for month in months {
            let ordered = byMonth[month]!.sorted { $0.localIdentifier < $1.localIdentifier }
            let signature = ordered.map { $0.localIdentifier + "|" + String(($0.modificationDate ?? .distantPast).timeIntervalSince1970) + "|" + String($0.isFavorite) }.joined(separator: "\n")
            let fingerprint = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
            if fingerprints[month] == fingerprint { continue }
            if stopped(){break};state["month"]=month;set("exporting","Preparing \(month) previews; older months follow automatically.")
            let source=base.appendingPathComponent("sandbox-cache/\(month)")
            try export(month,byMonth[month]!.sorted{($0.creationDate ?? .distantPast)<($1.creationDate ?? .distantPast)},source)
            if stopped(){break}
            if !SandboxExport.recoverMissing(month:month,base:source,progress:{note in self.set("downloading",note)},shouldStop:{self.stopped()}) {if stopped(){break};throw NSError(domain:"PhotoSignal",code:1,userInfo:[NSLocalizedDescriptionKey:"iCloud recovery failed for \(month). See checkpoint files."])}
            if stopped(){break}
            repeat {
                set("indexing","\(month): processing the next batch of up to 100 photos. One request at a time.")
                try checkSpace()
                let phase=try launch(month)
                if stopped(){break}
                if phase=="batch_complete" {continue}
                if phase=="complete" || phase=="complete_with_gaps" {fingerprints[month] = fingerprint;state["month_fingerprints"] = fingerprints;done.insert(month);if phase=="complete_with_gaps"{gaps.insert(month)};state["completed_months"]=done.sorted();state["gaps"]=gaps.sorted();save();break}
                mode = "paused"; persistSettings();set(phase,"Paused at \(month): \(phase). Repeated errors or a budget limit need review. Choose Resume history to continue; uncertain photos are skipped.");return
            } while !stopped()
        }
        if !stopped(), backfill { backfill = false; persistSettings() }
        set(stopped() ? "paused":"watching",stopped() ? "Checkpoint saved. Resume skips completed work.":"Up to date for the requested range. Watching recent photos every 15 minutes. Videos excluded.")
    }
    private func launch(_ month:String) throws -> String {
        let path=base.appendingPathComponent("cloud-index/\(month)");try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let log=path.appendingPathComponent("history-worker.log");if !FileManager.default.fileExists(atPath:log.path){FileManager.default.createFile(atPath:log.path,contents:nil)}
        let handle=try FileHandle(forWritingTo:log);defer{try? handle.close()};try handle.seekToEnd()
        let p=Process();p.executableURL=base.appendingPathComponent("benchmark-venv/bin/python");p.arguments=[Bundle.main.url(forResource:"cloud_index",withExtension:"py")!.path,"--month",month,"--budget","35","--global-budget","35","--max-new","100","--concurrency","1"];p.qualityOfService = .utility;p.standardOutput=handle;p.standardError=handle
        try p.run();worker=p
        while p.isRunning {if stopped(){try? Data().write(to:path.appendingPathComponent("pause"))};Thread.sleep(forTimeInterval:1)}
        p.waitUntilExit();worker=nil
        if p.terminationStatus != 0 {throw NSError(domain:"PhotoSignal",code:2,userInfo:[NSLocalizedDescriptionKey:"Worker stopped for \(month). Inspect history-worker.log; no automatic retry."])}
        return object(path.appendingPathComponent("progress.json"))["phase"] as? String ?? "attention"
    }
    private func scaled(_ cg:CGImage)->CGImage? {let scale=min(1,768.0/Double(max(cg.width,cg.height)));let w=max(1,Int(Double(cg.width)*scale)),h=max(1,Int(Double(cg.height)*scale));guard let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else{return nil};context.interpolationQuality = .high;context.draw(cg,in:CGRect(x:0,y:0,width:w,height:h));return context.makeImage()}
    private func checkSpace() throws {let a=try FileManager.default.attributesOfFileSystem(forPath:base.path);if (a[.systemFreeSize] as? NSNumber)?.int64Value ?? 0 < 2_147_483_648 {throw NSError(domain:"PhotoSignal.Space",code:1,userInfo:[NSLocalizedDescriptionKey:"Paused: less than 2 GB free disk space. Free space, then Resume; existing work is saved."])}}
    private func export(_ month:String,_ assets:[PHAsset],_ source:URL) throws {
        let fm=FileManager.default
        for name in ["images-768","images-1536"]{try fm.createDirectory(at:source.appendingPathComponent(name),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        let manifest=source.appendingPathComponent("manifest.jsonl");var rows:[[String:Any]]=[]
        if let data=try? Data(contentsOf:manifest){rows=try String(decoding:data,as:UTF8.self).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}}
        var existing=Dictionary(rows.compactMap{row -> (String,[String:Any])? in guard let id=row["asset_id"] as? String else{return nil};return(id,row)},uniquingKeysWith:{$1})
        // Preserve stable filenames from previous exports; new assets use their UUID.
        rows=[]
        let validIDs=Set(assets.map{$0.localIdentifier})
        func checkpoint() throws {let processed=Set(rows.compactMap{$0["asset_id"] as? String});let preserved=existing.filter{validIDs.contains($0.key) && !processed.contains($0.key)}.values;var data=Data();for row in rows+Array(preserved){data.append(try JSONSerialization.data(withJSONObject:row,options:.sortedKeys));data.append(10)};try data.write(to:manifest,options:.atomic)}
        for (i,asset) in assets.enumerated(){
            if stopped(){break}
            try checkSpace()
            try autoreleasepool {
                var row=Benchmark.metadata(asset);let aid=asset.localIdentifier
                if let old=existing[aid],(old["modified_at"] as? String)==(row["modified_at"] as? String),let files=old["files"] as? [String:String],let rel=files["768"],fm.fileExists(atPath:source.appendingPathComponent(rel).path){row["files"] = files; row["sample_id"] = old["sample_id"]; row["status"] = old["status"]
                    rows.append(row); existing[aid] = row; return}
                let sid=(existing[aid]?["sample_id"] as? String) ?? aid.components(separatedBy:"/")[0]
                row["sample_id"]=sid
                let request=PHImageRequestOptions();request.isNetworkAccessAllowed=false;request.deliveryMode = .highQualityFormat;request.resizeMode = .fast;request.version = .current
                let ready=DispatchSemaphore(value:0),lock=NSLock();var received:NSImage?
                let rid=PHImageManager.default().requestImage(for:asset,targetSize:NSSize(width:768,height:768),contentMode:.aspectFit,options:request){image,info in if info?[PHImageResultIsDegradedKey] as? Bool == true{return};lock.lock();received=image;lock.unlock();ready.signal()}
                if ready.wait(timeout:.now()+3) == .timedOut {PHImageManager.default().cancelImageRequest(rid)}
                lock.lock();let image=received;lock.unlock();var files:[String:String]=[:]
                if let cg=image?.cgImage(forProposedRect:nil,context:nil,hints:nil),let small=self.scaled(cg),let data=NSBitmapImageRep(cgImage:small).representation(using:.jpeg,properties:[.compressionFactor:0.85]){let rel="images-768/\(sid).jpg";try data.write(to:source.appendingPathComponent(rel),options:.atomic);files["768"]=rel}
                row["files"]=files;row["status"]=files.isEmpty ? "unavailable":"exported";rows.append(row);existing[aid]=row
                try checkpoint()
            }
            if i%25==0{set("exporting","\(month): \(i+1)/\(assets.count) previews checked.")}
        }
        try checkpoint()
        if !stopped(){let summary:[String:Any]=["month":month,"status":"complete","eligible_photos":assets.count,"exported":rows.filter{!($0["files"] as? [String:String] ?? [:]).isEmpty}.count];try JSONSerialization.data(withJSONObject:summary).write(to:source.appendingPathComponent("summary.json"),options:.atomic)}
    }
}
