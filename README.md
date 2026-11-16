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

`CHA_TEST=demo|codes|fullscreen` replays a UI scenario — the machine has no
Accessibility permission, so scripts cannot click the interface.
`CHA_TEST=sidebar` renders the sidebar offscreen into `build/sidebar.png`,
which also works while the screen is asleep or locked.

## Keyboard

- ⌘T command bar (opens the result in a new tab), ⌘L command bar for the current tab
- ⇧⌘T empty tab, ⌘W close tab, ⌘1…⌘9 pick a tab
- ⇧⌘V fill the verification code for the current site
- ⌘S toggle sidebar, ⌃⌘F full screen, ⌘R reload, ⌘[ / ⌘] back and forward
- ⇧⌘N new space, ⌥⌘← / ⌥⌘→ switch spaces

The window takes the active space's colour, the page sits on it as a rounded
card, pinned tabs show up as a grid of favourite tiles, and the new-tab button
sits at the bottom next to the space switcher.

Drag a tab in the sidebar to reorder it, or drop it on a space icon to move it
there. Double-click the space name to rename it. Drag the sidebar's right edge
to resize it.

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
