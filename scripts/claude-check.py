#!/usr/bin/env python3
"""Claude's tools in cha, end to end: speaks MCP to a running cha through
the cha-mcp bridge it wrote, the way Claude Code does, and checks each tool
against a local probe page.

    scripts/claude-check.py <profile dir> <port of the probe site>

Prints CHECK lines; the exit code is the number that failed."""
import json, re, subprocess, sys, base64, struct

profile, port = sys.argv[1], sys.argv[2]
bridge = subprocess.Popen([f"{profile}/cha-mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
next_id = 0
failed = 0
passed = 0


def rpc(method, params=None):
    global next_id
    next_id += 1
    bridge.stdin.write(json.dumps({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params or {}}) + "\n")
    bridge.stdin.flush()
    while True:
        line = bridge.stdout.readline()
        if not line:
            raise SystemExit("the bridge closed")
        message = json.loads(line)
        if message.get("id") == next_id:
            return message


def call(name, **arguments):
    result = rpc("tools/call", {"name": name, "arguments": arguments})["result"]
    text = "\n".join(c.get("text", "") for c in result["content"] if c["type"] == "text")
    return result, text


def check(name, ok, detail=""):
    global failed, passed
    if ok:
        passed += 1
    else:
        failed += 1
    print(f"CHECK {'ok  ' if ok else 'FAIL'} {name}" + ("" if ok else f" — {detail[:300]}"))


init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "check", "version": "1"}})
check("initialize answers as cha", init["result"]["serverInfo"]["name"] == "cha", str(init))
bridge.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
tools = {t["name"] for t in rpc("tools/list")["result"]["tools"]}
check("tools/list has the 16 tools", len(tools) == 16 and {"tabs", "click", "screenshot"} <= tools, str(tools))

_, before = call("tabs")
front = re.search(r"\* \[(\w+)\]", before)
_, text = call("open_tab", url=f"127.0.0.1:{port}")
tab = re.search(r"\[(\w{8})\]", text)
check("open_tab opens the probe page", tab and "Claude probe" in text, text)
tab = tab.group(1) if tab else ""
_, after = call("tabs")
check("it opened in the background: the tab in front stays", front and f"* [{front.group(1)}]" in after, after)

_, outline = call("read_page", filter="interactive")
name_ref = re.search(r'textbox "Your name" \[(ref_\d+)\]', outline)
check("read_page lists the field, button, checkbox and link with refs",
      name_ref and 'button "Greet"' in outline and 'checkbox "Remember me"' in outline and 'link "Second page"' in outline, outline)
_, text = call("type", ref=name_ref.group(1) if name_ref else "", text="Stas")
_, found = call("find", query="greet")
greet = re.search(r'button "Greet" \[(ref_\d+)\]', found)
check("find gives the button's ref", greet is not None, found)
_, text = call("click", ref=greet.group(1) if greet else "")
check("type and click work in a background tab", "Greeted Stas" in text, text)
_, text = call("get_page_text")
check("get_page_text reads the page (without tab_id: the session's tab)", "Hello, Stas" in text, text)
_, text = call("javascript", code="new Promise(r => setTimeout(() => r({late: [1, 2]}), 50))")
check("javascript awaits a promise the code returns", json.loads(text) == {"late": [1, 2]} if text.startswith("{") else False, text)
_, text = call("type", ref=name_ref.group(1) if name_ref else "", text="Ann", clear=True)
_, text = call("javascript", code="document.getElementById('q').value")
check("type with clear replaces the value", text == "Ann", text)
call("press_key", keys="cmd+a Backspace")
_, text = call("javascript", code="document.getElementById('q').value || 'empty'")
check("press_key: ⌘A and Backspace empty the field", text == "empty", text)
_, text = call("scroll", direction="down", amount=2)
check("scroll moves the page", re.search(r"Now at [1-9]\d* of", text) is not None, text)
call("javascript", code="scrollTo(0, 0)")
result, text = call("screenshot")
image = next((c for c in result["content"] if c["type"] == "image"), None)
width = 0
if image:
    data = base64.b64decode(image["data"])
    i = 2  # JPEG: the SOF segment holds the size
    while i < len(data) - 9:
        marker, size = data[i + 1], struct.unpack(">H", data[i + 2:i + 4])[0]
        if marker in (0xC0, 0xC2):
            width = struct.unpack(">H", data[i + 7:i + 9])[0]
            break
        i += 2 + size
