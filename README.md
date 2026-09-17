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

`CHA_TEST=demo|fullscreen` replays a UI scenario — the machine has no
Accessibility permission, so scripts cannot click the interface.

## Keyboard

- ⌘T command bar (opens the result in a new tab), ⌘L command bar for the current tab
- ⇧⌘T empty tab, ⌘W close tab, ⌘1…⌘9 pick a tab
- ⌘S toggle sidebar, ⌃⌘F full screen, ⌘R reload, ⌘[ / ⌘] back and forward
- ⇧⌘N new space, ⌥⌘← / ⌥⌘→ switch spaces

Drag a tab in the sidebar to reorder it, or drop it on a space icon to move it
there. Double-click the space name to rename it. Drag the sidebar's right edge
to resize it.

## Layout

- `src/core` — the CEF layer in Objective-C++ (`ChaEngine`, `ChaTab`).
- `src/app` — the Swift app: model, window, sidebar, menu.
- `spike/` — the original throwaway spike, no longer built.
