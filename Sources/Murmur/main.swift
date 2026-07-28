import AppKit

let app = NSApplication.shared

// Dock icon on by default; the General settings pane can drop back to a pure
// menu-bar accessory. Read straight from defaults — AppState isn't up yet.
let showInDock = UserDefaults.standard.object(forKey: "MurmurShowInDock") as? Bool ?? true
app.setActivationPolicy(showInDock ? .regular : .accessory)

app.mainMenu = MainMenu.build()

let delegate = AppDelegate()
app.delegate = delegate
app.run()
