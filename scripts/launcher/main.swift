// cha launcher: opens the browser built from what is on disk right now.
//
// hop, Dock and Finder open this instead of build/cha.app. It compares the
// source stamp (scripts/source-stamp) with the one scripts/bundle.sh recorded:
// equal — opens cha right away; different — shows a window with the build's
// progress, rebuilds and opens the fresh app.
//
// If cha is already running the launcher only brings it forward: rebuilding
// would close every open tab; the fresh build is picked up on the next launch.
//
// Built by scripts/build-launcher.sh, which puts the repository path into
// Info.plist. Same design as Pilot's and Nest's launchers.

import AppKit

let chaBundleID = "dev.stasiandr.cha"

// CHA_* variables given to the launcher go on to cha, so a check can run the
// whole path off screen (CHA_HEADLESS, CHA_PROFILE); with CHA_HEADLESS the
// launcher shows no window of its own either and logs to stderr instead.
let passedEnvironment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("CHA_") }
let headless = !(passedEnvironment["CHA_HEADLESS"] ?? "").isEmpty

func note(_ text: String) {
    if headless { FileHandle.standardError.write(("LAUNCHER " + text + "\n").data(using: .utf8)!) }
}

final class Launcher: NSObject, NSApplicationDelegate {
    let repo: URL
    var chaApp: URL { repo.appendingPathComponent("build/cha.app") }
    var stampFile: URL { repo.appendingPathComponent("build/cha.stamp") }
    var log: URL { repo.appendingPathComponent("build/launcher-build.log") }

    var build: Process?
    var started = Date()
    var lastLine = ""
    var output = ""

    var window: NSWindow?
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let primary = NSButton()
    let secondary = NSButton()
    var timer: Timer?

    override init() {
        let path = Bundle.main.object(forInfoDictionaryKey: "ChaRepo") as? String ?? ""
        repo = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        decide()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        build?.terminate()
    }

    // MARK: - Deciding

    func decide() {
        // Another profile (CHA_PROFILE, the checks) is another instance: the
        // one already running belongs to the real profile and stays as it is.
        let ownProfile = passedEnvironment["CHA_PROFILE"] == nil
        if ownProfile,
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: chaBundleID).first
        {
            // A quitting cha leaves the Dock at once (it hides its windows,
            // then writes the profile out for a few seconds): bringing it
            // forward would show nothing, so wait for it to go and open a
            // fresh one. Windows on screen tell nothing: cha in full screen or
            // on another desktop has none on this one.
            if running.activationPolicy == .regular {
                note("already running: bringing it forward")
                if headless {
                    NSApp.terminate(nil)
                } else {
                    bringForward(running)
                }
                return
            }
            note("running but quitting: waiting for it to end")
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(20)
                while !running.isTerminated, Date() < deadline { usleep(100_000) }
                DispatchQueue.main.async { self.decide() }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let current = self.currentStamp()
            let built = (try? String(contentsOf: self.stampFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                note("stamp built=\(built ?? "-") now=\(current ?? "-")")
                if let current, current == built, FileManager.default.fileExists(atPath: self.chaApp.path) {
                    self.launchCha()
                } else {
                    self.startBuild(reason: built == nil ? "cha ещё не собран" : "Код изменился")
                }
            }
        }
    }

