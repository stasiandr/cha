// Times any Mac app's launch and quit from the outside, the same way for
// every app, so cha can be compared with Arc:
//
//   swift scripts/launchbench.swift <App.app> <runs> [KEY=VALUE ...]
//
// Each run: make sure the app is not running, launch it through
// LaunchServices (as a Dock click does), wait for its first real window to
// be on screen, let it settle, then send it the quit Apple event (what ⌘Q
// does) and wait for its windows to go and the process to end. Environment
// pairs are passed to the app (cha uses them for a throwaway profile).
//
// Prints one line per run and the medians, in milliseconds:
//   window   launch → first window of the app on screen
//   hidden   quit → no window of the app on screen
//   exit     quit → process gone
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let runs = Int(args[2]) else {
    print("usage: launchbench <App.app> <runs> [KEY=VALUE ...]")
    exit(2)
}
let appURL = URL(fileURLWithPath: args[1])
guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
    print("no bundle at \(args[1])")
    exit(2)
}
var environment: [String: String] = [:]
for pair in args.dropFirst(3) {
    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 { environment[parts[0]] = parts[1] }
}

func now() -> Double { Date().timeIntervalSince1970 * 1000 }

func running() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
}

// Spins the run loop (LaunchServices and termination notices need it).
func spin(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        spin(0.004)
    }
    return condition()
}

// A normal window of |pid| that is on screen and big enough to be the
// browser (not a splash or a status item).
func hasWindow(_ pid: pid_t) -> Bool {
    guard
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
    else { return false }
    return list.contains { info in
        guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
            (info[kCGWindowLayer as String] as? Int) == 0,
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
        else { return false }
        return (bounds["Width"] ?? 0) >= 400 && (bounds["Height"] ?? 0) >= 300
    }
}

func quitAll() {
    for app in running() { app.terminate() }
    if !waitUntil(15, { running().isEmpty }) {
        for app in running() { app.forceTerminate() }
        _ = waitUntil(5, { running().isEmpty })
    }
}

var results: [[String: Double]] = []
quitAll()
spin(1.5)

for run in 1...runs {
    var marks: [String: Double] = [:]
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.environment = environment
    configuration.activates = true
    configuration.createsNewApplicationInstance = false

    let start = now()
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
        if let error { print("launch error: \(error)") }
    }
    guard waitUntil(20, { !running().isEmpty }), let app = running().first else {
        print("\(run)/\(runs) did not start")
        continue
    }
    let pid = app.processIdentifier
    if waitUntil(20, { hasWindow(pid) }) { marks["window"] = now() - start }

    spin(4)  // Let it finish loading what it restores.

    let quit = now()
    app.terminate()
    if waitUntil(20, { !hasWindow(pid) }) { marks["hidden"] = now() - quit }
    if waitUntil(20, { app.isTerminated }) {
        marks["exit"] = now() - quit
    } else {
        marks["hung"] = 1
        app.forceTerminate()
        _ = waitUntil(5, { app.isTerminated })
    }
    results.append(marks)
    print(
        String(
            format: "%d/%d window=%.0f hidden=%.0f exit=%.0f%@", run, runs,
            marks["window"] ?? -1, marks["hidden"] ?? -1, marks["exit"] ?? -1,
            marks["hung"] != nil ? " HUNG" : ""))
    fflush(stdout)
    spin(2)
}

func median(_ key: String) -> Double {
    let values = results.compactMap { $0[key] }.sorted()
    guard !values.isEmpty else { return -1 }
    return values[values.count / 2]
}
print(
    String(
        format: "median %@ window=%.0f hidden=%.0f exit=%.0f", appURL.lastPathComponent,
        median("window"), median("hidden"), median("exit")))
