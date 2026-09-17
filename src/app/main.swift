import AppKit

// CEF needs its own NSApplication subclass in place before any UI exists.
ChaEngine.installApplication()

let launcher = Launcher()
ChaEngine.shared.delegate = launcher

guard ChaEngine.shared.start(withArgc: CommandLine.argc, argv: CommandLine.unsafeArgv)
else {
    exit(1)
}

ChaEngine.shared.run()
launcher.controller?.save()
ChaEngine.shared.shutdown()

final class Launcher: NSObject, ChaEngineDelegate {
    var controller: BrowserController?

    func engineDidInitialize() {
        let controller = BrowserController()
        self.controller = controller
        NSApp.mainMenu = MainMenu.build(controller: controller)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow()
        if let scenario = ProcessInfo.processInfo.environment["CHA_TEST"] {
            TestScenarios.run(scenario, controller: controller)
        }
    }
}
