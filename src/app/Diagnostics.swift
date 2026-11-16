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
