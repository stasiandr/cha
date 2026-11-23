import AppKit
import SwiftUI

// Arc's tab menu extras and its "Copied" toast.
extension BrowserController {
    /// Today's tabs shown under this one in the sidebar.
    func tabsBelow(_ id: UUID) -> [UUID] {
        guard let space = spaceContaining(id) else { return [] }
        let today = space.unpinnedTabs.map(\.id)
        guard let index = today.firstIndex(of: id) else { return [] }
        return Array(today[(index + 1)...])
    }

    func closeTabsBelow(_ id: UUID) {
        for tab in tabsBelow(id) { closeTab(tab) }
    }

    /// Every other of today's tabs in the space; pinned ones stay.
    func closeOtherTabs(_ id: UUID) {
        guard let space = spaceContaining(id) else { return }
        for tab in space.unpinnedTabs where tab.id != id { closeTab(tab.id) }
        activateTab(id)
    }

    /// A short note at the bottom of the page: "Copied", as Arc shows.
    func showToast(_ text: String, symbol: String = "checkmark.circle.fill") {
        toastText = text
        toastSymbol = symbol
        let shown = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.toastText == shown else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.toastText = nil }
        }
        let panel = toastPanel ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
            panel.contentView = NSHostingView(rootView: Toast(controller: self))
            return panel
        }()
        toastPanel = panel
        let page = contentScreenRect
        panel.setFrame(NSRect(x: page.midX - 140, y: page.minY + 18, width: 280, height: 44), display: true)
        if panel.parent == nil, let window { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }
}

struct Toast: View {
    @ObservedObject var controller: BrowserController

    var body: some View {
        ZStack {
            if let text = controller.toastText {
                HStack(spacing: 6) {
                    Image(systemName: controller.toastSymbol)
                    Text(text).font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.regularMaterial))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
