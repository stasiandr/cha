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

## Status (2026-11-16)

All of the above is implemented; `scripts/check.sh` passes: 47 space checks,
the verification-code fill, and the bench:

| mark | median |
|---|---|
| window with the sidebar | 189 ms |
| first tab's browser created | 224 ms |
| page loaded | 308 ms |
| ⌘Q → windows hidden | < 1 ms |
| ⌘Q → process gone | 116 ms |

Before this work ⌘Q never quit: CEF's message loop ignores the quit while
browsers are open, so the process kept running until killed.

The same 47 checks also pass in a real window on a second monitor
(`CHA_SCREEN=1 scripts/check.sh window`); `build/shots/*-window.png` are
screen captures of it, pages included. The sidebar's first row shares the
title bar with the traffic lights, as in Arc (reference: the user's Arc
screenshots, 2026-11-16).

### Side by side with Arc

`CHA_TEST=arclike` rebuilds the reference sidebar (same tabs, second one
open, 193 pt sidebar, 1114×669 window, dark). Measured against the user's
Arc screenshot at the same scale (1.625 px/pt there, from the traffic
lights' 20 pt spacing):

| | Arc | cha |
|---|---|---|
| traffic-light row → address pill top | 32 pt | 33 pt |
| pill height | 31.5 pt | 32 pt |
| tab row pitch / active card height | 36 / 31.5 pt | 36 / 32 pt |
| pill edge → tab title | 30 pt | 30 pt |
| tab title width ("Confluence") | 65 pt | 65 pt (12.5 pt font) |
| sidebar → page card edge | 192 pt | 191 pt |
| divider when today is empty | none | none |

The comparison picture stays out of the repo (it shows private work data):
build/shots/arc-vs-cha.png.

### Interaction checks (`CHA_TEST=ui`, windowed)

Clicks on tab rows and space icons go through real AppKit events and pass
on any display. Hover and drags (tab onto a space icon, reordering tabs,
reordering space icons) need the window server's cursor, so they move the
real mouse and run only when the Mac is idle (`CHA_REAL_INPUT=1`, set by
check.sh window); otherwise they are reported as skipped, not passed. The
colour panel's live recolouring is checked through its action.

Run on 2026-11-16 with the real cursor (Mac idle, main display): 9/9 —
click opens a tab, click on a space icon switches (and back), hover shows
the close button on that row only, a tab dragged onto a space icon moves
there, dragging reorders tabs, dragging space icons reorders spaces, the
colour panel recolours the space.

### Launch and quit against Arc

Measured the same way for both (`scripts/compare-arc.sh`, run by itself
when the Mac was idle, 2026-11-17 00:46): launched through LaunchServices
until the first window is on screen, then the quit Apple event until the
windows are gone and the process has ended. Medians of 5, ms:

| | cha | Arc 1.173.1 |
|---|---|---|
| launch → window on screen | 318 | 2115 |
| quit → windows gone | 90 | 195 |
| quit → process gone | 135 | 214 |

cha opens its window ~6.6× sooner and quits ~1.6× sooner. (Arc restored
its own profile's tabs; cha a 3-space, 15-tab test profile. Neither number
includes loading the page itself.) The swipe is checked through synthesized
scroll events fed to the handler; the direction for natural scrolling
follows `isDirectionInvertedFromDevice`.

## Beyond spaces (2026-11-24, branch arc-parity)

Each line names its check: a scenario of `scripts/check.sh` (`CHA_TEST=…`)
or the `spaces` checks. All pass headless. The windowed run
(`check.sh window`) could not be done: the screen was locked all night, and
a locked screen draws no windows and gives them no pointer, so every
windowed check fails there, on main as on this branch. `check.sh window`
now says so and skips (exit 75) instead of reporting those failures.

- Command bar commands: typing "copy", "new space", "zoom"… runs Copy URL,
  Copy URL as Markdown, Duplicate, Pin, Favorite, Close, Reopen, Clear,
  Reload, Find, Zoom In/Out/Actual Size, Print, Developer Tools, View
  Source, Picture in Picture, Toggle Sidebar, New Space, Edit Space, New
  Folder, Little Window, Downloads, Split View, Boost, New Note, New Easel,
  Capture, Route Links, Extensions, Ask/Summarize, Tidy Titles; archived
  tabs are found too. (spaces)
- Arc's keys: ⌘= ⌘- ⌘0, ⌘P, ⌥⌘I, ⌥⌘U, ⌥⇧⌘C, ⌃⇧= / ⌃⇧-, ⌃⌘N, ⇧⌘2, ⇧⌘F.
- ⌃Tab / ⌃⇧Tab through recently used tabs, ⌘Tab-style. (spaces, real key
  events)
- A speaker on tabs that play sound (click mutes), and a mini player in the
  sidebar for a tab left playing. (sound)
- Split View. (split)
- Boosts: per-site CSS, script and Zap. (boost)
- Air Traffic Control: links from other apps routed to a space by rule.
  (openurl)
- Notes (⌃⌘N) and Easels (canvas: pen, text, boxes, pasted pictures).
  (notes, easel)
- Capture: ⇧⌘2, a dragged part of the page or all of it, to the clipboard.
  (capture)
- Chrome extensions from the Chrome Web Store: installed by link or ID,
  keep their store ID, loaded at launch, popups and options open from the
  Extensions window. (extensions; by hand: uBlock Origin Lite blocks ads,
  its popup opens. Dark Reader installs and its popup opens, but it did not
  restyle a page in that run: extensions that need a toolbar button click
  or Chrome's tab strip may not fully work.) Only the default profile's
  spaces get them.
- Arc Max on Apple's on-device model: Ask This Page / Summarize (⇧⌘F) and
  Tidy Tab Titles; nothing leaves the Mac, no key. (ask)
- The hidden sidebar peeks out at the left edge. (spaces)
- Close Tabs Below / Close Other Tabs, a "Copied" toast, each space's own
  archive time (12 h, 24 h, 7 d, 30 d, never). (spaces)

Done earlier: profiles per space, Little Arc, Peek, picture in picture,
the meeting card, the secret space, per-space history.

Not done:
- Sync between devices (Arc Sync). It would go through cloudsync
  (sync.stasiandr.com), but needs a sync identity created on that server,
  its recovery phrase kept by the user, and a second Mac with cha to sync
  with; none of that should be set up without the user.
- An extensions toolbar (action buttons on pages): popups open from the
  Extensions window instead.