_, inner = call("javascript", code="innerWidth")
check("screenshot is in CSS pixels (as wide as the page)", image and str(width) == inner, f"{width} vs {inner}")
corner = None
if image:  # the page's empty corner must be white, not black
    import os, tempfile
    with tempfile.TemporaryDirectory() as tmp:
        open(f"{tmp}/s.jpg", "wb").write(base64.b64decode(image["data"]))
        subprocess.run(["sips", "-s", "format", "bmp", f"{tmp}/s.jpg", "--out", f"{tmp}/s.bmp"], capture_output=True)
        if os.path.exists(f"{tmp}/s.bmp"):
            bmp = open(f"{tmp}/s.bmp", "rb").read()
            offset, bpp = struct.unpack("<I", bmp[10:14])[0], struct.unpack("<H", bmp[28:30])[0] // 8
            corner = tuple(bmp[offset + 10 * bpp:offset + 10 * bpp + 3])  # a bottom row pixel
check("screenshot shows the page's white, not black", corner is not None and min(corner) > 230, str(corner))
_, box = call("find", query="Remember")
box_xy = re.search(r"at \((\d+), (\d+)\)", box)
if box_xy:
    call("click", x=int(box_xy.group(1)), y=int(box_xy.group(2)))
_, text = call("javascript", code="document.getElementById('c').checked")
check("click by x, y from find hits the checkbox", text == "true", text + " " + box)
call("javascript", code="scrollTo(0, 0)")
_, found = call("find", query="Volume")
slider = re.search(r"at \((\d+), (\d+)\)", found)
if slider:
    x, y = int(slider.group(1)), int(slider.group(2))
    call("drag", x=x - 98, y=y, to_x=x + 98, to_y=y)
_, text = call("javascript", code="document.getElementById('r').value")
check("drag moves a slider to its end", text.strip('"') in ("99", "100"), text + " " + found)
_, found = call("find", query="hover me")
hover_ref = re.search(r"\[(ref_\d+)\]", found)
call("hover", ref=hover_ref.group(1) if hover_ref else "")
_, text = call("javascript", code="document.getElementById('h').textContent")
check("hover sets off mouseenter", text == "hovered", text + " " + found)
search = re.search(r'textbox "search" \[(ref_\d+)\]', outline)
_, text = call("type", ref=search.group(1) if search else "", text="hello", submit=True)
check("type with submit sends the form", "page2.html?s=hello" in text, text)
_, text = call("navigate", url="back")
check("navigate back", "page2" not in text and f"127.0.0.1:{port}/" in text, text)
_, text = call("navigate", url=f"http://127.0.0.1:{port}/page2.html", tab_id=tab)
check("navigate to an address", "Page two" in text, text)
_, text = call("select_tab", tab_id=tab)
_, listing = call("tabs")
check("select_tab brings it to the front", f"* [{tab}]" in listing, listing)
result, text = call("click", ref="ref_9999")
check("a stale ref is an error that says what to do", result.get("isError") and "read_page" in text, text)
result, text = call("navigate", url="x", tab_id="zzzzzzzz")
check("an unknown tab is an error", result.get("isError") is True, text)
_, text = call("close_tab", tab_id=tab)
_, listing = call("tabs")
check("close_tab closes it", tab not in listing, listing)

bridge.stdin.close()
bridge.wait(timeout=5)
print(f"CHECKS passed={passed} failed={failed}")
sys.exit(failed)
