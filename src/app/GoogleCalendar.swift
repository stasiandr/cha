import AppKit
import CryptoKit
import Network
import UserNotifications

// Google Calendar, as in Arc: the next meeting sits at the bottom of the
// sidebar with a Join button, and a notification comes a minute before a
// meeting that has a call link.
//
// Signing in is Google's OAuth for desktop apps: the consent page opens in a
// cha tab (where the user is signed in to Google already), Google sends the
// code to a one-off server on 127.0.0.1, PKCE keeps it to cha. The client ID
// is the user's own (Google Cloud → Credentials → OAuth client, "Desktop
// app"); cha asks for the downloaded JSON the first time. Only read access to
// events is asked for.
//
// The checks point it at a fake Google (scripts/google-fake.py) with
// CHA_GOOGLE_BASE, and record reminders instead of posting them.

struct CalendarEvent: Equatable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let joinURL: URL?
    let link: URL?
}

final class GoogleCalendar: NSObject, ObservableObject {
    static let shared = GoogleCalendar()

    @Published private(set) var connected = false
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var problem: String?
    @Published private(set) var now = Date()
    @Published var dismissed: Set<String> = []

    /// Opens a URL in cha (the consent page, Join); set by the controller.
    var openURL: (String) -> Void = { _ in }
    /// Closes the tab that showed "connected"; set by the controller.
    var closeSignInTab: (String) -> Void = { _ in }
    /// Reminders: posted for real, recorded by the checks.
    var schedule: (_ reminders: [(event: CalendarEvent, at: Date)]) -> Void = { _ in }

    private let base = ProcessInfo.processInfo.environment["CHA_GOOGLE_BASE"]
    private var authURL: String { base.map { $0 + "/auth" } ?? "https://accounts.google.com/o/oauth2/v2/auth" }
    private var tokenURL: String { base.map { $0 + "/token" } ?? "https://oauth2.googleapis.com/token" }
    private var apiURL: String { base.map { $0 + "/calendar/v3" } ?? "https://www.googleapis.com/calendar/v3" }
    static let scope = "https://www.googleapis.com/auth/calendar.events.readonly"

    private var clientFile: URL { Persistence.directory.appendingPathComponent("google-client.json") }
    private var tokenFile: URL { Persistence.directory.appendingPathComponent("google-token.json") }

    private struct Client { let id: String; let secret: String }
    private struct Token: Codable {
        var refresh: String
        var access: String
        var expires: Date
    }
    private var token: Token?
    private var listener: NWListener?
    private var timer: Timer?
    private var fetching = false
    private var redirectURI = ""
    // The browser's spare connections that never send anything: closed with
    // the listener.
    private var connections: [NWConnection] = []

    private func stopListening(keeping answered: NWConnection? = nil) {
        listener?.cancel()
        listener = nil
        connections.filter { $0 !== answered }.forEach { $0.cancel() }  // the answered one closes after its reply
        connections = []
    }

    // MARK: - Starting

    func start() {
        token = (try? Data(contentsOf: tokenFile)).flatMap { try? JSONDecoder().decode(Token.self, from: $0) }
        connected = token != nil
        timer?.invalidate()
        // The card's "in 5 min" moves every half minute; events come anew every 5.
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.now = Date()
            ticks += 1
            if ticks % 10 == 0 { self.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.now = Date()
            self?.refresh()
        }
        refresh()
    }

    /// The meeting for the card: going on now, or the next one today.
    var next: CalendarEvent? {
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        return events.first { $0.end > now && $0.start < endOfDay && !dismissed.contains($0.id) }
    }

    // MARK: - Signing in

    func connect() {
        guard let client = loadClient() ?? pickClientFile() else { return }
        problem = nil
        let verifier = Self.randomString(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(16)

        stopListening()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else {
            problem = "Couldn't start the sign-in"
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.connections.append(connection)
            self?.answer(connection, client: client, verifier: verifier, state: state)
        }
        listener.stateUpdateHandler = { [weak self] status in
            guard case .ready = status, let port = listener.port?.rawValue else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.redirectURI = "http://127.0.0.1:\(port)"
                var parts = URLComponents(string: self.authURL)!
                parts.queryItems = [
                    .init(name: "client_id", value: client.id),
                    .init(name: "redirect_uri", value: self.redirectURI),
                    .init(name: "response_type", value: "code"),
                    .init(name: "scope", value: Self.scope),
                    .init(name: "code_challenge", value: challenge),
                    .init(name: "code_challenge_method", value: "S256"),
                    .init(name: "state", value: state),
                    .init(name: "access_type", value: "offline"),
                    .init(name: "prompt", value: "consent"),
                ]
                self.openURL(parts.url!.absoluteString)
            }
        }
        listener.start(queue: .main)
    }

    func disconnect() {
        token = nil
        try? FileManager.default.removeItem(at: tokenFile)
        connected = false
        events = []
        schedule([])
    }

