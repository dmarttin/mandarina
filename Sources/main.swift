import AppKit

// One instance only: two wheels would race for the same modifier keys.
if let identifier = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1 {
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
