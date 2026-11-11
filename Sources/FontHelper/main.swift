import AppKit

// A worker that quits mid-request must not take the app down with it.
signal(SIGPIPE, SIG_IGN)

// Figma Friend lives in the menu bar only: no Dock icon, no main window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
