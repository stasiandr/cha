import AppKit

// Arc's Easels: a free canvas as a tab of the space. Draw with the pen, put
// text anywhere, frame things with boxes, paste pictures (a Capture of a
// page is one ⌘V away), move things with the pointer, Delete removes, ⌘Z
// undoes. Kept in Easels/<id>.json as it changes, back when the tab opens
// again. Like a note, it is a page cha makes (data: with a marker).
enum EaselStore {
    static let directory: URL = {
        let dir = Persistence.directory.appendingPathComponent("Easels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let marker = "cha-easel:"

    static func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    static func id(in url: String) -> UUID? {
        guard url.hasPrefix("data:"), let range = url.range(of: marker) else { return nil }
        return UUID(uuidString: String(url[range.upperBound...].prefix(36)))
    }

    /// The saved board: {"title": …, "items": […]}, as the page sent it.
    static func load(_ id: UUID) -> String? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ id: UUID, json: String) {
        try? Data(json.utf8).write(to: file(id), options: .atomic)
    }

    static func url(_ id: UUID) -> String {
        let page = """
            <!doctype html><meta charset="utf-8"><!--\(marker)\(id.uuidString)--><title>Easel</title>
            <style>
            :root { color-scheme: light dark; --ink: CanvasText; }
            html, body { margin: 0; height: 100%; overflow: hidden; font: 14px -apple-system, system-ui, sans-serif;
              background: Canvas; background-image: radial-gradient(color-mix(in srgb, CanvasText 14%, transparent) 1px, transparent 1px);
              background-size: 22px 22px; }
            #board { position: absolute; inset: 0; }
            #ink { position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none; overflow: visible; }
            .item { position: absolute; }
            .item.sel { outline: 2px solid #0a84ff; outline-offset: 2px; }
            .text { min-width: 40px; padding: 2px 4px; white-space: pre-wrap; outline: none; line-height: 1.35; }
            .box { border: 2.5px solid; border-radius: 6px; }
            .pic { border-radius: 6px; box-shadow: 0 2px 10px rgba(0,0,0,.18); }
            #tools { position: fixed; top: 14px; left: 50%; transform: translateX(-50%); display: flex; gap: 4px; padding: 5px;
              border-radius: 12px; background: color-mix(in srgb, Canvas 88%, CanvasText 12%); box-shadow: 0 2px 12px rgba(0,0,0,.15); z-index: 10; }
            #tools button { border: 0; background: transparent; color: CanvasText; font: 13px system-ui, -apple-system, sans-serif; padding: 6px 10px; border-radius: 8px; cursor: default; }
            #tools button.on { background: color-mix(in srgb, CanvasText 16%, transparent); }
            #tools .dot { width: 18px; height: 18px; padding: 0; margin: 4px 2px; border-radius: 50%; }
            #tools .dot.on { outline: 2px solid CanvasText; outline-offset: 1px; }
            </style>
            <div id="tools">
              <button data-tool="move" class="on">Move</button><button data-tool="pen">Pen</button>
              <button data-tool="text">Text</button><button data-tool="box">Box</button>
              <span style="width:8px"></span>
              <button class="dot on" data-color="CanvasText" style="background:CanvasText"></button>
              <button class="dot" data-color="#ff3b30" style="background:#ff3b30"></button>
              <button class="dot" data-color="#0a84ff" style="background:#0a84ff"></button>
              <button class="dot" data-color="#34c759" style="background:#34c759"></button>
              <button class="dot" data-color="#ff9f0a" style="background:#ff9f0a"></button>
            </div>
            <div id="board"><svg id="ink"></svg></div>
            <script>
            const id = '\(id.uuidString)';
            const board = document.getElementById('board'), ink = document.getElementById('ink');
            let items = [], tool = 'move', color = 'CanvasText', selected = null, history = [], timer = null;
            const uid = () => Math.random().toString(36).slice(2, 10);
            const snapshot = () => JSON.stringify(items);
            const remember = () => { history.push(snapshot()); if (history.length > 100) history.shift(); };
            const name = () => { const t = items.find(i => i.type === 'text' && i.text.trim()); return t ? t.text.trim().split('\\n')[0].slice(0, 60) : 'Easel'; };
            const save = () => {
              clearTimeout(timer);
              timer = setTimeout(() => console.log('__cha_app__ easel ' + id + ' ' + JSON.stringify({ title: name(), items })), 250);
              document.title = name();
            };
            const draw = () => {
              board.querySelectorAll('.item').forEach(e => e.remove());
              ink.innerHTML = '';
              for (const it of items) {
                if (it.type === 'path') {
                  const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
                  p.setAttribute('d', 'M' + it.points.map(q => q.join(' ')).join(' L'));
                  p.setAttribute('fill', 'none'); p.setAttribute('stroke', it.color); p.setAttribute('stroke-width', 3);
                  p.setAttribute('stroke-linecap', 'round'); p.setAttribute('stroke-linejoin', 'round');
                  if (it.id === selected) p.setAttribute('stroke-dasharray', '6 4');
                  ink.append(p);
                  continue;
                }
                const e = document.createElement(it.type === 'image' ? 'img' : 'div');
                e.className = 'item ' + ({ text: 'text', box: 'box', image: 'pic' })[it.type] + (it.id === selected ? ' sel' : '');
                e.dataset.id = it.id;
                Object.assign(e.style, { left: it.x + 'px', top: it.y + 'px' });
                if (it.type === 'text') { e.textContent = it.text; e.style.color = it.color; e.style.fontSize = (it.size || 18) + 'px'; }
                if (it.type === 'box') { Object.assign(e.style, { width: it.w + 'px', height: it.h + 'px', borderColor: it.color }); }
                if (it.type === 'image') { e.src = it.src; e.style.width = it.w + 'px'; e.draggable = false; }
                board.append(e);
              }
            };
            const setTool = (t) => { tool = t; document.querySelectorAll('[data-tool]').forEach(b => b.classList.toggle('on', b.dataset.tool === t)); };
            document.querySelectorAll('[data-tool]').forEach(b => b.onclick = () => setTool(b.dataset.tool));
            document.querySelectorAll('[data-color]').forEach(b => b.onclick = () => {
              color = b.dataset.color; document.querySelectorAll('.dot').forEach(d => d.classList.toggle('on', d === b));
              const it = items.find(i => i.id === selected); if (it) { remember(); it.color = color; draw(); save(); }
            });
            const editText = (it) => {
              const e = board.querySelector('[data-id="' + it.id + '"]');
              e.contentEditable = 'true'; e.focus();
              const r = document.createRange(); r.selectNodeContents(e); r.collapse(false); getSelection().removeAllRanges(); getSelection().addRange(r);
              e.oninput = () => { it.text = e.innerText; save(); };
              e.onblur = () => { e.contentEditable = 'false'; if (!it.text.trim()) { items = items.filter(i => i !== it); draw(); } save(); };
            };
            let drag = null;
            board.addEventListener('pointerdown', ev => {
              if (ev.target.isContentEditable) return;
              const x = ev.clientX, y = ev.clientY;
              if (tool === 'pen') { remember(); const it = { id: uid(), type: 'path', color, points: [[x, y]] }; items.push(it); drag = { pen: it }; }
              else if (tool === 'box') { remember(); const it = { id: uid(), type: 'box', color, x, y, w: 1, h: 1 }; items.push(it); drag = { box: it, x, y }; }
              else if (tool === 'text') {
                remember(); const it = { id: uid(), type: 'text', color, x, y: y - 12, text: '', size: 18 };
                items.push(it); selected = it.id; draw(); editText(it); setTool('move'); ev.preventDefault(); return;
              } else {
                const hit = ev.target.closest('.item');
                selected = hit ? hit.dataset.id : null;
                const it = items.find(i => i.id === selected);
                if (it) { remember(); drag = { move: it, dx: x - it.x, dy: y - it.y }; }
              }
              board.setPointerCapture(ev.pointerId); draw();
            });
            board.addEventListener('pointermove', ev => {
              if (!drag) return;
              const x = ev.clientX, y = ev.clientY;
              if (drag.pen) drag.pen.points.push([x, y]);
              if (drag.box) Object.assign(drag.box, { x: Math.min(x, drag.x), y: Math.min(y, drag.y), w: Math.abs(x - drag.x), h: Math.abs(y - drag.y) });
              if (drag.move) { drag.move.x = x - drag.dx; drag.move.y = y - drag.dy; }
              draw();
            });
            board.addEventListener('pointerup', () => { if (drag) { drag = null; save(); } });
            board.addEventListener('dblclick', ev => { const hit = ev.target.closest('.text'); const it = hit && items.find(i => i.id === hit.dataset.id); if (it) editText(it); });
            document.addEventListener('keydown', ev => {
              if (document.activeElement && document.activeElement.isContentEditable) { if (ev.key === 'Escape') document.activeElement.blur(); return; }
              if ((ev.key === 'Backspace' || ev.key === 'Delete') && selected) { remember(); items = items.filter(i => i.id !== selected); selected = null; draw(); save(); }
              if (ev.key === 'z' && (ev.metaKey || ev.ctrlKey) && history.length) { items = JSON.parse(history.pop()); selected = null; draw(); save(); ev.preventDefault(); }
              if (ev.key === 'v' && !ev.metaKey) setTool('move');
              if (ev.key === 'p') setTool('pen'); if (ev.key === 't') setTool('text'); if (ev.key === 'b') setTool('box');
            });
            document.addEventListener('paste', ev => {
              if (document.activeElement && document.activeElement.isContentEditable) return;
              for (const item of ev.clipboardData.items) {
                if (item.type.startsWith('image/')) {
                  const reader = new FileReader();
                  reader.onload = () => {
                    const img = new Image();
                    img.onload = () => {
                      remember();
                      const w = Math.min(img.naturalWidth / (window.devicePixelRatio || 1), innerWidth * 0.6);
                      items.push({ id: uid(), type: 'image', src: reader.result, x: 60 + items.length * 12, y: 80 + items.length * 12, w });
                      draw(); save();
                    };
                    img.src = reader.result;
                  };
                  reader.readAsDataURL(item.getAsFile());
                  ev.preventDefault(); return;
                }
                if (item.type === 'text/plain') {
                  item.getAsString(text => { remember(); items.push({ id: uid(), type: 'text', color, x: 80, y: 100 + items.length * 14, text, size: 18 }); draw(); save(); });
                  ev.preventDefault(); return;
                }
              }
            });
            window.__chaEaselLoad = (board) => { items = (board && board.items) || []; history = []; draw(); document.title = name(); };
            window.__chaEaselAdd = (it) => { remember(); items.push(Object.assign({ id: uid() }, it)); draw(); save(); };
            draw();
            </script>
            """
        let encoded = page.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "#%&+")))
            ?? page
        return "data:text/html;charset=utf-8," + encoded
    }
}

extension BrowserController {
    func newEasel() {
        newTab(url: EaselStore.url(UUID()))
    }

    func fillEasel(_ tab: ChaTab) {
        guard let id = EaselStore.id(in: tab.currentURL), let json = EaselStore.load(id) else { return }
        tab.executeJavaScript("window.__chaEaselLoad && window.__chaEaselLoad(\(json))")
    }

    func saveEasel(_ message: String) {
        let parts = message.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "easel", let id = UUID(uuidString: parts[1]),
            (try? JSONSerialization.jsonObject(with: Data(parts[2].utf8))) != nil
        else { return }
        EaselStore.save(id, json: parts[2])
    }
}
