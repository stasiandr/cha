# Arc parity: spaces, launch and quit

What "like Arc" means for cha, as checks. Each line names how it is verified:
`shot` — an offscreen picture from `scripts/check.sh` (build/shots), `log` — a
scenario's log line, `bench` — `scripts/bench.py`.

## Sidebar layout (top to bottom)

- Traffic lights, sidebar toggle, back / forward / reload; arrows quiet until hovered. (shot)
- Address pill showing the host only, the full URL in the command bar. (shot)
- Favourites: a grid of tiles shared by every space, at most 4 per row. (shot, log)
- The space's own page, which slides sideways when the space changes:
  - its name (and icon) as a header, with a menu on hover; (shot)
  - pinned tabs and folders; (shot)
  - a divider with "Clear" that archives the unpinned tabs; (shot, log)
  - "+ New Tab", then today's (unpinned) tabs, newest at the top. (shot)
- Bottom bar: archive (library) on the left, one icon per space in the middle,
  "+" on the right for a new space or folder. (shot)

## Spaces

- Each space has a name, an icon (emoji or symbol) and a theme colour; the
  whole window wears its gradient, in light and dark mode. (shot)
- Switch by clicking its icon, ⌃1…⌃9, ⌥⌘← / ⌥⌘→, or a two-finger swipe on the
  sidebar that follows the fingers and blends the colours. (log)
- Each space remembers its open tab. (log)
- New space opens an editor page in the sidebar: name, icon, colour. (shot, log)
- Rename, change icon, change colour, delete (asking when it has tabs),
  reorder by dragging icons. (log)
- A tab moves to another space by drag onto its icon or Move to Space ▸. (log)

## Tabs inside a space

- Pinned tabs remember the address they were pinned at; ⌘W unloads one
  without removing it; "Back to pinned address" when it wandered off. (log)
- Unpinned tabs not looked at for 12 hours go to the archive on launch;
  archived tabs are listed and searchable from the command bar. (log)
- Folders in the pinned section: create, rename, open/close, drag tabs in. (log)
- Favicons survive a restart, so the sidebar looks right before pages load. (shot)

## Launch and quit (bench, median of 5, headless, Apple Silicon)

- Window with the sidebar on screen: under 250 ms from exec.
- Active tab's page loaded (local page): under 500 ms.
- ⌘Q: windows gone at once; process gone under 300 ms. Never hangs.
- Only the active tab of each space is loaded at launch; others load on demand.
