import AppKit
import SwiftUI

// Arc: with the sidebar hidden (⌘S), the pointer at the window's left edge
// slides the sidebar out over the page; it goes away when the pointer leaves
// it. It is the same sidebar, in a panel above the page's window.
extension BrowserController {
    static let peekEdge: CGFloat = 6

    /// Where the pointer is; replaced by the checks.
    static var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }

    /// Watches the pointer while the sidebar is hidden.
    func startSidebarPeekWatch() {
        guard sidebarPeekTimer == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.sidebarPeekTick() }
        RunLoop.main.add(timer, forMode: .common)
        sidebarPeekTimer = timer
    }

    func stopSidebarPeekWatch() {
        sidebarPeekTimer?.invalidate()
        sidebarPeekTimer = nil
        hideSidebarPeek()
    }

    func sidebarPeekTick() {
        guard !sidebarVisible, let window, window.isVisible else {
            hideSidebarPeek()
            return
        }
        let mouse = Self.mouseLocation()
        let frame = window.frame
        if let panel = sidebarPeek, panel.isVisible {
            // Gone once the pointer is well clear of it.
            if !panel.frame.insetBy(dx: -24, dy: -24).contains(mouse) { hideSidebarPeek() }
            return
        }
        let atEdge = mouse.x >= frame.minX - 1 && mouse.x <= frame.minX + Self.peekEdge
            && mouse.y >= frame.minY && mouse.y <= frame.maxY
        if atEdge { showSidebarPeek() }
    }

    func showSidebarPeek() {
        guard let window, !sidebarVisible else { return }
        let panel = sidebarPeek ?? makeSidebarPeek()
        sidebarPeek = panel
        let inset: CGFloat = 6
        let frame = NSRect(x: window.frame.minX + inset, y: window.frame.minY + inset,
                           width: sidebarWidth, height: window.frame.height - 2 * inset)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        // Off screen an animation only ends with the next event: no slide.
        guard !Diagnostics.headless else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            panel.orderFront(nil)
            return
        }
        panel.setFrame(frame.offsetBy(dx: -sidebarWidth / 3, dy: 0), display: true)
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hideSidebarPeek() {
        guard let panel = sidebarPeek, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    var sidebarPeekShown: Bool { sidebarPeek?.isVisible == true }

    private func makeSidebarPeek() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        let tint = NSHostingView(rootView: SidebarPeekBackground(controller: self))
        let sidebar = NSHostingView(rootView: SidebarView(controller: self))
        for view in [tint, sidebar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                view.topAnchor.constraint(equalTo: effect.topAnchor),
                view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
        }
        panel.contentView = effect
        return panel
    }
}

/// The space's colour under the peeking sidebar, as under the real one.
struct SidebarPeekBackground: View {
    @ObservedObject var controller: BrowserController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // As the window's tint (applySpaceTint), over the sidebar material.
        let tint = Color(controller.activeSpace.theme.color)
        let dark = scheme == .dark
        LinearGradient(colors: [tint.opacity(dark ? 0.42 : 0.50), tint.opacity(dark ? 0.20 : 0.26)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
