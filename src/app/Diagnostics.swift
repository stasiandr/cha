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

    // Don't take focus from whoever is at the Mac.
    static var quiet: Bool { headless || screenIndex != nil }

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

// The main window. In headless mode it may sit outside every screen, which
// AppKit otherwise corrects.
final class BrowserWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Off screen (headless) or on a chosen display (CHA_SCREEN): the
        // frame stands as set, not pulled back onto the main display.
        Diagnostics.quiet ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    // Arc sets the traffic lights lower and further in than AppKit does, on
    // the same line as the sidebar's first row: the close button's centre is
    // 19 pt from the left and 22 pt from the top (measured on the user's Arc,
    // macOS 26+ buttons). AppKit puts them back on every titlebar layout, so
    // this runs after resizes, full screen and appearance changes.
    static let trafficLightCenter = NSPoint(x: 19, y: 22)
    private var buttonSpacing: CGFloat?

    // Hidden in full screen and while the sidebar is hidden, as in Arc; the
    // page then has the whole window.
    var trafficLightsHidden = false {
        didSet { placeTrafficLights() }
    }

    func placeTrafficLights() {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { standardWindowButton($0) }
        guard buttons.count == 3, let titlebar = buttons[0].superview,
            let container = titlebar.superview
        else { return }
        for button in buttons { button.isHidden = trafficLightsHidden }
        guard !styleMask.contains(.fullScreen) else { return }
        // Their own spacing (it changed between macOS versions), taken once
        // from where AppKit first put them.
        let spacing = buttonSpacing ?? (buttons[1].frame.minX - buttons[0].frame.minX)
        buttonSpacing = spacing

        // The titlebar stays AppKit's (32 pt): a button centred 22 pt down
        // still fits. Positions are worked out in the window's coordinates,
        // then carried into the titlebar's.
        guard let content = contentView else { return }
        let height = content.bounds.height
        placing = true
        defer { placing = false }
        for (index, button) in buttons.enumerated() {
            let size = button.frame.size
            let centre = NSPoint(
                x: Self.trafficLightCenter.x + CGFloat(index) * spacing,
                y: height - Self.trafficLightCenter.y)
            let local = titlebar.convert(centre, from: nil)
            let origin = NSPoint(
                x: (local.x - size.width / 2).rounded(), y: (local.y - size.height / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        watch(buttons)
        _ = container
    }

    // AppKit moves the buttons back on its own titlebar layouts, which don't
    // all pass through this window; each move is undone as it happens.
    private var placing = false
    private var watched = false
    private func watch(_ buttons: [NSButton]) {
        guard !watched else { return }
        watched = true
        for button in buttons {
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: .main
            ) { [weak self] _ in
                guard let self, !self.placing else { return }
                self.placeTrafficLights()
            }
        }
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        placeTrafficLights()
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
