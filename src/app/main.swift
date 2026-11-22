import AppKit

Diagnostics.mark("main")
ChaTab.log = { Diagnostics.tabLog($0) }
ExternalLinks.install()
ChaTab.allowsFloatingWindows = !Diagnostics.headless || ProcessInfo.processInfo.environment["CHA_FLOATING"] != nil

// CEF needs its own NSApplication subclass in place before any UI exists.
ChaEngine.installApplication()
if Diagnostics.headless { NSApp.setActivationPolicy(.accessory) }
// A windowed check on another screen keeps the Dock icon, as a real run
// would, but never comes to the front by itself. macOS still activates a
// freshly launched app once; focus goes straight back to whoever had it.
if Diagnostics.screenIndex != nil && !Diagnostics.loud {
    NSApp.setActivationPolicy(.regular)
    let previous = NSWorkspace.shared.frontmostApplication
    NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
        guard let previous, previous != NSRunningApplication.current else { return }
        NSApp.yieldActivation(to: previous)
        previous.activate()
        NSLog("QUIET gave focus back to %@", previous.localizedName ?? "-")
    }
}

// Links and files from other apps (cha as the default browser).
URLOpener.shared.install()

let launcher = Launcher()
ChaEngine.shared.delegate = launcher

guard ChaEngine.shared.start(withArgc: CommandLine.argc, argv: CommandLine.unsafeArgv)
else {
    exit(1)
}
Diagnostics.mark("cef-initialized")

ChaEngine.shared.run()
Diagnostics.mark("loop-exited")
ChaEngine.shared.shutdown()
Diagnostics.mark("shutdown-done")
exit(Int32(min(SpaceChecks.failed, 100)))

final class Launcher: NSObject, ChaEngineDelegate {
    var controller: BrowserController?

    func engineDidInitialize() {
        Diagnostics.mark("context-initialized")
        ChaTab.prepareWindows()
        let controller = BrowserController()
        self.controller = controller
        NSApp.mainMenu = MainMenu.build(controller: controller)
        if !Diagnostics.quiet {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        controller.showWindow()
        URLOpener.shared.install()
        URLOpener.shared.controller = controller
        controller.startCalendar()
        if let scenario = ProcessInfo.processInfo.environment["CHA_TEST"] {
            TestScenarios.run(scenario, controller: controller)
        }
    }

    func engineWillQuit() {
        guard let controller else {
            ChaEngine.shared.quit()
            return
        }
        controller.prepareToQuit { ChaEngine.shared.quit() }
    }
}
