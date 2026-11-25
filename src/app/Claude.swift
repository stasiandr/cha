import AppKit
import Darwin

// Claude in cha, as Claude in Chrome is in Chrome: Claude Code (and the
// Claude app's Code tab) drive cha's tabs through an MCP server. cha
// listens on a Unix socket in its profile folder (claude.sock, only this
// user can open it); `cha-mcp` next to it is the stdio server Claude starts.
// It joins the socket; while cha isn't running it answers the handshake
// itself and opens cha (in the background) only on the first tool call.
//
// The tools work on cha's own tabs, in every space but the secret one:
// list them, open, select, close, go to an address, read the page as text
// or as an outline of what can be clicked (with refs), find an element,
// click, type, press keys, scroll, take a screenshot, run JavaScript.
// Tabs opened by Claude open in the background, so whoever is using cha
// keeps the tab in front; a tab Claude works on shows a sparkle in the
// sidebar for a few seconds.
final class ClaudeServer {
    static let shared = ClaudeServer()
    weak var controller: BrowserController?

    /// claude.sock in the profile folder; a Unix socket's path has room
    /// for 103 bytes, so a deeper profile (a check's, in a worktree) gets
    /// one in the user's temporary folder, named after the profile.
    static let socketURL: URL = {
        let url = Persistence.directory.appendingPathComponent("claude.sock")
        if url.path.utf8.count < 100 { return url }
        let digest = ExtensionStore.extensionID(of: Data(Persistence.directory.path.utf8)).prefix(12)
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cha-\(digest).sock")
    }()
    static var bridgeURL: URL { Persistence.directory.appendingPathComponent("cha-mcp") }