    // The redirect: one GET with ?code= (or ?error=), answered with a page
    // saying what happened; then the code becomes tokens.
    private func answer(_ connection: NWConnection, client: Client, verifier: String, state: String) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://127.0.0.1" + path)?.queryItems ?? []
            func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
            guard path.hasPrefix("/?"), item("state") != nil || item("error") != nil else {
                self.reply(connection, status: "404 Not Found", body: "")
                return
            }
            guard item("state") == state, let code = item("code") else {
                self.reply(connection, status: "200 OK", body: Self.page("Google Calendar wasn't connected", item("error") ?? "Try again from the cha menu."))
                self.problem = "Google sign-in: \(item("error") ?? "refused")"
                self.stopListening(keeping: connection)
                return
            }
            self.reply(connection, status: "200 OK", body: Self.page("Google Calendar is connected", "This tab closes by itself."))
            self.stopListening(keeping: connection)
            self.exchange(code: code, client: client, verifier: verifier, redirect: self.redirectURI)
        }
    }

    private func reply(_ connection: NWConnection, status: String, body: String) {
        let data = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(_ title: String, _ text: String) -> String {
        "<!doctype html><title>\(title)</title><body style='font: 15px -apple-system; margin: 4em; color: #333'>"
            + "<h2>\(title)</h2><p>\(text)</p>"
    }

    private func exchange(code: String, client: Client, verifier: String, redirect: String) {
        post(tokenURL, [
            "code": code, "client_id": client.id, "client_secret": client.secret,
            "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirect,
        ]) { [weak self] json in
            guard let self else { return }
            guard let json, let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
                self.problem = "Google sign-in failed: \((json?["error"] as? String) ?? "no answer")"
                return
            }
            let expires = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
            self.store(Token(refresh: refresh, access: access, expires: expires))
            self.connected = true
            self.closeSignInTab(redirect)
            self.refresh()
        }
    }

    private func store(_ token: Token) {
        self.token = token
        if let data = try? JSONEncoder().encode(token) {
            FileManager.default.createFile(atPath: tokenFile.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    // MARK: - Events

    func refresh() {
        guard let token, !fetching else { return }
        fetching = true
        withAccess(token) { [weak self] access in
            guard let self else { return }
            guard let access else { self.fetching = false; return }
            var parts = URLComponents(string: self.apiURL + "/calendars/primary/events")!
            let now = Date()
            let iso = ISO8601DateFormatter()
            parts.queryItems = [
                .init(name: "timeMin", value: iso.string(from: now.addingTimeInterval(-6 * 3600))),
                .init(name: "timeMax", value: iso.string(from: now.addingTimeInterval(36 * 3600))),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "maxResults", value: "50"),
            ]
            var request = URLRequest(url: parts.url!)
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                DispatchQueue.main.async {
                    self.fetching = false
                    guard status == 200, let items = json?["items"] as? [[String: Any]] else {
                        if status == 401 { self.token?.expires = .distantPast }
                        self.problem = status == 0 ? nil : "Google Calendar: HTTP \(status)"
                        return
                    }
                    self.problem = nil
                    self.now = Date()
                    self.events = items.compactMap(Self.event).filter { $0.end > self.now }
                    self.schedule(self.events.compactMap { event in
                        guard event.joinURL != nil else { return nil }
                        let at = event.start.addingTimeInterval(-60)
                        return at > self.now ? (event, at) : nil
                    })
                }
            }.resume()
        }
    }

    /// A timed meeting the user hasn't declined; all-day events and
    /// cancelled ones are no meetings.
    static func event(_ item: [String: Any]) -> CalendarEvent? {
        guard (item["status"] as? String) != "cancelled",
              let id = item["id"] as? String,
              let start = (item["start"] as? [String: Any])?["dateTime"] as? String,
              let end = (item["end"] as? [String: Any])?["dateTime"] as? String,
              let startDate = parseDate(start), let endDate = parseDate(end)
        else { return nil }
        let attendees = item["attendees"] as? [[String: Any]] ?? []
        if attendees.contains(where: { ($0["self"] as? Bool) == true && ($0["responseStatus"] as? String) == "declined" }) {
            return nil
        }
        return CalendarEvent(
            id: id, title: (item["summary"] as? String) ?? "(No title)",
            start: startDate, end: endDate, joinURL: joinURL(item),
            link: (item["htmlLink"] as? String).flatMap(URL.init(string:)))
    }

    static func joinURL(_ item: [String: Any]) -> URL? {
        if let link = item["hangoutLink"] as? String, let url = URL(string: link) { return url }
        let points = (item["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] ?? []
        if let video = points.first(where: { ($0["entryPointType"] as? String) == "video" })?["uri"] as? String,
           let url = URL(string: video) { return url }
        // Zoom, Teams, Meet links written into the place or the description.
        let text = [item["location"], item["description"]].compactMap { $0 as? String }.joined(separator: " ")
        let pattern = #"https://[^\s"'<>]*(meet\.google\.com|zoom\.us|teams\.microsoft\.com|teams\.live\.com)[^\s"'<>]*"#
        if let range = text.range(of: pattern, options: .regularExpression) {
            return URL(string: String(text[range]))
        }
        return nil
    }

    private static func parseDate(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    private func withAccess(_ token: Token, _ then: @escaping (String?) -> Void) {
        if token.expires > Date() { then(token.access); return }
        guard let client = loadClient() else { then(nil); return }
        post(tokenURL, [
            "client_id": client.id, "client_secret": client.secret,
            "refresh_token": token.refresh, "grant_type": "refresh_token",
        ]) { [weak self] json in
            guard let self else { return }
            guard let access = json?["access_token"] as? String else {
                // Revoked or expired for good: signing in again is needed.
                if (json?["error"] as? String) == "invalid_grant" {
                    self.disconnect()
                    self.problem = "Google Calendar needs signing in again"
                }
                then(nil)
                return
            }
            var fresh = token
            fresh.access = access
            fresh.expires = Date().addingTimeInterval((json?["expires_in"] as? Double ?? 3600) - 60)
            self.store(fresh)
            then(access)
        }
    }

    private func post(_ url: String, _ form: [String: String], _ done: @escaping ([String: Any]?) -> Void) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(json) }
        }.resume()
    }

    // MARK: - The client ID

    // Google's download: {"installed": {"client_id": …, "client_secret": …}}.
    private func loadClient() -> Client? {
        guard let data = try? Data(contentsOf: clientFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = (json["installed"] ?? json["web"]) as? [String: Any],
              let id = inner["client_id"] as? String
        else { return nil }
        return Client(id: id, secret: inner["client_secret"] as? String ?? "")
    }

    private func pickClientFile() -> Client? {
        let alert = NSAlert()
        alert.messageText = "Connect Google Calendar"
        alert.informativeText = """
            cha signs in with your own OAuth client. In Google Cloud Console → \
            APIs & Services: enable the Google Calendar API, then Credentials → \
            Create credentials → OAuth client ID → Desktop app, and download its JSON.
            """
        alert.addButton(withTitle: "Choose the JSON…")
        alert.addButton(withTitle: "Open Google Cloud")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertSecondButtonReturn:
            openURL("https://console.cloud.google.com/apis/credentials")
            return nil
        default: return nil
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let picked = panel.url, let data = try? Data(contentsOf: picked) else { return nil }
        FileManager.default.createFile(atPath: clientFile.path, contents: data, attributes: [.posixPermissions: 0o600])
        guard let client = loadClient() else {
            problem = "That file isn't an OAuth client"
            return nil
        }
        return client
    }

    private static func randomString(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Reminders

/// A notification a minute before a meeting with a call link; clicking it
/// or Join opens the call in cha.
final class MeetingReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MeetingReminders()
    var join: (URL) -> Void = { _ in }
    private var asked = false

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let join = UNNotificationAction(identifier: "join", title: "Join", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "meeting", actions: [join], intentIdentifiers: []),
        ])
    }

    func schedule(_ reminders: [(event: CalendarEvent, at: Date)]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let ours = pending.map(\.identifier).filter { $0.hasPrefix("meeting-") }
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }
        guard !reminders.isEmpty else { return }
        let post = {
            for (event, at) in reminders.prefix(20) {
                let content = UNMutableNotificationContent()
                content.title = event.title
                content.body = "Starts in a minute, \(Self.time.string(from: event.start))–\(Self.time.string(from: event.end))"
                content.sound = .default
                content.categoryIdentifier = "meeting"
                content.userInfo = ["join": event.joinURL?.absoluteString ?? ""]
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                center.add(UNNotificationRequest(
                    identifier: "meeting-\(event.id)-\(Int(event.start.timeIntervalSince1970))",
                    content: content, trigger: trigger))
            }
        }
        if asked { post(); return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.asked = true
            if granted { DispatchQueue.main.async(execute: post) }
        }
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let link = response.notification.request.content.userInfo["join"] as? String, let url = URL(string: link),
           response.actionIdentifier == "join" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.join(url) }
        }
        done()
    }
}

extension BrowserController {
    /// Hooks the calendar up to this window: sign-in and Join open cha tabs,
    /// reminders post notifications (recorded in the checks instead).
    func startCalendar() {
        let calendar = GoogleCalendar.shared
        calendar.openURL = { [weak self] in self?.newTab(url: $0) }
        calendar.closeSignInTab = { [weak self] redirect in
            guard let self else { return }
            for space in self.spaces {
                for tab in space.tabs where (self.liveTabs[tab.id]?.currentURL ?? tab.url).hasPrefix(redirect) {
                    self.closeTab(tab.id)
                }
            }
        }
        if !Diagnostics.headless {
            MeetingReminders.shared.install()
            MeetingReminders.shared.join = { [weak self] in self?.joinMeeting($0) }
            calendar.schedule = { MeetingReminders.shared.schedule($0) }
        }
        calendar.start()
    }

    func joinMeeting(_ url: URL) {
        if !Diagnostics.quiet { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
        newTab(url: url.absoluteString)
    }
}
