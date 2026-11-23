import AppKit
import SwiftUI

// Arc's Air Traffic Control: links from other apps go to the space they
// belong to. A rule says "a link containing figma.com opens in Work"; a link
// that matches one opens as a tab of that space, in the main window. The
// rest open in a little window as before. Kept in routing.json.
struct RouteRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var match = ""  // A piece of the address: a host, a path, anything in it.
    var spaceID: UUID

    func matches(_ url: String) -> Bool {
        let needle = match.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return false }
        return url.lowercased().contains(needle)
    }
}

final class RoutingStore: ObservableObject {
    static let shared = RoutingStore()
    @Published var rules: [RouteRule] = [] { didSet { save() } }
    private let file = Persistence.directory.appendingPathComponent("routing.json")

    init() {
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([RouteRule].self, from: data) {
            rules = list
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// The space for a link: the first rule that matches and whose space is
    /// still there (never the secret one).
    func space(for url: String, in spaces: [SpaceData]) -> UUID? {
        for rule in rules where rule.matches(url) {
            if spaces.contains(where: { $0.id == rule.spaceID && !$0.isSecret }) { return rule.spaceID }
        }
        return nil
    }
}

extension BrowserController {
    /// A link from another app: to its space by a rule, else a little window.
    func openFromOtherApp(_ url: String, over caller: NSRect?, callerWindow: Int?) {
        if let spaceID = RoutingStore.shared.space(for: url, in: spaces) {
            Diagnostics.linkLog("link routed to space \(space(spaceID)?.name ?? "?")")
            if spaceID != activeSpaceID { selectSpace(spaceID, animated: false) }
            newTab(url: url)
            showMainWindow()
            if !Diagnostics.quiet { NSApp.activate(ignoringOtherApps: true) }
        } else {
            openLittleWindow(url, over: caller, callerWindow: callerWindow)
        }
    }

    func openRoutingRules() {
        let panel = routingPanel ?? {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Route Links to Spaces"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: RoutingEditor(controller: self, store: .shared))
            return panel
        }()
        routingPanel = panel
        if let frame = window?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        if Diagnostics.quiet { panel.orderFront(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }
}

struct RoutingEditor: View {
    @ObservedObject var controller: BrowserController
    @ObservedObject var store: RoutingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Links from other apps that contain…").font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($store.rules) { $rule in
                        HStack(spacing: 8) {
                            TextField("figma.com", text: $rule.match).textFieldStyle(.roundedBorder)
                            Text("open in").font(.system(size: 12)).foregroundStyle(.secondary)
                            Picker("", selection: $rule.spaceID) {
                                ForEach(controller.visibleSpaces) { space in Text(space.name).tag(space.id) }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                            Button {
                                store.rules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Remove this rule")
                        }
                    }
                }
            }
            if store.rules.isEmpty {
                Text("No rules: every link opens in a little window.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Button("Add Rule") { store.rules.append(RouteRule(spaceID: controller.activeSpaceID)) }
                Spacer()
                Text("Others open in a little window.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 240, alignment: .topLeading)
    }
}
