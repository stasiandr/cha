import AppKit
import CommonCrypto
import SwiftUI

// Chrome extensions, as Arc has them: installed from the Chrome Web Store
// (its link, or the extension's ID), kept unpacked in the profile's
// Extensions/<id>, loaded by Chromium at launch (ChaEngine passes them as
// --load-extension). A new or removed one takes effect after a restart,
// which the window offers. Chromium's own chrome://extensions shows their
// options and permissions.
struct InstalledExtension: Identifiable, Equatable {
    var id: String  // The folder's name: the Web Store ID.
    var name: String
    var version: String
    var path: URL
}

final class ExtensionStore: ObservableObject {
    static let shared = ExtensionStore()

    static var directory: URL {
        let dir = Persistence.directory.appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where a CRX comes from; replaced by the checks (a local server).
    static var crxURL: (String) -> URL? = { id in
        URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=152.0.0.0"
            + "&acceptformat=crx3&x=id%3D\(id)%26installsource%3Dondemand%26uc")
    }

    @Published private(set) var installed: [InstalledExtension] = []
    @Published var busy = false
    @Published var message = ""
    /// Installed or removed since launch: a restart turns the change on.
    @Published var needsRestart = false

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        installed = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            var name = manifest["name"] as? String ?? dir.lastPathComponent
            if name.hasPrefix("__MSG_") { name = Self.localized(name, in: dir, manifest: manifest) }
            return InstalledExtension(id: dir.lastPathComponent, name: name,
                                      version: manifest["version"] as? String ?? "", path: dir)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// "__MSG_appName__" from _locales/<default or en>/messages.json.
    static func localized(_ key: String, in dir: URL, manifest: [String: Any]) -> String {
        let id = key.dropFirst(6).dropLast(2).lowercased()
        let locale = manifest["default_locale"] as? String ?? "en"
        for name in [locale, "en", "en_US"] {
            let file = dir.appendingPathComponent("_locales/\(name)/messages.json")
            guard let data = try? Data(contentsOf: file),
                let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for (k, v) in messages where k.lowercased() == id {
                if let text = (v as? [String: Any])?["message"] as? String { return text }
            }
        }
        return dir.lastPathComponent
    }

