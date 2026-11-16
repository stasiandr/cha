# cha

An Arc-like browser for macOS: a native Swift/AppKit interface on top of
Chromium via CEF.

Chrome style keeps Chromium's own password manager and autofill, but on macOS
it only works in a CEF-owned window. So the app owns a normal AppKit window
with the sidebar, and every tab is a separate frameless CEF window attached as
a child window over the content area; only the active tab's window is visible.

## Build

```
scripts/bundle.sh          # → build/cha.app
open build/cha.app
```

The script fetches the CEF 152 binary distribution into `third_party/cef`
(~300 MB, not in the repo) on the first run, then builds with cmake and ninja.

## Run

```
open build/cha.app
```

The app is unsigned, so Chromium runs with `--use-mock-keychain` and encrypts
saved passwords with a throwaway key. Once the app is signed, set
`CHA_REAL_KEYCHAIN=1` to use the real keychain.

## Checks

```
scripts/check.sh           # build, space checks, code fill, launch/quit bench
scripts/check.sh fast      # build and space checks
scripts/check.sh window    # the space checks in a real window (Mac idle only)
scripts/bench.py 5         # launch and quit timing alone
```

They run headless: `CHA_HEADLESS=1` keeps the windows off screen, never takes
focus and mutes audio, and `CHA_PROFILE=<dir>` points state, codes and the
Chromium profile at a throwaway directory. `CHA_TEST=<scenario>` replays a
scenario (`spaces`, `codes`, `bench`, `demo`, …); pictures go to
`build/shots`, logs to `build/check`. What "like Arc" means, and where it
stands, is in [docs/arc-parity.md](docs/arc-parity.md).

## Keyboard

- ⌘T command bar (opens the result in a new tab), ⌘L command bar for the current tab
- ⇧⌘T empty tab, ⌘W close tab (pinned tabs and favourites only unload), ⌘1…⌘9 pick a tab
- ⌘D pin / unpin, ⇧⌘D add to favourites, ⇧⌘C copy link, ⇧⌘K clear today's tabs
- ⌥⌘A archived tabs
- ⇧⌘V fill the verification code for the current site
- ⌘S toggle sidebar, ⌃⌘F full screen, ⌘R reload, ⌘[ / ⌘] back and forward
- ⇧⌘N new space, ⌃1…⌃9 go to a space, ⌥⌘← / ⌥⌘→ previous / next space

## Spaces

As in Arc. Favourites sit on top as tiles shared by every space. Below them
is the space's own page: its name (double-click to rename, ⋯ for more),
pinned tabs and folders, a divider with Clear, New Tab, then today's tabs,
newest first. The window takes the space's colour, and the page sits on it as
a rounded card.

Switch spaces with the icons at the bottom, ⌃1…⌃9, ⌥⌘←/→ or a two-finger
swipe on the sidebar; the page slides along and the colours blend. A new
space opens an editor page: name, an SF Symbol or any emoji, a preset or any
colour. Drag space icons to reorder them; drop a tab on one to move it there.

Pinned tabs remember the address they were pinned at (↩ takes them back).
Today's tabs go to the archive on Clear, on ⌘W, or after 12 hours unseen; the
archive (bottom left) and the command bar bring them back. Drag the sidebar's
right edge to resize it.

## Verification codes

Chromium's password manager fills logins, but it has no place for TOTP, so the
app keeps those itself: File ▸ Verification Codes lists them with the code each
one reads right now, ⇧⌘V types the one this site needs into the page, and a
matching code fills an empty one-time-code field by itself once the page loads.

Add one by pasting its `otpauth://` link into the command bar, or import them
from the Passwords app: export the logins to CSV, then File ▸ Verification
Codes ▸ Import from Passwords Export. Only the OTPAuth column is read — delete
the export afterwards, it holds the passwords in the clear.

The secrets live in `~/Library/Application Support/cha/codes.json`, readable by
this user only. The app is unsigned, so there is no keychain to put them in.

## Layout

- `src/core` — the CEF layer in Objective-C++ (`ChaEngine`, `ChaTab`).
- `src/app` — the Swift app: model, window, sidebar, menu.
- `spike/` — the original throwaway spike, no longer built.
