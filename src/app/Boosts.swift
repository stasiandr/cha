import AppKit
import SwiftUI

// Arc's Boosts: a site made your own. Per host: CSS laid over its pages,
// a script run on each of them, and "Zap": click things on the page to hide
// them for good. On and off with a switch; kept in boosts.json in the
// profile. Every tab of the site follows an edit at once.
struct Boost: Codable, Equatable {
    var host: String
    var enabled = true
    var css = ""
    var js = ""
    var zapped: [String] = []  // CSS selectors of what was zapped.

    /// What the page gets: the CSS, then the zapped things hidden.
    var fullCSS: String {
        let hidden = zapped.map { "\($0) { display: none !important; }" }.joined(separator: "\n")
        return [css, hidden].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var isEmpty: Bool { css.isEmpty && js.isEmpty && zapped.isEmpty }
}

final class BoostStore: ObservableObject {
    static let shared = BoostStore()

    @Published private(set) var boosts: [String: Boost] = [:]
    private let file = Persistence.directory.appendingPathComponent("boosts.json")

    init() {
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Boost].self, from: data) {
            for boost in list { boosts[boost.host] = boost }
        }
    }

    /// "www.youtube.com" and "youtube.com" are one site.
    static func site(_ url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func boost(for url: String) -> Boost? { BoostStore.site(url).flatMap { boosts[$0] } }

    func set(_ boost: Boost) {
        if boost.isEmpty && boost.enabled { boosts[boost.host] = nil } else { boosts[boost.host] = boost }
        save()
    }

    func remove(_ host: String) {
        boosts[host] = nil
        save()
    }

    private func save() {
        let list = boosts.values.sorted { $0.host < $1.host }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// The script that puts the boost on a page (or takes it off): the CSS
    /// replaced in place, the script run once per page.
    static func script(for boost: Boost?) -> String {
        let on = boost?.enabled == true
        let css = on ? boost?.fullCSS ?? "" : ""
        let js = on ? boost?.js ?? "" : ""
        let cssJSON = String(data: (try? JSONEncoder().encode(css)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        var script = """
            (() => {
              const css = \(cssJSON);
              let s = document.getElementById('__cha_boost');
              if (!css) { if (s) s.remove(); return; }
              if (!s) {
                s = document.createElement('style'); s.id = '__cha_boost';
                (document.head || document.documentElement).append(s);
              }
              if (s.textContent !== css) s.textContent = css;
            })();
            """
        if !js.isEmpty {
            script += "\nif (!window.__chaBoostRan) { window.__chaBoostRan = true; try {\n\(js)\n} catch (e) { console.error('boost', e); } }"
        }
        return script
    }

    /// Zap mode: the element under the pointer is outlined; a click hides it
    /// and sends its selector back; Esc ends it.
    static let zapScript = """
        (() => {
          if (window.__chaZapEnd) return;
          const box = document.createElement('div');
          box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #ff3b30;background:rgba(255,59,48,.15);border-radius:3px;display:none';
          document.documentElement.append(box);
          let target = null;
          const selector = (el) => {
            if (el.id && /^[A-Za-z][\\w-]*$/.test(el.id)) return '#' + el.id;
            const parts = [];
            while (el && el.nodeType === 1 && el !== document.documentElement) {
              let part = el.tagName.toLowerCase();
              if (el.id && /^[A-Za-z][\\w-]*$/.test(el.id)) { parts.unshift('#' + el.id); break; }
              const same = el.parentElement ? [...el.parentElement.children].filter(c => c.tagName === el.tagName) : [];
              if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
              parts.unshift(part);
              el = el.parentElement;
            }
            return parts.join(' > ');
          };
          const move = (e) => {
            target = e.target;
            const r = target.getBoundingClientRect();
            Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
          };
          const click = (e) => {
            e.preventDefault(); e.stopPropagation();
            const el = e.target;
            if (!el || el === document.body || el === document.documentElement) return;
            el.style.setProperty('display', 'none', 'important');
            console.log('__cha_app__ zap ' + selector(el));
          };
          const key = (e) => { if (e.key === 'Escape') { end(); console.log('__cha_app__ zap-end'); } };
          const end = () => {
            box.remove();
            document.removeEventListener('mousemove', move, true);
            document.removeEventListener('click', click, true);
            document.removeEventListener('keydown', key, true);
            window.__chaZapEnd = null;
          };
          document.addEventListener('mousemove', move, true);
          document.addEventListener('click', click, true);
          document.addEventListener('keydown', key, true);
          window.__chaZapEnd = end;
        })();
        """
}

extension BrowserController {
    /// Each new page of a boosted site, and again once it has loaded (some
    /// pages replace their <head>).
    func applyBoost(to tab: ChaTab) {
        guard let boost = BoostStore.shared.boost(for: tab.currentURL) else { return }
        tab.executeJavaScript(BoostStore.script(for: boost))
    }

    /// After an edit: every open tab of the site, at once.
    func applyBoost(site: String) {
        let boost = BoostStore.shared.boosts[site]
        for tab in liveTabs.values where BoostStore.site(tab.currentURL) == site {
            tab.executeJavaScript(BoostStore.script(for: boost))
        }
    }

    func openBoostEditor() {
        guard let tab = activeTab, let site = BoostStore.site(tab.currentURL),
            History.keeps(tab.currentURL)
        else {
            NSSound.beep()
            return
        }
        boostSite = site
        let panel = boostPanel ?? makeBoostPanel()
        boostPanel = panel
        repositionBoostPanel()
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        if Diagnostics.quiet { panel.orderFront(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    func closeBoostEditor() {
        stopZapping()
        guard let panel = boostPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        boostSite = nil
    }

    func repositionBoostPanel() {
        guard let panel = boostPanel else { return }
        let page = contentScreenRect
        let size = NSSize(width: 320, height: min(520, page.height - 24))
        panel.setFrame(NSRect(x: page.maxX - size.width - 12, y: page.maxY - size.height - 12,
                              width: size.width, height: size.height), display: true)
    }

    private func makeBoostPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
                            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = NSHostingView(rootView: BoostEditor(controller: self, store: .shared))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) {
            [weak self] _ in
            self?.stopZapping()
            self?.boostSite = nil
        }
        return panel
    }

    func updateBoost(_ change: (inout Boost) -> Void) {
        guard let site = boostSite else { return }
        var boost = BoostStore.shared.boosts[site] ?? Boost(host: site)
        change(&boost)
        BoostStore.shared.set(boost)
        applyBoost(site: site)
    }

    func startZapping() {
        guard let tab = activeTab else { return }
        zapping = true
        tab.executeJavaScript(BoostStore.zapScript)
        if !Diagnostics.quiet { tab.focus() }
    }

    func stopZapping() {
        guard zapping else { return }
        zapping = false
        activeTab?.executeJavaScript("window.__chaZapEnd && window.__chaZapEnd()")
    }

    func tab(_ tab: ChaTab, didSendMessage message: String) {
        if message.hasPrefix("note ") {
            saveNote(message)
        } else if message.hasPrefix("easel ") {
            saveEasel(message)
        } else if message.hasPrefix("zap "), let site = BoostStore.site(tab.currentURL) {
            let selector = String(message.dropFirst(4))
            var boost = BoostStore.shared.boosts[site] ?? Boost(host: site)
            if !boost.zapped.contains(selector) { boost.zapped.append(selector) }
            BoostStore.shared.set(boost)
            applyBoost(site: site)
        } else if message == "zap-end" {
            zapping = false
        }
    }

    func tabDidStartLoad(_ tab: ChaTab) {
        applyBoost(to: tab)
    }
}

struct BoostEditor: View {
    @ObservedObject var controller: BrowserController
    @ObservedObject var store: BoostStore

    var body: some View {
        if let site = controller.boostSite {
            let boost = store.boosts[site] ?? Boost(host: site)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "paintbrush.fill").foregroundStyle(Color.accentColor)
                    Text("Boost · \(site)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Toggle("", isOn: Binding(get: { boost.enabled }, set: { on in controller.updateBoost { $0.enabled = on } }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .help("Boost on or off")
                }
                .padding(.top, 18)
                Text("CSS").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                code(Binding(get: { boost.css }, set: { text in controller.updateBoost { $0.css = text } }))
                Text("JavaScript, run on each page").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                code(Binding(get: { boost.js }, set: { text in controller.updateBoost { $0.js = text } }))
                HStack {
                    Button(controller.zapping ? "Zapping… (Esc)" : "Zap") {
                        controller.zapping ? controller.stopZapping() : controller.startZapping()
                    }
                    .help("Click things on the page to hide them on this site")
                    Spacer()
                    if !boost.zapped.isEmpty {
                        Button("Bring back \(boost.zapped.count) zapped") { controller.updateBoost { $0.zapped = [] } }
                    }
                }
                HStack {
                    Button("Delete Boost", role: .destructive) {
                        store.remove(site)
                        controller.applyBoost(site: site)
                        controller.closeBoostEditor()
                    }
                    .disabled(store.boosts[site] == nil)
                    Spacer()
                    Button("Done") { controller.closeBoostEditor() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func code(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 11.5, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .frame(minHeight: 90)
    }
}