    /// The 32-letter ID in a Web Store link ("…/detail/name/<id>") or alone.
    static func extensionID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: "[a-p]{32}", options: .regularExpression) else { return nil }
        return String(text[range])
    }

    func install(_ input: String, done: ((Bool) -> Void)? = nil) {
        guard let id = Self.extensionID(from: input), let url = Self.crxURL(id) else {
            message = "That is not a Chrome Web Store link or extension ID."
            done?(false)
            return
        }
        busy = true
        message = "Installing…"
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            let result = data.flatMap { Self.unpack($0, id: id) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if let result, result {
                    self.reload()
                    self.needsRestart = true
                    let name = self.installed.first { $0.id == id }?.name ?? id
                    self.message = "\(name) is installed. Restart cha to turn it on."
                    done?(true)
                } else {
                    self.message = "Could not install it" + (error.map { ": \($0.localizedDescription)" } ?? ".")
                    done?(false)
                }
            }
        }.resume()
    }

    /// A CRX3 file is "Cr24", a version, a header length, the header, then a
    /// zip: the zip is unpacked into Extensions/<id>.
    static func unpack(_ crx: Data, id: String) -> Bool {
        let bytes = [UInt8](crx)
        guard bytes.count > 12, bytes[0..<4] == [0x43, 0x72, 0x32, 0x34] else { return false }
        let version = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        let headerSize = Int(UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24)
        let start: Int
        var publicKey: Data?
        if version == 3 {
            start = 12 + headerSize
            if start <= bytes.count { publicKey = Self.publicKey(in: Array(bytes[12..<start]), for: id) }
        } else if version == 2, bytes.count > 16 {
            let signature = Int(UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24)
            start = 16 + headerSize + signature  // CRX2: key and signature lengths.
        } else {
            return false
        }
        guard start < bytes.count else { return false }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cha-crx-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent("ext.zip")
        let out = work.appendingPathComponent("out")
        guard (try? Data(bytes[start...]).write(to: zip)) != nil else { return false }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, out.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        guard (try? ditto.run()) != nil else { return false }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0, fm.fileExists(atPath: out.appendingPathComponent("manifest.json").path)
        else { return false }
        // Chromium won't load an unpacked extension carrying Web Store
        // metadata folders it can't verify.
        try? fm.removeItem(at: out.appendingPathComponent("_metadata"))
        // The Web Store's key in the manifest gives the unpacked extension the
        // same ID as in the store (its pages, its storage).
        if let publicKey {
            let manifestURL = out.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL),
                var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any], manifest["key"] == nil
            {
                manifest["key"] = publicKey.base64EncodedString()
                if let edited = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
                    try? edited.write(to: manifestURL)
                }
            }
        }
        let target = directory.appendingPathComponent(id)
        try? fm.removeItem(at: target)
        return (try? fm.moveItem(at: out, to: target)) != nil
    }

    /// The CRX3 header (a protobuf) holds RSA proofs, each with a public key
    /// (field 2 → field 1); the one whose SHA-256 gives the ID is the store's.
    static func publicKey(in header: [UInt8], for id: String) -> Data? {
        for proof in protoFields(header) where proof.field == 2 {
            for item in protoFields(proof.bytes) where item.field == 1 {
                let key = Data(item.bytes)
                if extensionID(of: key) == id { return key }
            }
        }
        return nil
    }

    /// Chromium's extension ID: the first 16 bytes of SHA-256, as a-p.
    static func extensionID(of key: Data) -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        key.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(key.count), &digest) }
        let letters = Array("abcdefghijklmnop")
        return String(digest.prefix(16).flatMap { [letters[Int($0 >> 4)], letters[Int($0 & 15)]] })
    }

    /// Length-delimited fields of a protobuf message (the only kind used here).
    private static func protoFields(_ bytes: [UInt8]) -> [(field: Int, bytes: [UInt8])] {
        var fields: [(Int, [UInt8])] = []
        var i = 0
        func varint() -> Int? {
            var value = 0, shift = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                value |= Int(b & 0x7f) << shift
                if b & 0x80 == 0 { return value }
                shift += 7
                if shift > 56 { return nil }
            }
            return nil
        }
        while i < bytes.count {
            guard let tag = varint() else { break }
            let field = tag >> 3, wire = tag & 7
            switch wire {
            case 0: guard varint() != nil else { return fields }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let length = varint(), length >= 0, i + length <= bytes.count else { return fields }
                fields.append((field, Array(bytes[i..<i + length])))
                i += length
            default: return fields
            }
        }
        return fields
    }

    /// Pages of the extension that cha can open: its toolbar popup and
    /// options, as chrome-extension:// addresses.
    func pages(of ext: InstalledExtension) -> (popup: String?, options: String?) {
        guard let data = try? Data(contentsOf: ext.path.appendingPathComponent("manifest.json")),
            let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        let popup = action?["default_popup"] as? String
        let options = (manifest["options_ui"] as? [String: Any])?["page"] as? String ?? manifest["options_page"] as? String
        let base = "chrome-extension://\(ext.id)/"
        return (popup.map { base + $0 }, options.map { base + $0 })
    }

    func remove(_ ext: InstalledExtension) {
        try? FileManager.default.removeItem(at: ext.path)
        reload()
        needsRestart = true
        message = "\(ext.name) is removed. Restart cha to finish."
    }
}

extension BrowserController {
    func openExtensions() {
        let panel = extensionsPanel ?? {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Extensions"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: ExtensionsWindow(controller: self, store: .shared))
            return panel
        }()
        extensionsPanel = panel
        if let frame = window?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        if Diagnostics.quiet { panel.orderFront(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    /// On a Web Store page: install the extension it shows.
    func installExtensionFromPage() {
        guard let url = activeTab?.currentURL, url.contains("chromewebstore.google.com") || url.contains("chrome.google.com/webstore"),
            ExtensionStore.extensionID(from: url) != nil
        else {
            openExtensions()
            return
        }
        openExtensions()
        ExtensionStore.shared.install(url)
    }

    /// Quits and opens cha again: a restart that turns extensions on or off.
    func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

struct ExtensionsWindow: View {
    @ObservedObject var controller: BrowserController
    @ObservedObject var store: ExtensionStore
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Chrome Web Store link or extension ID", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(install)
                Button("Install", action: install).disabled(store.busy || input.isEmpty)
            }
            if !store.message.isEmpty {
                Text(store.message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            List {
                ForEach(store.installed) { ext in
                    HStack {
                        Image(systemName: "puzzlepiece.extension")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ext.name).font(.system(size: 13, weight: .medium))
                            Text("\(ext.version) · \(ext.id)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let pages = store.pages(of: ext)
                        if let popup = pages.popup {
                            Button("Open") { controller.openLittleWindow(popup) }
                                .help("Its toolbar popup, in a little window")
                        }
                        if let options = pages.options {
                            Button("Options") { controller.newTab(url: options) }
                        }
                        Button("Remove") { store.remove(ext) }
                    }
                }
            }
            .overlay {
                if store.installed.isEmpty {
                    Text("No extensions yet. Paste a link from chromewebstore.google.com.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Options and Permissions…") { controller.newTab(url: "chrome://extensions/") }
                Button("Open the Web Store") { controller.newTab(url: "https://chromewebstore.google.com/") }
                Spacer()
                if store.needsRestart {
                    Button("Restart cha") { controller.relaunch() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 300)
    }

    private func install() {
        store.install(input) { ok in if ok { input = "" } }
    }
}
