import AppKit

// Arc's Notes: ⌃⌘N opens a note as a tab of the space, to jot something
// next to the pages. It is a page cha makes itself: rich text (⌘B, ⌘I, ⌘U,
// lists by "- "), its first line the tab's name. What is written is kept in
// Notes/<id>.json in the profile as it is typed, and comes back when the tab
// is opened again, after a restart too.
struct Note: Codable, Equatable {
    var id: UUID
    var html = ""
    var title = ""
    var edited = Date()
}

enum NoteStore {
    static let directory: URL = {
        let dir = Persistence.directory.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    static func load(_ id: UUID) -> Note {
        guard let data = try? Data(contentsOf: file(id)), let note = try? JSONDecoder().decode(Note.self, from: data)
        else { return Note(id: id) }
        return note
    }

    static func save(_ note: Note) {
        guard let data = try? JSONEncoder().encode(note) else { return }
        try? data.write(to: file(note.id), options: .atomic)
    }

    static let marker = "cha-note:"

    /// The note a tab's address is, if it is one.
    static func id(in url: String) -> UUID? {
        guard url.hasPrefix("data:"), let range = url.range(of: marker) else { return nil }
        return UUID(uuidString: String(url[range.upperBound...].prefix(36)))
    }

    /// The page of a note. Its contents come from cha once it has loaded.
    static func url(_ id: UUID) -> String {
        let page = """
            <!doctype html><meta charset="utf-8"><!--\(marker)\(id.uuidString)--><title>New Note</title>
            <style>
            :root { color-scheme: light dark; }
            body { margin: 0; font: 16px/1.55 -apple-system, system-ui, sans-serif; }
            #note { max-width: 720px; margin: 0 auto; padding: 56px 48px 120px; min-height: 80vh; outline: none; }
            #note:empty::before { content: 'Write something…'; color: GrayText; }
            #note > div:first-child, #note > h1:first-child { font-size: 28px; font-weight: 700; line-height: 1.25; margin-bottom: 12px; }
            </style>
            <div id="note" contenteditable="true" spellcheck="true"></div>
            <script>
            const note = document.getElementById('note');
            const id = '\(id.uuidString)';
            let timer = null;
            const name = () => (note.innerText.split('\\n').find(l => l.trim()) || '').trim().slice(0, 80);
            const save = () => {
              document.title = name() || 'New Note';
              console.log('__cha_app__ note ' + id + ' ' + JSON.stringify({ html: note.innerHTML, title: name() }));
            };
            note.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(save, 300); document.title = name() || 'New Note'; });
            window.__chaNoteLoad = (html) => {
              note.innerHTML = html;
              document.title = name() || 'New Note';
              const range = document.createRange(); range.selectNodeContents(note); range.collapse(false);
              getSelection().removeAllRanges(); getSelection().addRange(range);
              note.focus();
            };
            note.focus();
            </script>
            """
        let encoded = page.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "#%&+")))
            ?? page
        return "data:text/html;charset=utf-8," + encoded
    }
}

extension BrowserController {
    /// ⌃⌘N: a new note, as a tab of the space in front.
    func newNote() {
        newTab(url: NoteStore.url(UUID()))
    }

    /// Once a note's page has loaded, what was written comes back into it.
    func fillNote(_ tab: ChaTab) {
        guard let id = NoteStore.id(in: tab.currentURL) else { return }
        let note = NoteStore.load(id)
        guard !note.html.isEmpty,
            let json = String(data: (try? JSONEncoder().encode(note.html)) ?? Data(), encoding: .utf8)
        else { return }
        tab.executeJavaScript("window.__chaNoteLoad && window.__chaNoteLoad(\(json))")
    }

    /// The page saying what is written now.
    func saveNote(_ message: String) {
        let parts = message.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "note", let id = UUID(uuidString: parts[1]),
            let data = parts[2].data(using: .utf8),
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }
        NoteStore.save(Note(id: id, html: body["html"] ?? "", title: body["title"] ?? "", edited: Date()))
    }
}
