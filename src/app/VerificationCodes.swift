import CryptoKit
import Foundation

// A TOTP secret — what the Passwords app calls a verification code. Keeping
// one here lets the browser type the code into the login form itself instead
// of the user copying it out of another app every time.
struct CodeEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String  // "Keycloak (stas)" — what the menu shows
    var site: String  // host this code fills on, empty until one is known
    var secret: String  // base32, as it comes out of an otpauth:// URI
    var algorithm: String = "SHA1"
    var digits: Int = 6
    var period: Int = 30

    var code: String? { code(at: Date()) }

    // RFC 6238: HMAC over the counter, then dynamic truncation.
    func code(at date: Date) -> String? {
        guard let key = base32Decode(secret), !key.isEmpty, digits > 0,
            digits <= 9, period > 0
        else { return nil }
        let counter = UInt64(date.timeIntervalSince1970 / Double(period))
        var message = counter.bigEndian
        let data = withUnsafeBytes(of: &message) { Data($0) }
        let key32 = SymmetricKey(data: key)
        let mac: Data
        switch algorithm.uppercased() {
        case "SHA256":
            mac = Data(HMAC<SHA256>.authenticationCode(for: data, using: key32))
        case "SHA512":
            mac = Data(HMAC<SHA512>.authenticationCode(for: data, using: key32))
        default:
            mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key32))
        }
        let bytes = [UInt8](mac)
        let offset = Int(bytes[bytes.count - 1] & 0x0f)
        let truncated =
            (UInt32(bytes[offset] & 0x7f) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        return String(format: "%0\(digits)u", truncated % modulus)
    }

    // How long the current code stays valid, for the menu.
    func secondsRemaining(at date: Date = Date()) -> Int {
        let step = Double(max(period, 1))
        return Int(step - date.timeIntervalSince1970.truncatingRemainder(dividingBy: step))
    }
}

func base32Decode(_ text: String) -> Data? {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    var bits = 0
    var value = 0
    var output = Data()
    for character in text.uppercased() where character != "=" && character != " " {
        guard let index = alphabet.firstIndex(of: character) else {
            if character == "-" { continue }
            return nil
        }
        value = (value << 5) | alphabet.distance(from: alphabet.startIndex, to: index)
        bits += 5
        if bits >= 8 {
            bits -= 8
            output.append(UInt8((value >> bits) & 0xff))
        }
    }
    return output
}

enum OTPAuth {
    // Accepts a full otpauth:// URI or a bare base32 secret.
    static func parse(_ input: String, site: String = "") -> CodeEntry? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("otpauth://") else {
            guard let key = base32Decode(text), key.count >= 10 else { return nil }
            return CodeEntry(
                label: site.isEmpty ? "Verification code" : site, site: site,
                secret: text.replacingOccurrences(of: " ", with: ""))
        }
        guard let components = URLComponents(string: text),
            components.host?.lowercased() == "totp"
        else { return nil }
        let items = components.queryItems ?? []
        func item(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value
        }
        guard let secret = item("secret"), base32Decode(secret) != nil else { return nil }

        // The path is "/Issuer:account" or just "/account".
        let path = components.path.hasPrefix("/")
            ? String(components.path.dropFirst()) : components.path
        let issuer = item("issuer") ?? path.components(separatedBy: ":").first ?? ""
        let account = path.components(separatedBy: ":").last ?? ""
        var label = [issuer, account].filter { !$0.isEmpty }.joined(separator: " — ")
        if label.isEmpty { label = site.isEmpty ? "Verification code" : site }

        return CodeEntry(
            label: label, site: site, secret: secret,
            algorithm: item("algorithm") ?? "SHA1",
            digits: Int(item("digits") ?? "") ?? 6,
            period: Int(item("period") ?? "") ?? 30)
    }
}

// The codes the app knows about. Kept next to the browser state, readable by
// this user only; the app is unsigned, so there is no keychain to hide it in.
final class CodeStore {
    static let shared = CodeStore()

    private(set) var entries: [CodeEntry] = []

    private static var fileURL: URL {
        Persistence.fileURL.deletingLastPathComponent()
            .appendingPathComponent("codes.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
            let decoded = try? JSONDecoder().decode([CodeEntry].self, from: data)
        {
            entries = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    @discardableResult
    func add(_ entry: CodeEntry) -> CodeEntry {
        // The same secret twice is the same code: keep one, prefer the newer
        // label and any site it came with.
        if let index = entries.firstIndex(where: { $0.secret == entry.secret }) {
            entries[index].label = entry.label
            if !entry.site.isEmpty { entries[index].site = entry.site }
            save()
            return entries[index]
        }
        entries.append(entry)
        save()
        return entry
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func setSite(_ site: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
            entries[index].site != site
        else { return }
        entries[index].site = site
        save()
    }

    // auth.example.com is served by the example.com entry, and vice versa.
    func matches(host: String) -> [CodeEntry] {
        let host = host.lowercased()
        guard !host.isEmpty else { return [] }
        return entries.filter { entry in
            let site = entry.site.lowercased()
            guard !site.isEmpty else { return false }
            return host == site || host.hasSuffix("." + site) || site.hasSuffix("." + host)
        }
    }

    // The Passwords app exports one row per login, with the otpauth URI in its
    // own column; everything else in the row is ignored, passwords included.
    @discardableResult
    func importPasswordsCSV(_ text: String) -> Int {
        let rows = parseCSV(text)
        guard let header = rows.first else { return 0 }
        let lowered = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        guard let otpColumn = lowered.firstIndex(where: { $0.contains("otpauth") })
        else { return 0 }
        let urlColumn = lowered.firstIndex { $0 == "url" || $0.contains("website") }
        let titleColumn = lowered.firstIndex { $0 == "title" || $0 == "name" }

        var imported = 0
        for row in rows.dropFirst() {
            guard otpColumn < row.count, !row[otpColumn].isEmpty else { continue }
            let site = urlColumn.flatMap { $0 < row.count ? host(of: row[$0]) : nil } ?? ""
            guard var entry = OTPAuth.parse(row[otpColumn], site: site) else { continue }
            if let titleColumn, titleColumn < row.count, !row[titleColumn].isEmpty {
                entry.label = row[titleColumn]
            }
            add(entry)
            imported += 1
        }
        return imported
    }

    private func host(of text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "" }
        let withScheme = text.contains("://") ? text : "https://" + text
        return URL(string: withScheme)?.host ?? ""
    }
}

// Quote-aware CSV, enough for an export file: "" is an escaped quote and a
// quoted field may hold commas and newlines.
func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var iterator = text.makeIterator()
    var pending: Character?

    func endField() {
        row.append(field.trimmingCharacters(in: .whitespaces))
        field = ""
    }
    func endRow() {
        endField()
        if row.count > 1 || !(row.first ?? "").isEmpty { rows.append(row) }
        row = []
    }

    while let character = pending ?? iterator.next() {
        pending = nil
        if quoted {
            if character == "\"" {
                if let next = iterator.next() {
                    if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                } else {
                    quoted = false
                }
            } else {
                field.append(character)
            }
            continue
        }
        switch character {
        case "\"": quoted = true
        case ",": endField()
        case "\n": endRow()
        case "\r": break
        default: field.append(character)
        }
    }
    endRow()
    return rows
}
