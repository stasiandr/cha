import AppKit
import SwiftUI

// Sync between Macs, as Arc Sync: spaces (name, icon, colour), their pinned
// tabs and folders, and the favourites. Today's tabs, the secret space and
// history stay on each Mac. It goes through cloudsync (sync.stasiandr.com),
// end to end encrypted: the server sees ciphertext only. Each Mac has its
// own key; the first one starts a sync space, the others are added to it by
// their code ("cs1:…"), pasted on a Mac already in.
//
// Records: "cha.space" (one per space, its id) and "cha.favorites" ("all").
// The newer record wins; what this Mac applied is not sent back.
struct SpaceSnapshot: Codable, Equatable {
    // No page title: each Mac has its own as pages load, and sending those
    // back and forth would never settle.
    struct Tab: Codable, Equatable {
        var id: UUID
        var url: String
        var customTitle: String?
        var folderID: UUID?
        var pinnedURL: String?
    }
    var name: String
    var symbol: String
    var theme: SpaceTheme
    var pinned: [Tab]
    var folders: [FolderData]
    var order: Int
}

struct FavoritesSnapshot: Codable, Equatable {
    var tabs: [SpaceSnapshot.Tab]
}

final class SyncState: ObservableObject {
    static let shared = SyncState()
    @Published var status = "Off"
    @Published var on = false
    @Published var deviceCode = ""
    @Published var members = 0
    @Published var warnings: [String] = []
    @Published var waitingToJoin = false
}

#if CHA_SYNC
final class ChaSync {
    static var serverURL: String {
        ProcessInfo.processInfo.environment["CHA_SYNC_URL"] ?? "https://sync.stasiandr.com"
    }

    private let identityFile = Persistence.directory.appendingPathComponent("sync-identity")
    private let stateFile = Persistence.directory.appendingPathComponent("sync.json")
    private struct Saved: Codable {
        var space: String?
        var sent: [String: String] = [:]  // record key → payload last sent or applied
        var applied: [String: Int64] = [:]  // record key → updatedAt applied
    }

    private var saved = Saved()
    private var client: SyncClient?
    private weak var controller: BrowserController?
    private var pushWork: DispatchWorkItem?
    private var pulling = false
    let state = SyncState.shared

    init(controller: BrowserController) {
        self.controller = controller
        if let data = try? Data(contentsOf: stateFile), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = s
        }
        if let secret = try? Data(contentsOf: identityFile) {
            client = try? SyncClient(baseUrl: Self.serverURL, identitySecret: secret)
            state.deviceCode = client?.deviceCode() ?? ""
        }
        if saved.space != nil { start() } else if client != nil { waitToJoin() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: stateFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
    }

    /// This Mac's key, made once.
    private func ensureClient() -> SyncClient? {
        if let client { return client }
        let secret = generateIdentity()
        FileManager.default.createFile(atPath: identityFile.path, contents: secret, attributes: [.posixPermissions: 0o600])
        client = try? SyncClient(baseUrl: Self.serverURL, identitySecret: secret)
        state.deviceCode = client?.deviceCode() ?? ""
        return client
    }

    /// The first Mac: a new sync space with what is here.
    func startNew() {
        guard let client = ensureClient() else { return }
        state.status = "Starting…"
        Task { @MainActor in
            do {
                saved.space = try await client.createSpace()
                persist()
                start()
                schedulePush(now: true)
            } catch {
                state.status = "Could not start: \(error)"
            }
        }
    }

    /// Another Mac: show this Mac's code, and join once a Mac in the sync
    /// space has added it.
    func waitToJoin() {
        guard let client = ensureClient(), saved.space == nil else { return }
        state.waitingToJoin = true
        state.status = "Waiting to be added from a Mac already syncing"
        Task { @MainActor in
            while saved.space == nil, state.waitingToJoin {
                if let id = try? await client.spaces().first, let space = try? await client.join(spaceId: id) {
                    saved.space = space
                    persist()
                    state.waitingToJoin = false
                    start()
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// On a Mac already in: add another by its code.
    func addMac(code: String) async -> String {
        guard let client, let space = saved.space else { return "Sync is off here." }
        do {
            saved.space = try await client.addDevice(spaceJson: space, deviceCode: code.trimmingCharacters(in: .whitespacesAndNewlines), role: "member")
            persist()
            refreshMembers()
            return "Added. That Mac joins in a moment."
        } catch {
            return "Could not add it: \(error)"
        }
    }

    func turnOff() {
        state.waitingToJoin = false
        saved = Saved()
        persist()
        state.on = false
        state.status = "Off"
    }

    private func start() {
        state.on = true
        state.status = "On"
        refreshMembers()
        pullLoop()
    }

    private func refreshMembers() {
        guard let space = saved.space else { return }
        state.members = (try? spaceMembers(spaceJson: space).count) ?? 0
    }

    /// One spelling of a JSON value, whoever wrote it: sorted keys, no
    /// escaped slashes, compact.
    static func canonical(_ json: String) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return json }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Out

    func schedulePush(now: Bool = false) {
        guard saved.space != nil else { return }
        pushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.push() }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 2), execute: work)
    }

