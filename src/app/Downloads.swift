import AppKit
import SwiftUI

// Downloads: CEF saves into ~/Downloads (ChaTab.mm) and reports progress as
// the ChaDownloadUpdated notification; this keeps the list (saved in the
// profile), and the sidebar shows it on ⇧⌘L, sliding up from the bottom bar
// as Arc's library does.
struct DownloadData: Codable, Identifiable, Equatable {
    var id = UUID()
    var sessionID: UInt32  // CEF's id, valid while cha runs.
    var url: String
    var name: String
    var path: String
    var received: Int64 = 0
    var total: Int64 = 0
    var state: String = "progress"  // progress, complete, canceled, interrupted
    var started = Date()

    var inProgress: Bool { state == "progress" }
    var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
}

final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()
    @Published private(set) var items: [DownloadData] = []

    private var fileURL: URL { Persistence.directory.appendingPathComponent("downloads.json") }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
            var saved = try? JSONDecoder().decode([DownloadData].self, from: data)
        {
            // A download cha was quit in the middle of did not finish.
            for index in saved.indices where saved[index].inProgress { saved[index].state = "interrupted" }
            items = saved
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ChaDownloadUpdated"), object: nil, queue: .main
        ) { [weak self] note in
            self?.update(note.userInfo ?? [:])
        }
    }

    var active: [DownloadData] { items.filter(\.inProgress) }

    // Bytes of all running downloads together, for the button's ring.
    var activeFraction: Double {
        let running = active
        let total = running.reduce(Int64(0)) { $0 + $1.total }
        guard total > 0 else { return 0 }
        return Double(running.reduce(Int64(0)) { $0 + $1.received }) / Double(total)
    }

    private func update(_ info: [AnyHashable: Any]) {
        guard let session = (info["id"] as? NSNumber)?.uint32Value else { return }
        let url = info["url"] as? String ?? ""
        var item = items.first { $0.sessionID == session && $0.url == url && $0.inProgress }
            ?? DownloadData(sessionID: session, url: url, name: "", path: "")
        item.name = info["name"] as? String ?? item.name
        item.path = info["path"] as? String ?? item.path
        item.received = (info["received"] as? NSNumber)?.int64Value ?? item.received
        item.total = (info["total"] as? NSNumber)?.int64Value ?? item.total
        item.state = info["state"] as? String ?? item.state
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
            NSLog("DOWNLOAD started %@", item.name)
        }
        if !item.inProgress {
            NSLog("DOWNLOAD %@ %@", item.state, item.path)
            save()
        }
    }

    func cancel(_ item: DownloadData) {
        ChaTab.cancelDownload(item.sessionID)
    }

    func remove(_ item: DownloadData) {
        items.removeAll { $0.id == item.id }
        save()
    }

    // Clear: finished ones leave the list (the files stay on disk).
    func clearFinished() {
        items.removeAll { !$0.inProgress }
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(items.filter { !$0.inProgress }) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension BrowserController {
    // Slides in from the left in the time a space switch takes. The spaces'
    // transition is chosen first, then the page changes on the next turn, so
    // the outgoing view already carries the slide.
    func toggleDownloads() {
        slidingToDownloads = true
        DispatchQueue.main.async { [self] in
            withAnimation(.easeOut(duration: Self.switchDuration)) {
                sidebarPage = sidebarPage == .downloads ? .tabs : .downloads
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.switchDuration + 0.05) {
                self.slidingToDownloads = false
            }
        }
    }
}

struct DownloadsView: View {
    @ObservedObject var controller: BrowserController
    @ObservedObject var store = DownloadStore.shared
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: UUID?

    var body: some View {
        let style = SidebarStyle(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    controller.toggleDownloads()
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to tabs (⇧⌘L)")
                Text("Downloads")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                if store.items.contains(where: { !$0.inProgress }) {
                    Button("Clear") { store.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 35)

            if store.items.isEmpty {
                Text("Files you download show up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                Spacer()
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.items) { item in row(item, style: style) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func row(_ item: DownloadData, style: SidebarStyle) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .frame(width: 26, height: 26)
                .opacity(item.state == "complete" ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name.isEmpty ? item.url : item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.inProgress {
                    ProgressView(value: item.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                }
                Text(subtitle(item))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.inProgress, hovered == item.id {
                Button {
                    store.cancel(item)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(style.card(active: false, hovered: hovered == item.id)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? item.id : nil }
        .onTapGesture {
            if item.state == "complete" { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) }
        }
        .onDrag {
            NSItemProvider(contentsOf: URL(fileURLWithPath: item.path)) ?? NSItemProvider()
        }
        .help(item.path)
        .contextMenu {
            if item.state == "complete" {
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                }
            }
            if item.inProgress { Button("Cancel") { store.cancel(item) } }
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
            Divider()
            Button("Remove from List") { store.remove(item) }
        }
    }

    private func subtitle(_ item: DownloadData) -> String {
        let format = ByteCountFormatter()
        switch item.state {
        case "progress":
            return item.total > 0
                ? "\(format.string(fromByteCount: item.received)) of \(format.string(fromByteCount: item.total))"
                : format.string(fromByteCount: item.received)
        case "complete":
            let gone = !FileManager.default.fileExists(atPath: item.path)
            return gone ? "Moved or deleted" : format.string(fromByteCount: max(item.total, item.received))
        case "canceled": return "Cancelled"
        default: return "Failed"
        }
    }
}

// The bottom bar's button: a ring fills while something downloads.
struct DownloadsButton: View {
    @ObservedObject var controller: BrowserController
    @ObservedObject var store = DownloadStore.shared

    var body: some View {
        ChromeButton(
            symbol: controller.sidebarPage == .downloads ? "arrow.down.circle.fill" : "arrow.down.circle",
            help: "Downloads (⇧⌘L)"
        ) {
            controller.toggleDownloads()
        }
        .overlay {
            if !store.active.isEmpty {
                Circle()
                    .trim(from: 0, to: max(0.04, store.activeFraction))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 20, height: 20)
                    .allowsHitTesting(false)
            }
        }
    }
}
