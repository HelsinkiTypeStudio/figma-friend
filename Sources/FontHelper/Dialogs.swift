import AppKit
import UniformTypeIdentifiers

enum Dialogs {
    /// Asks whether a plugin may use Font Helper. Websites can reach localhost too,
    /// so the key is only handed out after you say yes.
    static func askToPair(plugin: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Allow “\(plugin)” to use your fonts?"
            alert.informativeText = "Only allow this if you just started this plugin in Figma. It lets the plugin read the font files installed on this Mac."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don’t Allow")
            alert.window.level = .floating
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    /// Shows a save dialog with the name filled in and the last folder used, then writes the file.
    static func save(name: String, data: Data, completion: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.canCreateDirectories = true
            panel.level = .floating
            if name.lowercased().hasSuffix(".pdf") { panel.allowedContentTypes = [.pdf] }
            if let folder = Settings.lastSaveFolder { panel.directoryURL = folder }
            guard panel.runModal() == .OK, let url = panel.url else {
                return completion(["cancelled": true])
            }
            do {
                try data.write(to: url, options: .atomic)
                Settings.lastSaveFolder = url.deletingLastPathComponent()
                Log.write("saved \(url.path) (\(data.count) bytes)")
                completion(["saved": url.path, "bytes": data.count])
            } catch {
                completion(["error": "could not save: \(error.localizedDescription)"])
            }
        }
    }
}
