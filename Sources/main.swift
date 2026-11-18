import AppKit

if CommandLine.arguments.contains("--dump") {
    MainActor.assumeIsolated { Diagnostic.dump() }
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    let passed = MainActor.assumeIsolated { Diagnostic.selfTest() }
    exit(passed ? 0 : 1)
}

if CommandLine.arguments.contains("--icon") {
    MainActor.assumeIsolated { Diagnostic.dumpIcon() }
    exit(0)
}

Debug.log("main: starting")
let application = NSApplication.shared
Debug.log("main: NSApplication.shared ok")
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
Debug.log("main: delegate set")
application.setActivationPolicy(.accessory)
Debug.log("main: activation policy set")
application.run()
Debug.log("main: run loop ended")
