import AppKit

// Arc's Capture (⇧⌘2): drag over the page to take a picture of that part of
// it, or click for all of it; the picture goes to the clipboard ("Copied
// screenshot"). Esc lets it be. Chromium draws the page (DevTools'
// Page.captureScreenshot), so it is the page's own pixels, nothing over it.
extension BrowserController {
    func startCapture() {
        guard let window, activeTab != nil else {
            NSSound.beep()
            return
        }
        let overlay = CaptureOverlay(page: contentScreenRect) { [weak self] rect in
            self?.endCapture()
            if let rect { self?.capture(rect) }
        }
        captureOverlay = overlay
        window.addChildWindow(overlay, ordered: .above)
        if Diagnostics.quiet { overlay.orderFront(nil) } else { overlay.makeKeyAndOrderFront(nil) }
        NSCursor.crosshair.push()
    }

    func endCapture() {
        guard let overlay = captureOverlay else { return }
        NSCursor.pop()
        overlay.parent?.removeChildWindow(overlay)
        overlay.orderOut(nil)
        captureOverlay = nil
    }

    /// Takes the part of the page under |rect| (screen points; all of it
    /// when the rect is tiny) and puts it on the clipboard.
    func capture(_ rect: NSRect, done: ((NSImage?) -> Void)? = nil) {
        guard let id = activeTabID, let tab = liveTabs[id], let pageFrame = tab.nativeWindow?.frame else {
            done?(nil)
            return
        }
        tab.captureVisiblePage { [weak self] png in
            guard let self, let png, let full = NSBitmapImageRep(data: png) else {
                done?(nil)
                return
            }
            var area = rect.intersection(pageFrame)
            if area.width < 4 || area.height < 4 { area = pageFrame }
            // Screen points (origin bottom left) to the picture's pixels (top left).
            let scale = CGFloat(full.pixelsWide) / pageFrame.width
            let crop = CGRect(
                x: (area.minX - pageFrame.minX) * scale, y: (pageFrame.maxY - area.maxY) * scale,
                width: area.width * scale, height: area.height * scale
            ).integral
            guard let cg = full.cgImage?.cropping(to: crop) else {
                done?(nil)
                return
            }
            let picture = NSBitmapImageRep(cgImage: cg)
            let image = NSImage(size: area.size)
            image.addRepresentation(picture)
            BrowserController.clipboard.clearContents()
            if let data = picture.representation(using: .png, properties: [:]) {
                BrowserController.clipboard.setData(data, forType: .png)
            }
            BrowserController.clipboard.writeObjects([image])
            self.showToast("Copied screenshot", symbol: "camera.viewfinder")
            done?(image)
        }
    }
}

/// The page dimmed, the dragged rectangle clear; reports it on mouse up.
final class CaptureOverlay: NSPanel {
    private let finish: (NSRect?) -> Void
    private let view = CaptureView()

    init(page: NSRect, finish: @escaping (NSRect?) -> Void) {
        self.finish = finish
        super.init(contentRect: page, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        contentView = view
        view.done = { [weak self] rect in
            guard let self else { return }
            // From the view to the screen.
            finish(rect.map { self.convertToScreen($0) })
        }
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { finish(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) } else { super.keyDown(with: event) }
    }
}

final class CaptureView: NSView {
    var done: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        if let rect = selection {
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        } else {
            let hint = "Drag to take a picture of part of the page, click for all of it, Esc to cancel"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white,
            ]
            let size = hint.size(withAttributes: attributes)
            hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        done?(selection ?? .zero)
    }
}
