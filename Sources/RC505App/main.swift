// RC-505.app: the bridge plus its control page in a window. macOS only; the
// command-line `rc505` target is the cross-platform way to run the bridge.
#if os(macOS)
import AppKit
import RC505Core
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var bridge: Bridge?
    private var baseURL: URL { URL(string: "http://localhost:\(bridge?.port ?? 5055)/")! }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("public/overlay.html").path) else {
            fail("This copy of the app is missing its web pages.", "Rebuild it with build.sh.")
            return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RC-505")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        installSnapshot(from: resources.appendingPathComponent("data/memories.json"), to: support.appendingPathComponent("memories.json"))

        let bridge = Bridge(root: resources, dataDirectory: support)
        guard bridge.start() else {
            fail("Port \(bridge.port) is already in use.", "Another copy of the RC-505 bridge is probably running. Quit it and open this app again.")
            return
        }
        self.bridge = bridge
        showWindow()
    }

    /// The memory names and loop lengths are bundled at build time; use the bundled copy when it is newer.
    private func installSnapshot(from bundled: URL, to installed: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundled.path) else { return }
        let date: (URL) -> Date? = { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        if let have = date(installed), let new = date(bundled), have >= new { return }
        try? fm.removeItem(at: installed)
        try? fm.copyItem(at: bundled, to: installed)
    }

    private func fail(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: window

    private func showWindow() {
        if window == nil {
            let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            web.navigationDelegate = self
            web.setValue(false, forKey: "drawsBackground") // no white flash before the dark page loads
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "RC-505"
            w.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.043, alpha: 1)
            w.minSize = NSSize(width: 420, height: 420)
            w.isReleasedWhenClosed = false
            w.contentView = web
            w.center()
            w.setFrameAutosaveName("RC505Main")
            window = w
            webView = web
            web.load(URLRequest(url: baseURL))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Closing the window leaves the bridge running, so the OBS overlay keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // Keep the window on the bridge's own pages; anything else opens in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, url.host != "localhost", url.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    // MARK: menu

    private func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if action != #selector(NSApplication.terminate(_:)), action != #selector(NSApplication.hide(_:)),
               action != #selector(NSApplication.orderFrontStandardAboutPanel(_:)), action != #selector(NSWindow.performClose(_:)),
               action != #selector(NSWindow.performMiniaturize(_:)) { i.target = self }
            return i
        }
        add("RC-505", [
            item("About RC-505", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide RC-505", #selector(NSApplication.hide(_:)), "h"),
            item("Quit RC-505", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add("Overlay", [
            item("Copy Overlay URL for OBS", #selector(copyOverlayURL), "O"),
            item("Copy Outline Overlay URL for OBS", #selector(copyOutlineURL)),
            item("Copy Panel Overlay URL for OBS", #selector(copyPanelURL)),
            .separator(),
            item("Preview Overlay in Browser", #selector(openOverlay)),
            item("Open Control Page in Browser", #selector(openControl)),
        ])
        add("Window", [
            item("Show Control Window", #selector(showControl), "1"),
            item("Reload", #selector(reload), "r"),
            .separator(),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.mainMenu = main
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    @objc private func copyOverlayURL() { copy(baseURL.appendingPathComponent("overlay")) }
    @objc private func copyOutlineURL() { copy(URL(string: "overlay?style=outline", relativeTo: baseURL)!.absoluteURL) }
    @objc private func copyPanelURL() { copy(URL(string: "panel?style=bold&backdrop=%23102040cc&fade=40", relativeTo: baseURL)!.absoluteURL) }
    @objc private func openOverlay() { NSWorkspace.shared.open(baseURL.appendingPathComponent("overlay")) }
    @objc private func openControl() { NSWorkspace.shared.open(baseURL) }
    @objc private func showControl() { showWindow() }
    @objc private func reload() { webView?.reload() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
#else
print("RC505App is the macOS app. On this platform run the `rc505` command-line bridge instead.")
#endif
