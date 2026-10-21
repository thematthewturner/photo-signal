import Cocoa

final class IndexerDelegate: NSObject, NSApplicationDelegate {
    let coordinator = HistoryIndexer()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.openViewer = {
            let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Photo Signal.app")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
        coordinator.install()
        if !CommandLine.arguments.contains("--background") { coordinator.showStatus() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { coordinator.showStatus(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !coordinator.hasActiveWork { return .terminateNow }
        coordinator.prepareToQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
let app = NSApplication.shared
let delegate = IndexerDelegate()
app.delegate = delegate
app.run()