    private func records() -> [SyncRecord] {
        guard let c = controller else { return [] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        var out: [SyncRecord] = []
        func tab(_ t: TabData) -> SpaceSnapshot.Tab {
            .init(id: t.id, url: t.pinnedURL ?? t.url, customTitle: t.customTitle, folderID: t.folderID, pinnedURL: t.pinnedURL)
        }
        for (order, space) in c.visibleSpaces.enumerated() {
            let snap = SpaceSnapshot(name: space.name, symbol: space.symbol, theme: space.theme,
                                     pinned: space.pinnedTabs.map(tab), folders: space.folders, order: order)
            if let json = try? encoder.encode(snap) {
                out.append(SyncRecord(collection: "cha.space", id: space.id.uuidString, kind: "cha.space",
                                      payloadJson: String(decoding: json, as: UTF8.self), updatedAt: stamp, deletedAt: nil))
            }
        }
        if let json = try? encoder.encode(FavoritesSnapshot(tabs: c.favorites.map(tab))) {
            out.append(SyncRecord(collection: "cha.favorites", id: "all", kind: "cha.favorites",
                                  payloadJson: String(decoding: json, as: UTF8.self), updatedAt: stamp, deletedAt: nil))
        }
        // Spaces sent before and gone now: deleted.
        let present = Set(out.map { $0.collection + "/" + $0.id })
        for key in saved.sent.keys where key.hasPrefix("cha.space/") && !present.contains(key) && saved.sent[key] != "" {
            out.append(SyncRecord(collection: "cha.space", id: String(key.dropFirst(10)), kind: "cha.space",
                                  payloadJson: "null", updatedAt: stamp, deletedAt: stamp))
        }
        return out
    }

    private func push() {
        guard let client, let space = saved.space else { return }
        let changed = records().filter { record in
            let key = record.collection + "/" + record.id
            let body = record.deletedAt == nil ? Self.canonical(record.payloadJson) : ""
            return saved.sent[key] != body
        }
        guard !changed.isEmpty else { return }
        Task { @MainActor in
            do {
                saved.space = try await client.put(spaceJson: space, records: changed)
                for r in changed {
                    let key = r.collection + "/" + r.id
                    saved.sent[key] = r.deletedAt == nil ? Self.canonical(r.payloadJson) : ""
                    saved.applied[key] = r.updatedAt
                }
                persist()
                state.status = "On · sent \(Date().formatted(date: .omitted, time: .shortened))"
            } catch {
                state.status = "Could not send: \(error)"
            }
        }
    }

    // MARK: In

    private func pullLoop() {
        guard !pulling else { return }
        pulling = true
        Task { @MainActor in
            while let space = saved.space, let client {
                do {
                    let result = try await client.pull(spaceJson: space, collection: nil, waitSeconds: 20)
                    if saved.space == nil { break }
                    saved.space = result.spaceJson
                    if !result.warnings.isEmpty { state.warnings = result.warnings }
                    apply(result.records)
                    persist()
                    refreshMembers()
                } catch {
                    state.status = "Offline, trying again"
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            pulling = false
        }
    }

    private func apply(_ records: [SyncRecord]) {
        guard let c = controller else { return }
        let decoder = JSONDecoder()
        var changed = false
        for r in records {
            let key = r.collection + "/" + r.id
            guard r.updatedAt > saved.applied[key] ?? 0 else { continue }
            saved.applied[key] = r.updatedAt
            saved.sent[key] = r.deletedAt == nil ? Self.canonical(r.payloadJson) : ""
            if r.collection == "cha.space", let id = UUID(uuidString: r.id) {
                if r.deletedAt != nil {
                    if c.space(id) != nil, c.visibleSpaces.count > 1 { c.deleteSpace(id, confirm: false) }
                } else if let snap = try? decoder.decode(SpaceSnapshot.self, from: Data(r.payloadJson.utf8)) {
                    c.applySynced(space: id, snap)
                }
                changed = true
            } else if r.collection == "cha.favorites",
                let snap = try? decoder.decode(FavoritesSnapshot.self, from: Data(r.payloadJson.utf8))
            {
                c.applySynced(favorites: snap)
                changed = true
            }
        }
        if changed { state.status = "On · received \(Date().formatted(date: .omitted, time: .shortened))" }
    }
}
#endif

extension BrowserController {
    /// A space as another Mac has it: its pinned tabs and folders replaced,
    /// today's tabs kept; a new one added.
    func applySynced(space id: UUID, _ snap: SpaceSnapshot) {
        func tab(_ t: SpaceSnapshot.Tab, existing: TabData?) -> TabData {
            var data = existing ?? TabData(url: t.url, isPinned: true)
            data.isPinned = true
            data.customTitle = t.customTitle
            data.folderID = t.folderID
            data.pinnedURL = t.pinnedURL ?? t.url
            if existing == nil { data.id = t.id; data.url = t.url }
            return data
        }
        if var space = spaces.first(where: { $0.id == id }) {
            let old = Dictionary(space.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let pinned = snap.pinned.map { tab($0, existing: old[$0.id]) }
            let pinnedIDs = Set(pinned.map(\.id))
            space.tabs = pinned + space.tabs.filter { !$0.isPinned && !pinnedIDs.contains($0.id) }
            space.name = snap.name
            space.symbol = snap.symbol
            space.theme = snap.theme
            space.folders = snap.folders
            for gone in old.values where gone.isPinned && !pinnedIDs.contains(gone.id) { unload(gone.id) }
            replace(space)
        } else {
            var space = SpaceData(id: id, name: snap.name, symbol: snap.symbol, theme: snap.theme)
            space.tabs = snap.pinned.map { tab($0, existing: nil) }
            space.folders = snap.folders
            let index = min(snap.order, spaces.count)
            spaces.insert(space, at: index)
            scheduleSave()
        }
        if id == activeSpaceID { applySpaceTint(animated: false) }
    }

    func applySynced(favorites snap: FavoritesSnapshot) {
        let old = Dictionary(favorites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        favorites = snap.tabs.map { t in
            var data = old[t.id] ?? TabData(url: t.url, isPinned: true)
            data.id = t.id
            data.customTitle = t.customTitle
            data.pinnedURL = t.pinnedURL ?? t.url
            return data
        }
        for gone in old.keys where !favorites.contains(where: { $0.id == gone }) { unload(gone) }
        scheduleSave()
    }

    func openSync() {
        let panel = syncPanel ?? {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Sync"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: SyncWindow(controller: self, state: .shared))
            return panel
        }()
        syncPanel = panel
        if let frame = window?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        if Diagnostics.quiet { panel.orderFront(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }
}

struct SyncWindow: View {
    @ObservedObject var controller: BrowserController
    @ObservedObject var state: SyncState
    @State private var code = ""
    @State private var addResult = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spaces, their pinned tabs and folders, and favourites, on every Mac you add. End-to-end encrypted through sync.stasiandr.com; today's tabs and history stay on each Mac.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Status:").font(.system(size: 12, weight: .medium))
                Text(state.status + (state.on && state.members > 0 ? " · \(state.members) Mac\(state.members == 1 ? "" : "s")" : ""))
                    .font(.system(size: 12))
            }
            #if CHA_SYNC
            if !state.on {
                HStack {
                    Button("Start Sync on This Mac") { controller.sync?.startNew() }
                    Button("Join from Another Mac") { controller.sync?.waitToJoin() }
                }
                if state.waitingToJoin, !state.deviceCode.isEmpty {
                    codeView("On a Mac already syncing, open Sync and add this code:")
                }
            } else {
                HStack {
                    TextField("Another Mac's code (cs1:…)", text: $code).textFieldStyle(.roundedBorder)
                    Button("Add Mac") {
                        Task { addResult = await controller.sync?.addMac(code: code) ?? ""; code = "" }
                    }
                    .disabled(code.isEmpty)
                }
                if !addResult.isEmpty { Text(addResult).font(.system(size: 12)).foregroundStyle(.secondary) }
                codeView("This Mac's code:")
                Button("Turn Off Sync on This Mac") { controller.sync?.turnOff() }
            }
            ForEach(state.warnings, id: \.self) { Text("⚠︎ " + $0).font(.system(size: 11)).foregroundStyle(.orange) }
            #else
            Text("This build has no sync (cloudsync's bindings were not found when it was built).")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            #endif
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 260, alignment: .topLeading)
    }

    private func codeView(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12))
            HStack {
                Text(state.deviceCode).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Copy") {
                    BrowserController.clipboard.clearContents()
                    BrowserController.clipboard.setString(state.deviceCode, forType: .string)
                }
            }
        }
    }
}