    func currentStamp() -> String? {
        let process = Process()
        process.executableURL = repo.appendingPathComponent("scripts/source-stamp")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Building

    /// How long a build usually takes, from previous ones; a guess for the first.
    var estimate: TimeInterval {
        let saved = UserDefaults.standard.double(forKey: "buildSeconds")
        return saved > 0 ? saved : 60
    }

    func startBuild(reason: String) {
        title.stringValue = "\(reason) — собираю свежий cha"
        showWindow()
        detail.stringValue = "Запускаю scripts/bundle.sh…"
        bar.doubleValue = 0
        primary.isHidden = true
        secondary.title = "Отмена"
        secondary.action = #selector(cancel)

        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: log)

        let process = Process()
        // A login shell for the user's PATH (mise, tuist): apps opened from
        // Finder or hop only get /usr/bin:/bin.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec scripts/bundle.sh"]
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            logHandle?.write(data)
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self.consume(text) }
        }
        process.terminationHandler = { process in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? logHandle?.close()
                self.finished(status: process.terminationStatus, reason: process.terminationReason)
            }
        }
        started = Date()
        build = process
        do {
            try process.run()
        } catch {
            failed("Не запустился bundle.sh: \(error.localizedDescription)")
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func consume(_ text: String) {
        output += text
        if output.count > 200_000 { output = String(output.suffix(100_000)) }
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let last = lines.last { lastLine = last }
        tick()
    }

    func tick() {
        let elapsed = Date().timeIntervalSince(started)
        // Linear up to the estimate, then creeping towards the end without reaching it.
        let fraction = elapsed < estimate * 0.9
            ? elapsed / estimate
            : 0.9 + 0.09 * (1 - exp(-(elapsed - estimate * 0.9) / estimate))
        bar.doubleValue = fraction * 100
        let line = lastLine.count > 70 ? String(lastLine.prefix(70)) + "…" : lastLine
        detail.stringValue = "\(clock(elapsed)) из ~\(clock(estimate))   \(line)"
    }

    func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    func finished(status: Int32, reason: Process.TerminationReason) {
        timer?.invalidate()
        build = nil
        if reason == .uncaughtSignal { return }  // Cancelled.
        guard status == 0 else {
            let errors = output.split(separator: "\n")
                .filter { $0.contains("error:") }
                .suffix(6)
                .joined(separator: "\n")
            failed(errors.isEmpty ? String(output.suffix(600)) : errors)
            return
        }
        // Averaged with the previous one so a single clean build doesn't skew it.
        let took = Date().timeIntervalSince(started)
        let saved = UserDefaults.standard.double(forKey: "buildSeconds")
        UserDefaults.standard.set(saved > 0 ? (saved + took) / 2 : took, forKey: "buildSeconds")
        bar.doubleValue = 100
        launchCha()
    }

    func failed(_ message: String) {
        showWindow()
        title.stringValue = "cha не собрался"
        detail.stringValue = message
        detail.maximumNumberOfLines = 8
        detail.lineBreakMode = .byTruncatingTail
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.isSelectable = true
        bar.isHidden = true
        primary.isHidden = false
        primary.title = "Открыть лог"
        primary.action = #selector(openLog)
        if FileManager.default.fileExists(atPath: chaApp.appendingPathComponent("Contents/MacOS/cha").path) {
            secondary.title = "Открыть прежнюю сборку"
            secondary.action = #selector(openOld)
        } else {
            secondary.title = "Закрыть"
            secondary.action = #selector(cancel)
        }
        window?.setContentSize(NSSize(width: 520, height: 240))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func cancel() {
        build?.terminate()
        NSApp.terminate(nil)
    }

    @objc func openLog() {
        NSWorkspace.shared.open(log)
    }

    @objc func openOld() {
        launchCha()
    }

    // MARK: - Opening cha

    /// Through LaunchServices, like a click in the Dock: it switches to the
    /// desktop or full screen cha is on and isn't refused the way
    /// NSRunningApplication.activate() is for an app that isn't frontmost.
    func bringForward(_ running: NSRunningApplication) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: running.bundleURL ?? chaApp, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func launchCha() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !headless
        configuration.createsNewApplicationInstance = passedEnvironment["CHA_PROFILE"] != nil
        configuration.environment = passedEnvironment
        note("opening \(chaApp.path)")
        NSWorkspace.shared.openApplication(at: chaApp, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.failed("cha не открылся: \(error.localizedDescription)")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - Window

    func showWindow() {
        if headless {
            note("window: \(title.stringValue)")
            return
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 132),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "cha"
        window.isReleasedWhenClosed = false

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        for button in [primary, secondary] {
            button.bezelStyle = .rounded
            button.target = self
        }
        secondary.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [NSView(), primary, secondary])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, bar, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        for view in [bar, detail, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }

        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let launcher = Launcher()
app.delegate = launcher
app.setActivationPolicy(.accessory)
app.run()
