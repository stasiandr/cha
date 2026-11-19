import AppKit
import Darwin
import SwiftUI

// Launch and quit timing, plus the headless mode the checks run in.
enum Diagnostics {
    // CHA_HEADLESS=1: the windows live far off screen, the app never takes
    // focus and has no Dock icon, so a run does not get in the way of whoever
    // is using this Mac. Everything else behaves as usual.
    static let headless = !(ProcessInfo.processInfo.environment["CHA_HEADLESS"] ?? "").isEmpty

    // CHA_SCREEN=<n>: a real, visible window on display n (NSScreen.screens
    // order), for windowed checks on a second monitor while someone works on
    // the first: the app never activates, so focus stays where it was, and
    // audio is muted.
    static let screenIndex: Int? = {
        guard let index = ProcessInfo.processInfo.environment["CHA_SCREEN"].flatMap(Int.init)
        else { return nil }
        return index
    }()

    // The chosen display may be gone (unplugged, asleep). Then the run goes
    // off screen like a headless one rather than onto the display in use.
    static var screenMissing: Bool {
        guard let index = screenIndex else { return false }
        return index < 0 || index >= NSScreen.screens.count
    }

    // CHA_LOUD=1 with CHA_SCREEN: on that display, but behaving as a real
    // run does (it activates and takes focus), for checks of activation
    // itself, such as where a little window lands. Only when asked for.
    static let loud = !(ProcessInfo.processInfo.environment["CHA_LOUD"] ?? "").isEmpty

    // Don't take focus from whoever is at the Mac.
    static var quiet: Bool { headless || (screenIndex != nil && !loud) }

    static let offscreenOrigin = NSPoint(x: -30000, y: -30000)

    // Wall-clock time the kernel started this process, so marks include the
    // dyld and framework loading that happen before main().
    static let processStart: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return Date().timeIntervalSince1970
        }
        let start = info.kp_proc.p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }()

    private static var marked: Set<String> = []
    private static var waiters: [String: [() -> Void]] = [:]

    // Runs |body| once the mark |name| has been made (now, if it already was).
    static func after(_ name: String, _ body: @escaping () -> Void) {
        if marked.contains(name) { body() } else { waiters[name, default: []].append(body) }
    }

    // "TIMING <name> <ms since process start>" in the log, once per name.
    static func mark(_ name: String) {
        guard !marked.contains(name) else { return }
        marked.insert(name)
        let ms = (Date().timeIntervalSince1970 - processStart) * 1000
        let line = String(format: "TIMING %@ %.0f\n", name, ms)
        FileHandle.standardError.write(line.data(using: .utf8)!)
        for body in waiters.removeValue(forKey: name) ?? [] { body() }
    }
}

// Where links from other apps went (~/Library/Logs/cha/links.log, last
// 200 lines): placement on several displays is hard to see from tests.
extension Diagnostics {
    static func linkLog(_ line: String) {
        NSLog("LINK %@", line)
        fileLog("links.log", line)
    }

    // Every page closed and whether its browser went: a page heard after
    // its tab was closed shows up here.
    static func tabLog(_ line: String) {
        NSLog("TAB %@", line)
        fileLog("tabs.log", line)
    }

    // ~/Library/Logs/cha/<name>, its last 200 lines; not from checks.
    private static func fileLog(_ name: String, _ line: String) {
        guard !quiet else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/cha")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append(stamp + " " + line)
        try? lines.suffix(200).joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

extension ChaTab {
    // Closes the page and makes sure it went: one still there 3 s later
    // (it would go on playing, unseen) is logged and closed again.
    func end(_ why: String) {
        let url = currentURL
        Diagnostics.tabLog("close (\(why)) \(url)")
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.isClosed else { return }
            Diagnostics.tabLog("STILL OPEN 3 s after closing, again: \(url)")
            self.close()
        }
    }
}

// The main window. In headless mode it may sit outside every screen, which
// AppKit otherwise corrects.
final class BrowserWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Off screen (headless) or on a chosen display (CHA_SCREEN): the
        // frame stands as set, not pulled back onto the main display.
        // In full screen the window is the whole screen, menu bar's strip
        // included; AppKit would hold it to the visible frame below it.
        if Diagnostics.quiet || styleMask.contains(.fullScreen) { return frameRect }
        return super.constrainFrameRect(frameRect, to: screen)
    }

    static let trafficLightCenter = TrafficLights.center
    private lazy var lights = TrafficLights(self)

    // Hidden in full screen and while the sidebar is hidden, as in Arc; the
    // page then has the whole window.
    var trafficLightsHidden: Bool {
        get { lights.hidden }
        set { lights.hidden = newValue; placeTrafficLights() }
    }

    func placeTrafficLights() { lights.place() }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        placeTrafficLights()
    }
}

