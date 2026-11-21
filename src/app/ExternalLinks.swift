import AppKit

// Links to other apps — slack:, mailto:, zoommtg:, tg: — go to macOS, which
// opens the app that handles them. Chromium in cha would drop them silently.
//
// A click or a typed address opens the app at once. A page sending itself
// there on its own (a sign-in page handing over to the Slack app) asks first,
// as Chrome does, so no site can start apps behind the user's back.
enum ExternalLinks {
    /// Opens the URL in its app; replaced by the checks, which open nothing.
    static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Asks "Open in <app>?"; replaced by the checks.
    static var ask: (_ app: String, _ answer: @escaping (Bool) -> Void) -> Void = askWithAlert

    private static var asking = false

    static func install() {
        ChaTab.openExternal = { handle($0, userGesture: $1) }
    }

    static func handle(_ string: String, userGesture: Bool) {
        guard let url = URL(string: string) ?? string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:)),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url)
        else {
            Diagnostics.linkLog("external link with no app for it: \(scheme(of: string))")
            NSSound.beep()
            return
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        if userGesture {
            Diagnostics.linkLog("external link to \(name) (\(scheme(of: string)))")
            open(url)
            return
        }
        guard !asking else { return }
        asking = true
        ask(name) { yes in
            asking = false
            Diagnostics.linkLog("external link to \(name) (\(scheme(of: string))) from a page: \(yes ? "opened" : "refused")")
            if yes { open(url) }
        }
    }

    /// The scheme only: the rest can be a sign-in token, which stays out of logs.
    static func scheme(of url: String) -> String {
        url.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "?"
    }

    private static func askWithAlert(_ app: String, _ answer: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Open \(app)?"
        alert.informativeText = "This page wants to open a link in \(app)."
        alert.addButton(withTitle: "Open \(app)")
        alert.addButton(withTitle: "Cancel")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
        } else {
            answer(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}
