import AppKit

// 自動復元(Resume)は起動前に切っておく。ウィンドウ側でも isRestorable = false にしてある。
UserDefaults.standard.register(defaults: [
    "NSQuitAlwaysKeepsWindows": false,
    "ApplePersistenceIgnoreState": true,
])

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
