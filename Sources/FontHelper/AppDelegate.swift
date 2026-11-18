import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let server = Server()
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let shrinkItem = NSMenuItem(title: "Make Saved PDFs Smaller", action: #selector(toggleShrink), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.toolTip = "Figma Friend"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(item("Copy Pairing Key", #selector(copyKey)))
        menu.addItem(item("Unpair All Plugins", #selector(unpair)))
        menu.addItem(.separator())
        shrinkItem.target = self
        menu.addItem(shrinkItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(item("Show Log", #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Figma Friend", #selector(quit), key: "q"))
        statusItem.menu = menu

        server.onStatus = { [weak self] s in self?.statusLine.title = "Figma Friend \(Settings.version): \(s)" }
        server.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Worker.shared.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        shrinkItem.state = Settings.shrinkPDFs ? .on : .off
    }

    /// A very simple "FF": two letters F made of plain bars, drawn as a template so macOS
    /// colours it for light and dark menu bars.
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            func letterF(at x: CGFloat) {
                NSBezierPath(rect: NSRect(x: x, y: 3, width: 2.4, height: 12)).fill()      // stem
                NSBezierPath(rect: NSRect(x: x, y: 12.6, width: 6.4, height: 2.4)).fill()  // top bar
                NSBezierPath(rect: NSRect(x: x, y: 7.8, width: 5, height: 2.2)).fill()     // middle bar
            }
            letterF(at: 2)
            letterF(at: 10)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Figma Friend"
        return image
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func copyKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Settings.pairingKey, forType: .string)
    }

    @objc private func unpair() {
        Settings.resetPairingKey()
        Log.write("pairing key reset: every plugin has to ask again")
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("could not change Open at Login: \(error)")
        }
    }

    @objc private func toggleShrink() {
        Settings.shrinkPDFs.toggle()
    }

    @objc private func showLog() {
        if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("log started") }
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