// The little window is a panel: only a panel may show over another app's
// full-screen desktop (a window, whatever its collection behaviour, stays
// on cha's own desktop of that display).
final class LittlePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if Diagnostics.quiet { return frameRect }
        return super.constrainFrameRect(frameRect, to: screen)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private lazy var lights = TrafficLights(self)
    func placeTrafficLights() { lights.place() }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        placeTrafficLights()
    }
}

// Arc sets the traffic lights lower and further in than AppKit does, on the
// same line as the sidebar's first row: the close button's centre is 19 pt
// from the left and 22 pt from the top (measured on the user's Arc, macOS 26+
// buttons). AppKit puts them back on every titlebar layout, so this runs
// after resizes, full screen and appearance changes.
final class TrafficLights {
    static let center = NSPoint(x: 19, y: 22)
    private weak var window: NSWindow?
    var hidden = false
    private var spacing: CGFloat?
    private var placing = false
    private var watched = false

    init(_ window: NSWindow) { self.window = window }

    func place() {
        guard let window else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3, let titlebar = buttons[0].superview else { return }
        for button in buttons { button.isHidden = hidden }
        guard !window.styleMask.contains(.fullScreen) else { return }
        // Their own spacing (it changed between macOS versions), taken once
        // from where AppKit first put them.
        let spacing = self.spacing ?? (buttons[1].frame.minX - buttons[0].frame.minX)
        self.spacing = spacing
        // The titlebar stays AppKit's (32 pt): a button centred 22 pt down
        // still fits. Positions are worked out in the window's coordinates,
        // then carried into the titlebar's.
        guard let content = window.contentView else { return }
        let height = content.bounds.height
        placing = true
        defer { placing = false }
        for (index, button) in buttons.enumerated() {
            let size = button.frame.size
            let centre = NSPoint(x: Self.center.x + CGFloat(index) * spacing, y: height - Self.center.y)
            let local = titlebar.convert(centre, from: nil)
            let origin = NSPoint(
                x: (local.x - size.width / 2).rounded(), y: (local.y - size.height / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        watch(buttons)
    }

    // AppKit moves the buttons back on its own titlebar layouts, which don't
    // all pass through the window; each move is undone as it happens.
    private func watch(_ buttons: [NSButton]) {
        guard !watched else { return }
        watched = true
        for button in buttons {
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: .main
            ) { [weak self] _ in
                guard let self, !self.placing else { return }
                self.place()
            }
        }
    }
}

// Where SwiftUI put things, for the UI checks to click and drag on. Only
// recorded in test runs (CHA_TEST set); keys like "tab:<uuid>".
enum UIFrames {
    static let enabled = ProcessInfo.processInfo.environment["CHA_TEST"] != nil
    static var frames: [String: CGRect] = [:]  // In the sidebar's coordinates.
}

struct UIFrameRecorder: ViewModifier {
    let key: String
    func body(content: Content) -> some View {
        if UIFrames.enabled {
            content.background(
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .global)
                    Color.clear
                        .onAppear { UIFrames.frames[key] = frame }
                        .onChange(of: frame) { _, new in UIFrames.frames[key] = new }
                        .onDisappear { UIFrames.frames[key] = nil }
                })
        } else {
            content
        }
    }
}

extension View {
    func uiFrame(_ key: String) -> some View { modifier(UIFrameRecorder(key: key)) }
}

extension NSRect {
    // Equal to within a point: frames come back rounded from Chromium.
    func isClose(to other: NSRect, tolerance: CGFloat = 1) -> Bool {
        abs(minX - other.minX) < tolerance && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}