    /// Settings ▸ "Let Claude Use cha": on unless turned off.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "claudeControl") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "claudeControl")
            if newValue { shared.start() } else { shared.stop() }
        }
    }

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: ClaudeConnection] = [:]
    private(set) var isListening = false

    func start() {
        guard Self.enabled, !isListening else { return }
        writeBridge()
        let path = Self.socketURL.path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return log("socket failed: \(errno)") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            close(fd)
            return log("socket path too long (\(bytes.count) bytes): \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else {
            close(fd)
            return log("bind failed: \(errno)")
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            close(fd)
            return log("listen failed: \(errno)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        acceptSource = source
        isListening = true
        log("listening on \(path)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        isListening = false
        for connection in connections.values { connection.close() }
        connections.removeAll()
        unlink(Self.socketURL.path)
    }

    private func accept() {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let connection = ClaudeConnection(fd: fd)
            connection.onClose = { [weak self, weak connection] in
                guard let connection else { return }
                self?.connections.removeValue(forKey: ObjectIdentifier(connection))
            }
            connections[ObjectIdentifier(connection)] = connection
            connection.start()
        }
    }

    /// The stdio side Claude starts: joins the socket, opening cha first
    /// when nothing listens on it.
    private func writeBridge() {
        // What the bridge answers before cha is up (the handshake and the
        // tool list), so a Claude session starting never opens cha; the
        // first tool call does.
        let config: [String: Any] = [
            "socket": Self.socketURL.path,
            // Only the real profile opens cha: a check's profile must never
            // start (or bring forward) the cha in use.
            "launch": ProcessInfo.processInfo.environment["CHA_PROFILE"] == nil,
            "instructions": ClaudeTools.instructions,
            "tools": ClaudeTools.definitions,
        ]
        if let json = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes]) {
            let url = Self.bridgeURL.appendingPathExtension("json")
            if (try? Data(contentsOf: url)) != json { try? json.write(to: url, options: .atomic) }
        }
        let url = Self.bridgeURL
        if (try? String(contentsOf: url, encoding: .utf8)) != Self.bridgeScript {
            try? Self.bridgeScript.write(to: url, atomically: true, encoding: .utf8)
        }
        chmod(url.path, 0o755)
    }

    /// The stdio MCP server Claude starts (Python 3.9, as macOS has it).
    /// It joins cha's socket and passes lines both ways; with cha not
    /// running it answers the handshake and tools/list itself (from
    /// cha-mcp.json), and opens cha in the background on the first tool call.
    static let bridgeScript = #"""
    #!/usr/bin/python3 -I
    # cha's MCP server for Claude, written by cha at launch (Claude.swift).
    import json, os, socket, subprocess, sys, threading, time

    with open(os.path.realpath(__file__) + ".json") as f:
        CONFIG = json.load(f)
    HANDSHAKE = "cha-bridge-init"
    out_lock = threading.Lock()
    lock = threading.Lock()
    state = {"sock": None, "init": None, "pending": set()}

    def emit_line(text):
        with out_lock:
            sys.stdout.write(text + "\n")
            sys.stdout.flush()

    def reply(mid, result):
        emit_line(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}))

    def failure(mid, text):
        reply(mid, {"content": [{"type": "text", "text": text}], "isError": True})

    def connect():
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(CONFIG["socket"])
        except OSError:
            s.close()
            return None
        return s

    def reader(s):
        buf = b""
        while True:
            try:
                chunk = s.recv(65536)
            except OSError:
                chunk = b""
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    mid = json.loads(line).get("id")
                except ValueError:
                    continue
                if mid == HANDSHAKE:
                    continue
                with lock:
                    state["pending"].discard(json.dumps(mid))
                emit_line(line.decode())
        # cha went away: calls in flight get an answer; the next one reopens it.
        with lock:
            if state["sock"] is s:
                state["sock"] = None
            pending = list(state["pending"])
            state["pending"].clear()
        for mid in pending:
            failure(json.loads(mid), "cha quit during the call.")

    def attach(s, replay):
        if replay:
            s.sendall((json.dumps({"jsonrpc": "2.0", "id": HANDSHAKE, "method": "initialize",
                                   "params": state["init"] or {}}) + "\n"
                       + json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n").encode())
        with lock:
            state["sock"] = s
        threading.Thread(target=reader, args=(s,), daemon=True).start()

    def start_cha():
        s = connect()
        if s is None and CONFIG.get("launch"):
            app = os.path.expanduser("~/Applications/cha.app")
            args = ["open", "-g", app] if os.path.isdir(app) else ["open", "-g", "-b", "dev.stasiandr.cha"]
            subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.time() + 60
            while s is None and time.time() < deadline:
                time.sleep(0.5)
                s = connect()
        return s

    def forward(s, line, mid, method):
        if mid is not None and method:
            with lock:
                state["pending"].add(json.dumps(mid))
        try:
            s.sendall((line + "\n").encode())
            return True
        except OSError:
            with lock:
                state["sock"] = None
                state["pending"].discard(json.dumps(mid))
            return False

    def handle(line):
        try:
            message = json.loads(line)
        except ValueError:
            return
        method, mid = message.get("method"), message.get("id")
        if method == "initialize":
            state["init"] = message.get("params") or {}
        with lock:
            s = state["sock"]
        if s is not None and forward(s, line, mid, method):
            return
        if method == "initialize":
            s = connect()
            if s is not None:
                attach(s, replay=False)
                forward(s, line, mid, method)
                return
            reply(mid, {"protocolVersion": state["init"].get("protocolVersion") or "2025-06-18",
                        "capabilities": {"tools": {"listChanged": False}},
                        "serverInfo": {"name": "cha", "title": "cha browser", "version": "1.0"},
                        "instructions": CONFIG["instructions"]})
        elif mid is None:
            return  # a notification, with nobody to tell
        elif method == "ping":
            reply(mid, {})
        elif method == "tools/list":
            reply(mid, {"tools": CONFIG["tools"]})
        elif method in ("resources/list", "prompts/list"):
            reply(mid, {method.split("/")[0]: []})
        elif method == "tools/call":
            s = start_cha()
            if s is None:
                return failure(mid, "cha is not running" + (" and did not start in a minute." if CONFIG.get("launch") else "."))
            attach(s, replay=True)
            if not forward(s, line, mid, method):
                failure(mid, "cha closed the connection.")
        else:
            emit_line(json.dumps({"jsonrpc": "2.0", "id": mid,
                                  "error": {"code": -32601, "message": "Method not found: %s" % method}}))

    for raw in sys.stdin:
        raw = raw.strip()
        if raw:
            handle(raw)
    """#

    func log(_ line: String) { NSLog("CLAUDE %@", line) }
}

/// One MCP session: newline-delimited JSON-RPC both ways.
final class ClaudeConnection {
    let fd: Int32
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var closed = false
    var onClose: (() -> Void)?
    private lazy var tools = ClaudeTools(connection: self)

    init(fd: Int32) { self.fd = fd }

    func start() {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        self.source = source
    }

    func close() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        Darwin.close(fd)
        onClose?()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                continue
            }
            if count == 0 || (errno != EAGAIN && errno != EINTR) {
                close()
                return
            }
            break
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
            handle(Data(line))
        }
    }

    func send(_ message: [String: Any]) {
        guard !closed, var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        else { return }
        data.append(0x0A)
        // Blocking writes: a screenshot is a megabyte, and the other end
        // (nc) drains it at once.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    private func reply(_ id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func reply(_ id: Any, error code: Int, _ message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        if let batch = object as? [[String: Any]] {
            batch.forEach(handle(message:))
        } else if let message = object as? [String: Any] {
            handle(message: message)
        }
    }

    private func handle(message: [String: Any]) {
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id = message["id"], !(id is NSNull) else { return }  // a notification
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            reply(id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "cha", "title": "cha browser", "version": "1.0"],
                "instructions": ClaudeTools.instructions,
            ])
        case "ping":
            reply(id, result: [:])
        case "tools/list":
            reply(id, result: ["tools": ClaudeTools.definitions])
        case "tools/call":
            guard ClaudeServer.enabled else {
                reply(id, result: ClaudeTools.failure("Claude is turned off in cha (cha ▸ Claude ▸ Let Claude Use cha)."))
                return
            }
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            tools.call(name, arguments) { [weak self] result in self?.reply(id, result: result) }
        case "resources/list":
            reply(id, result: ["resources": []])
        case "prompts/list":
            reply(id, result: ["prompts": []])
        default:
            reply(id, error: -32601, "Method not found: \(method)")
        }
    }
}

// MARK: - Tools

final class ClaudeTools {
    weak var connection: ClaudeConnection?
    init(connection: ClaudeConnection) { self.connection = connection }

    typealias Result = [String: Any]
    typealias Done = (Result) -> Void

    static let instructions = """
        cha is the user's own browser (Arc-like: spaces with pinned and today's tabs). \
        These tools drive its tabs. Call tabs first to see spaces and tab ids. \
        open_tab opens a page in the background so the user keeps the tab in front; \
        pass foreground: true only when the user should look at it. Without tab_id a tool \
        acts on the tab this session last opened or named (else the tab in front). read_page and find give refs (ref_12) that click, type \
        and scroll take. The user is signed in to their sites in cha: act on their behalf \
        only as asked, and confirm before sending, buying, posting or deleting anything.
        """

    static func failure(_ text: String) -> Result {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    static func text(_ text: String) -> Result {
        ["content": [["type": "text", "text": text]]]
    }

    private static func tool(_ name: String, _ title: String, _ description: String,
                             _ properties: [String: [String: Any]] = [:], required: [String] = [],
                             readOnly: Bool = false) -> [String: Any] {
        [
            "name": name, "title": title, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
            "annotations": ["readOnlyHint": readOnly, "openWorldHint": true],
        ]
    }

    private static let tabID: [String: Any] = [
        "type": "string",
        "description": "Tab id from tabs (8 characters). Default: the tab this session last opened or used, else the tab in front.",
    ]
    private static let ref: [String: Any] = [
        "type": "string", "description": "Element ref from read_page or find, e.g. ref_12.",
    ]

    static let definitions: [[String: Any]] = [
        tool("tabs", "List tabs",
             "Spaces and their tabs (favourites, pinned, today's), with ids, titles and addresses. The tab in front is marked with *.",
             readOnly: true),
        tool("open_tab", "Open a tab",
             "Opens a URL in a new tab and waits for it to load. In the background unless foreground is true.",
             ["url": ["type": "string", "description": "Address or search words."],
              "foreground": ["type": "boolean", "description": "Bring the tab to the front (default false)."],
              "space": ["type": "string", "description": "Space name to open it in (default: the space in front)."]],
             required: ["url"]),
        tool("select_tab", "Select a tab", "Brings a tab (and its space) to the front.",
             ["tab_id": tabID], required: ["tab_id"]),
        tool("close_tab", "Close a tab",
             "Closes a tab (today's tabs go to the archive, pinned ones only unload, as ⌘W does).",
             ["tab_id": tabID], required: ["tab_id"]),
        tool("navigate", "Navigate",
             "Loads an address in a tab, or goes back, forward or reloads; waits for the page to load.",
             ["url": ["type": "string", "description": "Address or search words, or back, forward, reload."],
              "tab_id": tabID],
             required: ["url"]),
        tool("get_page_text", "Page text",
             "The text of the page (its main article when it has one), with title and address.",
             ["tab_id": tabID, "max_chars": ["type": "integer", "description": "Default 30000."]],
             readOnly: true),
        tool("read_page", "Read page",
             "An outline of the page: headings, text, links, buttons and fields, each clickable one with a ref.",
             ["tab_id": tabID,
              "filter": ["type": "string", "enum": ["all", "interactive"], "description": "interactive: only what can be clicked or typed in."],
              "max_chars": ["type": "integer", "description": "Default 40000."]],
             readOnly: true),
        tool("find", "Find on page",
             "Elements whose text, label or placeholder contains the query, with refs and positions.",
             ["query": ["type": "string"], "tab_id": tabID], required: ["query"], readOnly: true),
        tool("click", "Click",
             "Clicks an element (by ref) or a point (x, y in CSS pixels of the visible page), as a real mouse click.",
             ["ref": ref, "x": ["type": "number"], "y": ["type": "number"], "tab_id": tabID,
              "double": ["type": "boolean", "description": "Double-click."],
              "button": ["type": "string", "enum": ["left", "right", "middle"]]]),
        tool("drag", "Drag",
             "Presses the mouse at a start (ref or x, y), moves it in steps to an end (to_ref or to_x, to_y) and lets go: drawing, sliders, drag and drop.",
             ["ref": ref, "x": ["type": "number"], "y": ["type": "number"],
              "to_ref": ["type": "string", "description": "Element ref to drop on."],
              "to_x": ["type": "number"], "to_y": ["type": "number"], "tab_id": tabID]),
        tool("hover", "Hover",
             "Moves the mouse over an element (ref) or a point, for menus and tooltips that open on hover.",
             ["ref": ref, "x": ["type": "number"], "y": ["type": "number"], "tab_id": tabID]),
        tool("type", "Type text",
             "Types text into an element (by ref, focused first) or wherever the focus is.",
             ["text": ["type": "string"], "ref": ref, "tab_id": tabID,
              "clear": ["type": "boolean", "description": "Replace what the field holds (default false)."],
              "submit": ["type": "boolean", "description": "Press Enter after typing."]],
             required: ["text"]),
        tool("press_key", "Press keys",
             "Presses keys in the page: Enter, Tab, Escape, Backspace, ArrowDown, PageDown, a letter, or a chord such as cmd+a, shift+Tab. Several separated by spaces.",
             ["keys": ["type": "string"], "tab_id": tabID], required: ["keys"]),
        tool("scroll", "Scroll",
             "Scrolls the page (or the scrollable part under an element) up or down, or scrolls an element into view.",
             ["direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
              "amount": ["type": "number", "description": "Screens to scroll (default 0.8)."],
              "ref": ref, "tab_id": tabID]),
        tool("screenshot", "Screenshot",
             "A picture of what the tab shows now (JPEG). The tab needn't be in front.",
             ["tab_id": tabID], readOnly: true),
        tool("javascript", "Run JavaScript",
             "Runs JavaScript in the page and returns its value (promises are awaited, up to 60 s; the last expression is the result).",
             ["code": ["type": "string"], "tab_id": tabID], required: ["code"]),
    ]

    // MARK: Dispatch

    func call(_ name: String, _ args: [String: Any], done: @escaping Done) {
        guard let controller = ClaudeServer.shared.controller else {
            return done(Self.failure("cha is still starting."))
        }
        switch name {
        case "tabs": done(Self.text(listTabs(controller)))
        case "open_tab": openTab(controller, args, done)
        case "select_tab":
            guard let id = resolve(controller, args["tab_id"]) else { return done(noTab(args)) }
            controller.activateTab(id)
            done(Self.text("Tab \(short(id)) is in front."))
        case "close_tab":
            guard let id = resolve(controller, args["tab_id"]) else { return done(noTab(args)) }
            let title = controller.tabData(id)?.displayTitle ?? ""
            controller.claudeTabs.remove(id)
            controller.closeTab(id)
            done(Self.text("Closed \(short(id)) \(title)."))
        case "navigate": navigate(controller, args, done)
        case "get_page_text": pageText(controller, args, done)
        case "read_page": readPage(controller, args, done)
        case "find": find(controller, args, done)
        case "click": click(controller, args, done)
        case "drag": drag(controller, args, done)
        case "hover": hover(controller, args, done)
        case "type": type(controller, args, done)
        case "press_key": pressKeys(controller, args, done)
        case "scroll": scroll(controller, args, done)
        case "screenshot": screenshot(controller, args, done)
        case "javascript": javascript(controller, args, done)
        default: done(Self.failure("No tool named \(name)."))
        }
    }

    // MARK: Tabs

    private func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    /// Tabs Claude may see: favourites and every space but the secret one.
    private func visibleTabs(_ controller: BrowserController) -> [TabData] {
        controller.favorites + controller.spaces.filter { !$0.isSecret }.flatMap(\.tabs)
    }

    /// The tab this session last opened or named: what a call without a
    /// tab_id acts on, so Claude keeps to its own tab while the user browses.
    private var current: UUID?

    private func resolve(_ controller: BrowserController, _ value: Any?) -> UUID? {
        let visible = visibleTabs(controller)
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else {
            if let current, visible.contains(where: { $0.id == current }) { return current }
            guard !controller.inSecretSpace else { return nil }
            return controller.activeTabID
        }
        let id = visible.first { $0.id.uuidString.lowercased().hasPrefix(text) }?.id
        if id != nil { current = id }
        return id
    }

    private func noTab(_ args: [String: Any]) -> Result {
        if let id = args["tab_id"] as? String, !id.isEmpty {
            return Self.failure("No tab \(id). Call tabs to see the tab ids.")
        }
        return Self.failure("No tab is in front. Pass a tab_id (see tabs) or open_tab.")
    }

    private func listTabs(_ controller: BrowserController) -> String {
        var lines: [String] = []
        let front = controller.inSecretSpace ? nil : controller.activeTabID
        func line(_ tab: TabData, _ notes: [String]) -> String {
            var notes = notes
            if controller.isLoaded(tab.id) { notes.append("loaded") }
            if controller.loadingTabs.contains(tab.id) { notes.append("loading") }
            let mark = tab.id == front ? "*" : " "
            let suffix = notes.isEmpty ? "" : "  (" + notes.joined(separator: ", ") + ")"
            return "  \(mark) [\(short(tab.id))] \(tab.displayTitle) — \(tab.url)\(suffix)"
        }
        if !controller.favorites.isEmpty {
            lines.append("Favourites (in every space):")
            lines += controller.favorites.map { line($0, []) }
        }
        for space in controller.spaces where !space.isSecret {
            let active = space.id == controller.activeSpaceID ? " (in front)" : ""
            lines.append("Space \"\(space.name)\"\(active):")
            if space.tabs.isEmpty { lines.append("    no tabs") }
            for tab in space.tabs {
                var notes: [String] = []
                if tab.isPinned {
                    let folder = tab.folderID.flatMap { id in space.folders.first { $0.id == id }?.name }
                    notes.append(folder.map { "pinned, in \($0)" } ?? "pinned")
                }
                lines.append(line(tab, notes))
            }
        }
        if controller.inSecretSpace { lines.append("(The user is in a private space; its tabs are not listed.)") }
        return lines.joined(separator: "\n")
    }

    private func openTab(_ controller: BrowserController, _ args: [String: Any], _ done: @escaping Done) {
        guard let input = args["url"] as? String, !input.isEmpty else { return done(Self.failure("url is required.")) }
        let url = Self.address(input)
        var space = controller.activeSpace
        if let name = args["space"] as? String, !name.isEmpty {
            guard let named = controller.spaces.first(where: { !$0.isSecret && $0.name.lowercased() == name.lowercased() })
            else { return done(Self.failure("No space named \(name).")) }
            space = named
        }
        if space.isSecret, let first = controller.spaces.first(where: { !$0.isSecret }) { space = first }
        let data = TabData(url: url)
        let firstToday = space.tabs.firstIndex { !$0.isPinned } ?? space.tabs.count
        space.tabs.insert(data, at: firstToday)
        controller.replace(space)
        current = data.id
        if args["foreground"] as? Bool == true {
            controller.activateTab(data.id)
        } else {
            controller.liveTab(data.id, url: url)
        }
        touch(controller, data.id)
        waitForLoad(controller, data.id) { [weak self] in
            guard let self else { return }
            let tab = controller.tabData(data.id)
            done(Self.text("Opened [\(self.short(data.id))] \(tab?.displayTitle ?? "") — \(controller.liveTabs[data.id]?.currentURL ?? url)"))
        }
    }

    /// What the address bar would do with it: an address, or a search.
    static func address(_ input: String) -> String { normalizedURL(from: input) }

    private func navigate(_ controller: BrowserController, _ args: [String: Any], _ done: @escaping Done) {
        guard let id = resolve(controller, args["tab_id"]) else { return done(noTab(args)) }
        guard let input = args["url"] as? String, !input.isEmpty else { return done(Self.failure("url is required.")) }
        let tab = live(controller, id)
        switch input.lowercased() {
        case "back": tab.goBack()
        case "forward": tab.goForward()
        case "reload": tab.reload()
        default: tab.loadURL(Self.address(input))
        }
        touch(controller, id)
        waitForLoad(controller, id) {
            done(Self.text("[\(self.short(id))] \(tab.title) — \(tab.currentURL)"))
        }
    }

    /// The tab's browser, made if it has none yet (a restored or archived tab).
    private func live(_ controller: BrowserController, _ id: UUID) -> ChaTab {
        if let tab = controller.liveTabs[id] { return tab }
        return controller.liveTab(id, url: controller.tabData(id)?.url ?? "about:blank")
    }

    /// Done once the page stopped loading (or after 20 seconds).
    private func waitForLoad(_ controller: BrowserController, _ id: UUID, then: @escaping () -> Void) {
        let start = Date()
        func check() {
            let tab = controller.liveTabs[id]
            let elapsed = Date().timeIntervalSince(start)
            let ready = tab.map { !$0.isLoading && $0.nativeWindow != nil && !$0.currentURL.isEmpty } ?? true
            if (ready && elapsed > 0.4) || elapsed > 20 {
                then()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: check)
            }
        }
        check()
    }

    /// The sparkle on the tab's row, for a few seconds after Claude's last step.
    private func touch(_ controller: BrowserController, _ id: UUID) {
        controller.claudeTabs.insert(id)
        let stamp = Date()
        lastTouch[id] = stamp
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak controller] in
            guard let self, self.lastTouch[id] == stamp else { return }
            controller?.claudeTabs.remove(id)
        }
    }
    private var lastTouch: [UUID: Date] = [:]

    // MARK: DevTools

    /// A DevTools method on the tab's page, waiting (up to 10 s) for a
    /// browser that is still being made.
    private func devTools(_ tab: ChaTab, _ method: String, _ params: [String: Any] = [:],
                          timeout: TimeInterval = 20,
                          _ done: @escaping (Swift.Result<[String: Any], ClaudeError>) -> Void) {
        let start = Date()
        var finished = false
        func finish(_ result: Swift.Result<[String: Any], ClaudeError>) {
            guard !finished else { return }
            finished = true
            done(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(.failure(ClaudeError("\(method) took longer than \(Int(timeout)) s.")))
        }
        func attempt() {
            tab.callDevTools(method, params: params) { json, error in
                if let error {
                    if error.contains("no page loaded"), Date().timeIntervalSince(start) < 10, !tab.isClosed {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: attempt)
                        return
                    }
                    return finish(.failure(ClaudeError(error)))
                }
                let object = json.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                finish(.success(object ?? [:]))
            }
        }
        attempt()
    }

    /// Runs |expression| in the page; the value comes back as JSON-able Any.
    /// REPL mode (as the DevTools console: top-level await, const declared
    /// again) awaits only a top-level await, so a promise the code returns
    /// is awaited here, and objects come back by value.
    private func evaluate(_ tab: ChaTab, _ expression: String, gesture: Bool = false, timeout: TimeInterval = 20,
                          _ done: @escaping (Swift.Result<Any, ClaudeError>) -> Void) {
        devTools(tab, "Runtime.evaluate", [
            "expression": expression, "awaitPromise": true, "returnByValue": false,
            "userGesture": gesture, "replMode": true,
        ], timeout: timeout) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): done(.failure(error))
            case .success(let body): self.value(tab, body, done)
            }
        }
    }

    /// A Runtime result as a value: primitives as they are, a promise once
    /// it settles, an object copied by value.
    private func value(_ tab: ChaTab, _ body: [String: Any], _ done: @escaping (Swift.Result<Any, ClaudeError>) -> Void) {
        if let details = body["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            let text = exception?["description"] as? String ?? exception?["value"].map { "Uncaught \($0)" }
                ?? details["text"] as? String ?? "exception"
            return done(.failure(ClaudeError(text)))
        }
        let result = body["result"] as? [String: Any] ?? [:]
        guard let objectID = result["objectId"] as? String else {
            if (result["type"] as? String) == "undefined" { return done(.success(NSNull())) }
            if let unserializable = result["unserializableValue"] as? String { return done(.success(unserializable)) }
            return done(.success(result["value"] ?? NSNull()))
        }
        if (result["subtype"] as? String) == "promise" {
            devTools(tab, "Runtime.awaitPromise", ["promiseObjectId": objectID, "returnByValue": false], timeout: 60) { [weak self] next in
                switch next {
                case .failure(let error): done(.failure(error))
                case .success(let body): self?.value(tab, body, done)
                }
            }
            return
        }
        devTools(tab, "Runtime.callFunctionOn", [
            "objectId": objectID, "returnByValue": true,
            // DOM nodes and other things JSON can't hold are described instead.
            "functionDeclaration": """
                function() { try { const s = JSON.stringify(this); if (s !== undefined) return JSON.parse(s); } catch (e) {}
                  return this instanceof Node ? '<' + (this.nodeName || 'node').toLowerCase() + '>' : String(this); }
                """,
        ]) { next in
            switch next {
            case .failure(let error): done(.failure(error))
            case .success(let body):
                done(.success((body["result"] as? [String: Any])?["value"] ?? NSNull()))
            }
        }
    }

    /// The page helper (refs that last across calls), then |call| on it.
    private func helper(_ tab: ChaTab, _ call: String, _ done: @escaping (Swift.Result<Any, ClaudeError>) -> Void) {
        evaluate(tab, Self.helperScript + "\n" + call, done)
    }

    /// Finds the tab for a call that needs a page, or answers with why not.
    private func page(_ controller: BrowserController, _ args: [String: Any], _ done: Done) -> (UUID, ChaTab)? {
        guard let id = resolve(controller, args["tab_id"]) else {
            done(noTab(args))
            return nil
        }
        let tab = live(controller, id)
        touch(controller, id)
        return (id, tab)
    }

    // MARK: Reading

    private func pageText(_ controller: BrowserController, _ args: [String: Any], _ done: @escaping Done) {
        guard let (_, tab) = page(controller, args, done) else { return }
        let limit = args["max_chars"] as? Int ?? 30000
        helper(tab, "__chaClaude.text(\(limit))") { result in
            switch result {
            case .failure(let error): done(Self.failure("Could not read the page: \(error.message)"))
            case .success(let value): done(Self.text(value as? String ?? ""))
            }
        }
    }

    private func readPage(_ controller: BrowserController, _ args: [String: Any], _ done: @escaping Done) {
        guard let (_, tab) = page(controller, args, done) else { return }
        let interactive = (args["filter"] as? String) == "interactive"
        let limit = args["max_chars"] as? Int ?? 40000
        helper(tab, "__chaClaude.outline(\(interactive), \(limit))") { result in
            switch result {
            case .failure(let error): done(Self.failure("Could not read the page: \(error.message)"))
            case .success(let value): done(Self.text(value as? String ?? ""))
            }
        }
    }

    private func find(_ controller: BrowserController, _ args: [String: Any], _ done: @escaping Done) {
        guard let query = args["query"] as? String, !query.isEmpty else { return done(Self.failure("query is required.")) }
        guard let (_, tab) = page(controller, args, done) else { return }
        helper(tab, "__chaClaude.find(\(Self.jsString(query)))") { result in
            switch result {
            case .failure(let error): done(Self.failure("Could not search the page: \(error.message)"))
            case .success(let value): done(Self.text(value as? String ?? ""))
            }
        }
    }

    // MARK: Acting

    private func click(_ controller: BrowserController, _ args: [String: Any], _ done: @escaping Done) {
        guard let (id, tab) = page(controller, args, done) else { return }
        let count = args["double"] as? Bool == true ? 2 : 1
        let button = args["button"] as? String ?? "left"
        point(tab, args) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): done(Self.failure(error.message))
            case .success(let (x, y, label)):
                self.mouseClick(tab, x: x, y: y, button: button, count: count) { error in
                    if let error { return done(Self.failure("The click failed: \(error.message)")) }
                    // A click that navigates: the answer waits for the new page.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.waitForLoad(controller, id) {
                            done(Self.text("Clicked \(label) at (\(Int(x)), \(Int(y))). Page: \(tab.title) — \(tab.currentURL)"))
                        }
                    }
                }
            }
        }
    }

    /// Where to click: a ref's centre (scrolled into view first) or x, y.
    private func point(_ tab: ChaTab, _ args: [String: Any],
                       _ done: @escaping (Swift.Result<(Double, Double, String), ClaudeError>) -> Void) {
        if let ref = args["ref"] as? String, !ref.isEmpty {
            helper(tab, "__chaClaude.point(\(Self.jsString(ref)))") { result in
                switch result {
                case .failure(let error): done(.failure(error))
                case .success(let value):
                    guard let info = value as? [String: Any], let x = info["x"] as? Double, let y = info["y"] as? Double
                    else { return done(.failure(ClaudeError((value as? String) ?? "No element \(ref): call read_page or find again."))) }
                    done(.success((x, y, "\(ref) \(info["label"] as? String ?? "")")))
                }
            }
        } else if let x = (args["x"] as? NSNumber)?.doubleValue, let y = (args["y"] as? NSNumber)?.doubleValue {
            done(.success((x, y, "the point")))
        } else {
            done(.failure(ClaudeError("Pass a ref (from read_page or find) or x and y.")))
        }
    }

    private func drag(_ controller: BrowserController, _ args: [String: Any], _ done: @escaping Done) {
        guard let (_, tab) = page(controller, args, done) else { return }
        point(tab, args) { [weak self] start in
            guard let self else { return }
            guard case .success(let (x0, y0, from)) = start else {
                if case .failure(let error) = start { done(Self.failure(error.message)) }
                return
            }
            var end: [String: Any] = [:]
            if let ref = args["to_ref"] { end["ref"] = ref }
            if let x = args["to_x"] { end["x"] = x }
            if let y = args["to_y"] { end["y"] = y }
            self.point(tab, end) { finish in
                guard case .success(let (x1, y1, to)) = finish else {
                    if case .failure(let error) = finish { done(Self.failure("The end: " + error.message)) }
                    return
                }
                var calls: [(String, [String: Any])] = [
                    ("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": x0, "y": y0]),
                    ("Input.dispatchMouseEvent", ["type": "mousePressed", "x": x0, "y": y0, "button": "left", "buttons": 1, "clickCount": 1]),
                ]
                let steps = 12
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    calls.append(("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": x0 + (x1 - x0) * t, "y": y0 + (y1 - y0) * t,
                                                               "button": "left", "buttons": 1]))
                }
                calls.append(("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": x1, "y": y1, "button": "left", "buttons": 0, "clickCount": 1]))
                self.run(tab, calls) { error in
                    if let error { return done(Self.failure("The drag failed: \(error.message)")) }
                    done(Self.text("Dragged from \(from) (\(Int(x0)), \(Int(y0))) to \(to) (\(Int(x1)), \(Int(y1)))."))
                }
            }
        }
    }

    private func hover(_ controller: BrowserController, _ args: [String: Any], _ done: @escaping Done) {
        guard let (_, tab) = page(controller, args, done) else { return }
        point(tab, args) { [weak self] result in
            switch result {
            case .failure(let error): done(Self.failure(error.message))
            case .success(let (x, y, label)):
                self?.devTools(tab, "Input.dispatchMouseEvent", ["type": "mouseMoved", "x": x, "y": y]) { moved in
                    if case .failure(let error) = moved { return done(Self.failure(error.message)) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        done(Self.text("The mouse is over \(label) at (\(Int(x)), \(Int(y)))."))
                    }
                }
            }
        }
    }

    private func mouseClick(_ tab: ChaTab, x: Double, y: Double, button: String, count: Int,
                            _ done: @escaping (ClaudeError?) -> Void) {
        var steps: [[String: Any]] = [["type": "mouseMoved", "x": x, "y": y]]
        for click in 1...count {
            steps.append(["type": "mousePressed", "x": x, "y": y, "button": button, "clickCount": click])
            steps.append(["type": "mouseReleased", "x": x, "y": y, "button": button, "clickCount": click])
        }
        run(tab, steps.map { ("Input.dispatchMouseEvent", $0) }, done)
    }

    /// DevTools methods one after another; the first error stops them.
    private func run(_ tab: ChaTab, _ calls: [(String, [String: Any])], _ done: @escaping (ClaudeError?) -> Void) {
        guard let (method, params) = calls.first else { return done(nil) }
        devTools(tab, method, params) { [weak self] result in
            if case .failure(let error) = result { return done(error) }
            self?.run(tab, Array(calls.dropFirst()), done)
        }
    }

    private func type(_ controller: BrowserController, _ args: [String: Any], _ done: @escaping Done) {
        guard let text = args["text"] as? String else { return done(Self.failure("text is required.")) }
        guard let (id, tab) = page(controller, args, done) else { return }
        let clear = args["clear"] as? Bool == true
        let submit = args["submit"] as? Bool == true
        let typeIt: () -> Void = { [weak self] in
            guard let self else { return }
            var calls: [(String, [String: Any])] = []
            if !text.isEmpty { calls.append(("Input.insertText", ["text": text])) }
            if submit { calls += Self.keyEvents("Enter") ?? [] }
            self.run(tab, calls) { error in
                if let error { return done(Self.failure("Typing failed: \(error.message)")) }
                let what = text.count > 60 ? String(text.prefix(60)) + "…" : text
                if submit {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.waitForLoad(controller, id) {
                            done(Self.text("Typed “\(what)” and pressed Enter. Page: \(tab.title) — \(tab.currentURL)"))
                        }
                    }
                } else {
                    done(Self.text("Typed “\(what)”."))
                }
            }
        }
        if let ref = args["ref"] as? String, !ref.isEmpty {
            helper(tab, "__chaClaude.focus(\(Self.jsString(ref)), \(clear))") { result in
                switch result {
                case .failure(let error): done(Self.failure(error.message))
                case .success(let value):
                    if let problem = value as? String { return done(Self.failure(problem)) }
                    typeIt()
                }
            }
        } else if clear {
            helper(tab, "__chaClaude.clearFocused()") { _ in typeIt() }
        } else {
            typeIt()
        }
    }

    private func pressKeys(_ controller: BrowserController, _ args: [String: Any], _ done: @escaping Done) {
        guard let keys = args["keys"] as? String, !keys.isEmpty else { return done(Self.failure("keys is required.")) }
        guard let (id, tab) = page(controller, args, done) else { return }
        var calls: [(String, [String: Any])] = []
        for chord in keys.split(separator: " ") {
            guard let events = Self.keyEvents(String(chord)) else {
                return done(Self.failure("Unknown key \(chord)."))
            }
            calls += events
        }
        run(tab, calls) { [weak self] error in
            if let error { return done(Self.failure("Pressing keys failed: \(error.message)")) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.waitForLoad(controller, id) {
                    done(Self.text("Pressed \(keys). Page: \(tab.title) — \(tab.currentURL)"))
                }
            }
        }
    }

    private func scroll(_ controller: BrowserController, _ args: [String: Any], _ done: @escaping Done) {
        guard let (_, tab) = page(controller, args, done) else { return }
        let direction = args["direction"] as? String
        let ref = args["ref"] as? String
        if direction == nil, let ref, !ref.isEmpty {
            return helper(tab, "__chaClaude.point(\(Self.jsString(ref)))") { result in
                if case .failure(let error) = result { return done(Self.failure(error.message)) }
                done(Self.text("Scrolled \(ref) into view."))
            }
        }
        let amount = (args["amount"] as? NSNumber)?.doubleValue ?? 0.8
        helper(tab, "__chaClaude.scrollTarget(\(ref.map(Self.jsString) ?? "null"))") { [weak self] result in
            guard let self else { return }
            guard case .success(let value) = result, let info = value as? [String: Any],
                let x = info["x"] as? Double, let y = info["y"] as? Double,
                let width = info["w"] as? Double, let height = info["h"] as? Double
            else {
                if case .failure(let error) = result { return done(Self.failure(error.message)) }
                return done(Self.failure("Nothing to scroll."))
            }
            var dx = 0.0, dy = 0.0
            switch direction ?? "down" {
            case "up": dy = -height * amount
            case "left": dx = -width * amount
            case "right": dx = width * amount
            default: dy = height * amount
            }
            self.devTools(tab, "Input.dispatchMouseEvent",
                          ["type": "mouseWheel", "x": x, "y": y, "deltaX": dx, "deltaY": dy]) { result in
                if case .failure(let error) = result { return done(Self.failure(error.message)) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.helper(tab, "__chaClaude.position()") { result in
                        let where_ = (try? result.get()) as? String ?? ""
                        done(Self.text("Scrolled \(direction ?? "down"). \(where_)"))
                    }
                }
            }
        }
    }

    private func screenshot(_ controller: BrowserController, _ args: [String: Any], _ done: @escaping Done) {
        guard let (_, tab) = page(controller, args, done) else { return }
        // In CSS pixels, the ones click takes: a Retina page comes out twice
        // as large and every point read off it would miss. Chromium's own
        // scaling (clip.scale) loses the page's white for black, so the
        // picture is scaled here, on white.
        evaluate(tab, "innerWidth") { [weak self] width in
            guard let self else { return }
            let cssWidth = (try? width.get()) as? Double
            self.devTools(tab, "Page.captureScreenshot", ["format": "png"], timeout: 15) { result in
                switch result {
                case .failure(let error): done(Self.failure("No screenshot: \(error.message)"))
                case .success(let body):
                    guard let base64 = body["data"] as? String, let png = Data(base64Encoded: base64),
                        let jpeg = Self.jpeg(png, width: cssWidth)
                    else { return done(Self.failure("No screenshot.")) }
                    done(["content": [
                        ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
                        ["type": "text", "text": "\(tab.title) — \(tab.currentURL) (1 image pixel = 1 CSS pixel: x, y for click read straight off it)"],
                    ]])
                }
            }
        }
    }

    /// The page's picture at |width| pixels wide, on white, as JPEG.
    static func jpeg(_ png: Data, width: Double?) -> Data? {
        guard let source = NSBitmapImageRep(data: png), source.pixelsWide > 0 else { return nil }
        let scale = width.map { $0 > 0 ? min(1, $0 / Double(source.pixelsWide)) : 1 } ?? 1
        let w = max(1, Int((Double(source.pixelsWide) * scale).rounded()))
        let h = max(1, Int((Double(source.pixelsHigh) * scale).rounded()))
        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        source.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver,
                    fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return target.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private func javascript(_ controller: BrowserController, _ args: [String: Any], _ done: @escaping Done) {
        guard let code = args["code"] as? String, !code.isEmpty else { return done(Self.failure("code is required.")) }
        guard let (_, tab) = page(controller, args, done) else { return }
        evaluate(tab, code, gesture: true, timeout: 60) { result in
            switch result {
            case .failure(let error): done(Self.failure(error.message))
            case .success(let value):
                if let string = value as? String { return done(Self.text(string)) }
                if value is NSNull { return done(Self.text("undefined")) }
                let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted])) ?? Data()
                done(Self.text(String(data: data, encoding: .utf8) ?? "\(value)"))
            }
        }
    }

    // MARK: Keys

    private static let namedKeys: [String: (key: String, code: String, vk: Int, text: String?)] = [
        "enter": ("Enter", "Enter", 13, "\r"), "return": ("Enter", "Enter", 13, "\r"),
        "tab": ("Tab", "Tab", 9, nil), "escape": ("Escape", "Escape", 27, nil), "esc": ("Escape", "Escape", 27, nil),
        "backspace": ("Backspace", "Backspace", 8, nil), "delete": ("Delete", "Delete", 46, nil),
        "space": (" ", "Space", 32, " "),
        "arrowup": ("ArrowUp", "ArrowUp", 38, nil), "up": ("ArrowUp", "ArrowUp", 38, nil),
        "arrowdown": ("ArrowDown", "ArrowDown", 40, nil), "down": ("ArrowDown", "ArrowDown", 40, nil),
        "arrowleft": ("ArrowLeft", "ArrowLeft", 37, nil), "left": ("ArrowLeft", "ArrowLeft", 37, nil),
        "arrowright": ("ArrowRight", "ArrowRight", 39, nil), "right": ("ArrowRight", "ArrowRight", 39, nil),
        "home": ("Home", "Home", 36, nil), "end": ("End", "End", 35, nil),
        "pageup": ("PageUp", "PageUp", 33, nil), "pagedown": ("PageDown", "PageDown", 34, nil),
    ]

    /// Editing chords Chromium on the Mac only runs as commands.
    private static let macCommands: [String: String] = [
        "a": "selectAll", "c": "copy", "v": "paste", "x": "cut", "z": "undo",
    ]

    /// keyDown/keyUp for one key or chord ("cmd+shift+z", "Enter", "a").
    static func keyEvents(_ chord: String) -> [(String, [String: Any])]? {
        let parts = chord.split(separator: "+").map { String($0) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var modifiers = 0
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "alt", "option", "opt": modifiers |= 1
            case "ctrl", "control": modifiers |= 2
            case "cmd", "command", "meta": modifiers |= 4
            case "shift": modifiers |= 8
            default: return nil
            }
        }
        var key: String, code: String, vk: Int, text: String?
        if let named = namedKeys[last.lowercased()] {
            (key, code, vk, text) = named
        } else if last.count == 1, let scalar = last.unicodeScalars.first {
            let upper = last.uppercased()
            key = modifiers & 8 != 0 ? upper : last
            text = key
            if scalar.properties.isAlphabetic, scalar.isASCII {
                code = "Key" + upper
                vk = Int(upper.unicodeScalars.first!.value)
            } else if ("0"..."9").contains(last) {
                code = "Digit" + last
                vk = Int(scalar.value)
            } else {
                code = ""
                vk = 0
            }
        } else if last.lowercased().hasPrefix("f"), let number = Int(last.dropFirst()), (1...12).contains(number) {
            (key, code, vk, text) = ("F\(number)", "F\(number)", 111 + number, nil)
        } else {
            return nil
        }
        if modifiers & (2 | 4) != 0 { text = nil }  // a chord types nothing
        var down: [String: Any] = [
            "type": text == nil ? "rawKeyDown" : "keyDown", "key": key, "code": code,
            "windowsVirtualKeyCode": vk, "nativeVirtualKeyCode": vk, "modifiers": modifiers,
        ]
        if let text { down["text"] = text; down["unmodifiedText"] = text }
        if modifiers == 4, let command = macCommands[last.lowercased()] { down["commands"] = [command] }
        if modifiers == 12, last.lowercased() == "z" { down["commands"] = ["redo"] }
        let up: [String: Any] = ["type": "keyUp", "key": key, "code": code,
                                 "windowsVirtualKeyCode": vk, "nativeVirtualKeyCode": vk, "modifiers": modifiers]
        return [("Input.dispatchKeyEvent", down), ("Input.dispatchKeyEvent", up)]
    }

    static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    // MARK: Page helper

    /// Installed once per document; keeps element refs in a WeakMap so the
    /// same element has the same ref across read_page, find and click.
    static let helperScript = #"""
    if (!window.__chaClaude) window.__chaClaude = (() => {
      const refs = new Map(), ids = new WeakMap();
      let next = 1;
      const refOf = el => {
        let r = ids.get(el);
        if (!r) { r = 'ref_' + next++; ids.set(el, r); }
        refs.set(r, new WeakRef(el));
        return r;
      };
      const byRef = r => { const w = refs.get(r); const el = w && w.deref(); return el && el.isConnected ? el : null; };
      const clip = (s, n) => { s = (s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
      const visible = el => {
        if (!(el instanceof Element)) return false;
        const st = getComputedStyle(el);
        if (st.display === 'none' || st.visibility === 'hidden' || st.visibility === 'collapse') return false;
        if (el.getAttribute('aria-hidden') === 'true') return false;
        const r = el.getBoundingClientRect();
        return r.width > 0 || r.height > 0 || st.display === 'contents';
      };
      const ROLES = { A: 'link', BUTTON: 'button', SELECT: 'combobox', TEXTAREA: 'textbox', SUMMARY: 'button',
        H1: 'heading', H2: 'heading', H3: 'heading', H4: 'heading', H5: 'heading', H6: 'heading', IMG: 'img',
        NAV: 'navigation', MAIN: 'main', HEADER: 'banner', FOOTER: 'contentinfo', FORM: 'form', DIALOG: 'dialog',
        TABLE: 'table', UL: 'list', OL: 'list', LI: 'listitem', ASIDE: 'complementary', SECTION: 'region',
        ARTICLE: 'article', LABEL: 'label', P: 'paragraph', TR: 'row', TD: 'cell', TH: 'columnheader', IFRAME: 'iframe' };
      const INPUTS = { checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button',
        image: 'button', range: 'slider', search: 'searchbox', file: 'button', color: 'button' };
      const ACTIVE_ROLES = new Set(['button', 'link', 'checkbox', 'radio', 'tab', 'menuitem', 'menuitemcheckbox',
        'menuitemradio', 'option', 'switch', 'combobox', 'textbox', 'searchbox', 'slider', 'spinbutton', 'treeitem']);
      const role = el => {
        const explicit = el.getAttribute('role');
        if (explicit) return explicit.split(' ')[0];
        if (el.tagName === 'INPUT') return INPUTS[(el.type || 'text').toLowerCase()] || 'textbox';
        if (el.tagName === 'A' && !el.hasAttribute('href')) return 'generic';
        if (el.isContentEditable && (!el.parentElement || !el.parentElement.isContentEditable)) return 'textbox';
        return ROLES[el.tagName] || 'generic';
      };
      const interactive = el => {
        const r = role(el);
        if (ACTIVE_ROLES.has(r)) return el.tagName !== 'INPUT' || el.type !== 'hidden';
        if (el.hasAttribute('onclick')) return true;
        const ti = el.getAttribute('tabindex');
        return ti !== null && +ti >= 0 && r === 'generic' && el.innerText && el.innerText.trim().length > 0;
      };
      const labelled = el => {
        const by = el.getAttribute('aria-labelledby');
        if (by) return by.split(/\s+/).map(id => { const n = document.getElementById(id); return n ? n.innerText : ''; }).join(' ');
        if (el.id) { const l = document.querySelector('label[for="' + CSS.escape(el.id) + '"]'); if (l) return l.innerText; }
        const wrap = el.closest('label'); if (wrap && wrap !== el) return wrap.innerText;
        return '';
      };
      const name = el => {
        const n = el.getAttribute('aria-label') || labelled(el) || el.getAttribute('alt') || el.getAttribute('title');
        if (n) return clip(n, 100);
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
          return clip(el.getAttribute('placeholder') || el.getAttribute('name') || '', 100);
        }
        return clip(el.innerText || el.textContent || '', 100);
      };
      const state = el => {
        const s = [];
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
          if (el.type === 'checkbox' || el.type === 'radio') s.push(el.checked ? 'checked' : 'unchecked');
          else if (el.type === 'password') s.push(el.value ? 'value=••••' : 'empty');
          else if (el.value) s.push('value="' + clip(el.value, 60) + '"');
          if (el.placeholder && name(el) !== clip(el.placeholder, 100)) s.push('placeholder="' + clip(el.placeholder, 40) + '"');
        }
        if (el.tagName === 'SELECT') {
          const o = el.options[el.selectedIndex]; if (o) s.push('selected="' + clip(o.text, 40) + '"');
        }
        if (el.tagName === 'A' && el.href) s.push('href=' + clip(el.getAttribute('href'), 80));
        if (el.disabled || el.getAttribute('aria-disabled') === 'true') s.push('disabled');
        const exp = el.getAttribute('aria-expanded'); if (exp) s.push('expanded=' + exp);
        if (/^H[1-6]$/.test(el.tagName)) s.push('level=' + el.tagName[1]);
        if (document.activeElement === el) s.push('focused');
        return s.length ? ' (' + s.join(', ') + ')' : '';
      };
      const ownText = el => {
        let t = '';
        for (const n of el.childNodes) if (n.nodeType === 3) t += n.textContent;
        return clip(t, 200);
      };
      const STRUCT = new Set(['navigation', 'main', 'banner', 'contentinfo', 'form', 'dialog', 'table', 'list',
        'complementary', 'region', 'article', 'heading', 'img', 'iframe', 'alert', 'menu', 'tablist', 'listbox', 'grid']);
      return {
        outline(onlyActive, limit) {
          const out = [document.title + ' — ' + location.href, ''];
          let size = 0, cut = false;
          const emit = (depth, line) => {
            if (cut) return;
            const s = '  '.repeat(depth) + line;
            size += s.length + 1;
            if (size > limit) { cut = true; out.push('… (cut at ' + limit + ' characters: pass a larger max_chars or use find)'); return; }
            out.push(s);
          };
          const walk = (el, depth) => {
            if (cut || !visible(el)) return;
            if (['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'SVG'].includes(el.tagName.toUpperCase())) return;
            const r = role(el);
            if (interactive(el)) {
              emit(depth, r + ' "' + name(el) + '" [' + refOf(el) + ']' + state(el));
              if (el.tagName === 'SELECT' && !onlyActive) {
                for (const o of el.options) emit(depth + 1, 'option "' + clip(o.text, 60) + '"' + (o.selected ? ' (selected)' : ''));
              }
              return;
            }
            let d = depth;
            if (!onlyActive) {
              if (r === 'heading' || r === 'img') { emit(depth, r + ' "' + name(el) + '"' + state(el)); if (r === 'img') return; d++; }
              else if (STRUCT.has(r)) { emit(depth, r + (el.getAttribute('aria-label') ? ' "' + clip(el.getAttribute('aria-label'), 60) + '"' : '')); d++; }
              else { const t = ownText(el); if (t) emit(depth, 'text "' + t + '"'); }
            }
            if (el.shadowRoot) for (const c of el.shadowRoot.children) walk(c, d);
            for (const c of el.children) walk(c, d);
          };
          if (document.body) walk(document.body, 0);
          return out.join('\n');
        },
        text(limit) {
          const root = document.querySelector('article') || document.querySelector('main') || document.body;
          let t = (root && root.innerText || '').replace(/\n{3,}/g, '\n\n').trim();
          if (root !== document.body && t.length < 400) t = (document.body.innerText || '').trim();
          if (t.length > limit) t = t.slice(0, limit) + '\n… (cut at ' + limit + ' characters)';
          return document.title + ' — ' + location.href + '\n\n' + t;
        },
        find(query) {
          const q = query.toLowerCase(), hits = [];
          for (const el of document.querySelectorAll('body *')) {
            if (hits.length >= 25) break;
            if (!visible(el)) continue;
            const act = interactive(el);
            const hay = (act ? name(el) + ' ' + (el.getAttribute('placeholder') || '') + ' ' + (el.value || '') : ownText(el)).toLowerCase();
            if (!hay.includes(q)) continue;
            const r = el.getBoundingClientRect();
            const target = act ? el : (el.closest('a,button,[role=button],[role=link],label') || el);
            const where = ' at (' + Math.round(r.x + r.width / 2) + ', ' + Math.round(r.y + r.height / 2) + ')' +
              (r.bottom < 0 || r.top > innerHeight ? ' off screen' : '');
            hits.push(role(target) + ' "' + name(target) + '" [' + refOf(target) + ']' + state(target) + where);
          }
          return hits.length ? [...new Set(hits)].join('\n') : 'Nothing on the page matches "' + query + '".';
        },
        point(ref) {
          const el = byRef(ref);
          if (!el) return 'No element ' + ref + ' on this page now: call read_page or find again.';
          el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          const r = el.getBoundingClientRect();
          return { x: r.x + r.width / 2, y: r.y + r.height / 2, label: role(el) + ' "' + name(el) + '"' };
        },
        focus(ref, clear) {
          const el = byRef(ref);
          if (!el) return 'No element ' + ref + ' on this page now: call read_page or find again.';
          el.scrollIntoView({ block: 'center', behavior: 'instant' });
          el.focus();
          if (clear) this.clearFocused();
          return true;
        },
        clearFocused() {
          const el = document.activeElement;
          if (!el) return;
          if ('value' in el && typeof el.select === 'function') { el.select(); }
          else if (el.isContentEditable) { const s = getSelection(); s.removeAllRanges(); const r = document.createRange(); r.selectNodeContents(el); s.addRange(r); }
        },
        scrollTarget(ref) {
          const el = ref ? byRef(ref) : null;
          if (ref && !el) return 'No element ' + ref + ': call read_page or find again.';
          if (el) { const r = el.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height }; }
          return { x: innerWidth / 2, y: innerHeight / 2, w: innerWidth, h: innerHeight };
        },
        position() {
          const max = Math.max(1, document.documentElement.scrollHeight - innerHeight);
          return 'Now at ' + Math.round(scrollY) + ' of ' + max + ' px (' + Math.round(100 * scrollY / max) + '%).';
        },
      };
    })();
    """#
}

struct ClaudeError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Connecting Claude Code

enum ClaudeSetup {
    /// `claude mcp add` for this user, pointing at cha-mcp; |done| gets
    /// what to tell the user.
    static func connectClaudeCode(done: @escaping (Bool, String) -> Void) {
        ClaudeServer.shared.start()
        let bridge = ClaudeServer.bridgeURL.path
        let quoted = "'" + bridge.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // A login shell finds claude wherever it was installed.
        let script = """
            command -v claude >/dev/null 2>&1 || { echo "Claude Code is not installed (no claude command)."; exit 127; }
            claude mcp remove --scope user cha >/dev/null 2>&1
            claude mcp add --scope user cha -- \(quoted)
            """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.terminationHandler = { process in
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                done(process.terminationStatus == 0, output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        do { try task.run() } catch { done(false, error.localizedDescription) }
    }

    /// The menu's "Connect Claude Code…": runs it and says how it went.
    static func connectFromMenu() {
        connectClaudeCode { ok, output in
            let alert = NSAlert()
            if ok {
                alert.messageText = "Claude Code can use cha"
                alert.informativeText = """
                    New Claude Code sessions (in the terminal and in the Claude app's Code tab) \
                    have cha's tools: tabs, open_tab, read_page, click, type, screenshot and more. \
                    Ask Claude to "use cha" to work in your tabs.
                    """
            } else {
                alert.messageText = "Could not connect Claude Code"
                alert.informativeText = output.isEmpty ? "claude mcp add failed." : output
            }
            alert.runModal()
        }
    }
}
