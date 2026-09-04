import AppKit

// Explicit application entry point.
//
// DockDeck previously marked `AppDelegate` with `@main`. On AppKit that
// synthesises a call to `NSApplicationMain()`, which depends on the main nib
// (`NSMainNibFile`) to instantiate the delegate and wire it to `NSApp`. This
// bundle ships no nib and declares no custom `NSPrincipalClass`, so
// `NSApp.delegate` stayed nil for the whole process lifetime:
// `applicationDidFinishLaunching(_:)` never ran, and the app survived as a live
// process with no panel, no status item, and no storage directory — which is
// exactly how it presented to the user: "installed, running, invisible".
//
// Assigning the delegate before `run()` removes the nib dependency entirely.
// Uncaught Objective-C exceptions inside a delegate callback are swallowed by
// AppKit's event loop: the callback simply stops running and the app carries on
// looking healthy. Logging them is the difference between a diagnosable failure
// and a silent one.
NSSetUncaughtExceptionHandler { exception in
    NSLog("DockDeck: uncaught exception %@ — %@\n%@", exception.name.rawValue, exception.reason ?? "no reason", exception.callStackSymbols.joined(separator: "\n"))
    FileHandle.standardError.write(Data("DOCKDECK-EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "")\n".utf8))
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
