import AppKit

Diagnostics.mark("main")

// CEF needs its own NSApplication subclass in place before any UI exists.
ChaEngine.installApplication()
if Diagnostics.headless { NSApp.setActivationPolicy(.accessory) }

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

final class Launcher: NSObject, ChaEngineDelegate {
    var controller: BrowserController?

    func engineDidInitialize() {
        Diagnostics.mark("context-initialized")
        let controller = BrowserController()
        self.controller = controller
        NSApp.mainMenu = MainMenu.build(controller: controller)
        if !Diagnostics.headless {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        controller.showWindow()
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
