import AppKit
import UniformTypeIdentifiers

// Typing the verification code into the page. The page is Chromium's, so the
// only way in is a script: find the code field, set its value the way the
// framework behind the form expects, and tell it the field changed.
enum CodeFill {
    // |strict| only accepts a field that says it wants a one-time code, and
    // leaves a filled one alone: that is what runs unasked after a page loads.
    static func script(code: String, strict: Bool) -> String {
        let quoted = code.replacingOccurrences(of: "'", with: "")
        return #"""
        (function (code, strict) {
          function usable(el) {
            if (el.disabled || el.readOnly) return false;
            if (!/^(text|tel|number|password)$/.test(el.type || 'text')) return false;
            const box = el.getBoundingClientRect();
            return box.width > 4 && box.height > 4;
          }
          const inputs = Array.prototype.filter.call(
            document.querySelectorAll('input'), usable);
          const boxes = inputs.filter(function (el) { return el.maxLength === 1; });
          const named = /(otp|totp|2fa|mfa|one[-_ ]?time|onetime|verification|verify|securitycode|authcode|passcode|token)/i;
          const vague = /(^|[^a-z])(code|pin)([^a-z]|$)/i;

          function words(el) {
            return [el.name, el.id, el.getAttribute('autocomplete'),
                    el.placeholder, el.getAttribute('aria-label'),
                    el.className].filter(Boolean).join(' ');
          }
          function rank(el) {
            if (/one-time-code/i.test(el.getAttribute('autocomplete') || '')) return 3;
            if (named.test(words(el))) return 2;
            if (boxes.length >= code.length && el.maxLength === 1) return 2;
            if (!strict && vague.test(words(el))) return 1;
            if (!strict && el === document.activeElement) return 1;
            return 0;
          }

          function fill(el, value) {
            const setter = Object.getOwnPropertyDescriptor(
              HTMLInputElement.prototype, 'value').set;
            el.focus();
            setter.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            el.dispatchEvent(new KeyboardEvent('keyup', {
              bubbles: true, key: value.slice(-1) || 'Unidentified' }));
          }

          const ranked = inputs
            .map(function (el, i) { return { el: el, rank: rank(el), i: i }; })
            .filter(function (item) { return item.rank > 0; })
            .sort(function (a, b) { return b.rank - a.rank || a.i - b.i; });
          if (!ranked.length) return false;

          // A row of single-character boxes takes one digit each.
          const target = ranked[0].el;
          if (target.maxLength === 1 && boxes.length >= code.length) {
            const row = boxes.slice(boxes.indexOf(target), boxes.indexOf(target) + code.length);
            if (strict && row.some(function (el) { return el.value; })) return false;
            row.forEach(function (el, i) { fill(el, code[i]); });
            row[row.length - 1].focus();
            return true;
          }
          if (strict && target.value) return false;
          fill(target, code);
          return true;
        })('\#(quoted)', \#(strict));
        """#
    }
}

extension BrowserController {
    var activeHost: String {
        guard let url = activeTab?.currentURL, let host = URL(string: url)?.host
        else { return "" }
        return host
    }

    // ⇧⌘V: fill the code this site needs. One match fills straight away;
    // anything else asks, so the wrong code never lands in a form.
    func fillVerificationCode() {
        let store = CodeStore.shared
        let matches = store.matches(host: activeHost)
        if matches.count == 1 {
            fill(matches[0])
        } else if matches.isEmpty && store.entries.count == 1 {
            fill(store.entries[0])
        } else if store.entries.isEmpty {
            addVerificationCode()
        } else {
            showCodesMenu()
        }
    }

    func fill(_ entry: CodeEntry, strict: Bool = false) {
        guard let tab = activeTab, let code = entry.code else { return }
        // Filling here is what tells us where this code belongs.
        if entry.site.isEmpty && !activeHost.isEmpty {
            CodeStore.shared.setSite(activeHost, for: entry.id)
        }
        tab.executeJavaScript(CodeFill.script(code: code, strict: strict))
    }

    // After a page loads, a code whose site matches fills itself in — but only
    // into a field that asked for a one-time code and is still empty.
    func autofillVerificationCode(in tab: ChaTab) {
        guard let url = URL(string: tab.currentURL), let host = url.host else { return }
        let matches = CodeStore.shared.matches(host: host)
        guard matches.count == 1, let code = matches[0].code else { return }
        tab.executeJavaScript(CodeFill.script(code: code, strict: true))
    }

    // MARK: - Managing codes

    func addVerificationCode() {
        let alert = NSAlert()
        alert.messageText = "Add a verification code"
        alert.informativeText =
            "Paste the otpauth:// link or the setup key from the Passwords app."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let secretField = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        secretField.placeholderString = "otpauth://totp/… or setup key"
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        if OTPAuth.parse(pasted) != nil { secretField.stringValue = pasted }
        let siteField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        siteField.placeholderString = "Site, e.g. auth.example.com"
        siteField.stringValue = activeHost

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        accessory.addSubview(secretField)
        accessory.addSubview(siteField)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = secretField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let site = siteField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let entry = OTPAuth.parse(secretField.stringValue, site: site) else {
            report("That is not a verification code", "Expected an otpauth:// link or a base32 setup key.")
            return
        }
        CodeStore.shared.add(entry)
    }

    // The Passwords app exports the codes with the logins; only the otpauth
    // column is read, and the file is the user's to delete afterwards.
    func importVerificationCodes() {
        let panel = NSOpenPanel()
        panel.message = "Choose the CSV exported from the Passwords app"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let count = CodeStore.shared.importPasswordsCSV(text)
        report(
            count > 0 ? "Imported \(count) verification code\(count == 1 ? "" : "s")"
                : "No verification codes in that file",
            count > 0
                ? "Delete the export file — it holds your passwords in the clear."
                : "The export needs the OTPAuth column, which the Passwords app writes.")
    }

    // The codes, with what each one reads right now. Filled in on demand so
    // the menu shows the code that is valid when it opens.
    func populateCodesMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let target = MenuTarget.shared
        for entry in CodeStore.shared.entries {
            let code = entry.code ?? "??????"
            let site = entry.site.isEmpty ? "any site" : entry.site
            let item = NSMenuItem(
                title: "\(entry.label) — \(code)  ·  \(site), \(entry.secondsRemaining())s",
                action: #selector(MenuTarget.fillCodeEntry(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = entry.id

            let actions = NSMenu()
            for (title, selector) in [
                ("Fill", #selector(MenuTarget.fillCodeEntry(_:))),
                ("Copy Code", #selector(MenuTarget.copyCodeEntry(_:))),
                ("Remove", #selector(MenuTarget.removeCodeEntry(_:))),
            ] {
                let action = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                action.target = target
                action.representedObject = entry.id
                actions.addItem(action)
            }
            item.submenu = actions
            menu.addItem(item)
        }
        if CodeStore.shared.entries.isEmpty {
            let empty = NSMenuItem(
                title: "No verification codes", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(
            title: "Add Verification Code…", action: #selector(MenuTarget.addCode),
            keyEquivalent: "")
        add.target = target
        menu.addItem(add)
        let importItem = NSMenuItem(
            title: "Import from Passwords Export…",
            action: #selector(MenuTarget.importCodes), keyEquivalent: "")
        importItem.target = target
        menu.addItem(importItem)
    }

    // ⇧⌘V with more than one candidate: pick from a menu over the page.
    private func showCodesMenu() {
        let menu = NSMenu()
        populateCodesMenu(menu)
        let content = contentScreenRect
        let point = window.convertPoint(
            fromScreen: NSPoint(x: content.midX - 120, y: content.maxY - 60))
        menu.popUp(positioning: nil, at: point, in: window.contentView)
    }

    private func report(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

// Keeps the File submenu showing live codes without a timer.
final class CodesMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = CodesMenuDelegate()
    weak var controller: BrowserController?

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller?.populateCodesMenu(menu)
    }
}
