import Carbon.HIToolbox
import Foundation

// ⌘T, ⌘L and ⌃⇧= type addresses: the command bar opens with an English
// (ASCII) keyboard layout, whatever the page was typed in. Closing it gives
// the layout back, unless it was changed by hand meanwhile (a search typed
// in Russian stays in Russian). Search All Tabs keeps the layout: it finds
// what pages say, in their language.
enum InputSource {
    /// The selected keyboard layout's ID; replaced by the checks, which
    /// never touch the real one.
    static var current: () -> String? = {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return property(source, kTISPropertyInputSourceID)
    }

    /// The ASCII layout macOS would use for a password field (ABC, U.S.…).
    static var ascii: () -> String? = {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return property(source, kTISPropertyInputSourceID)
    }

    static var select: (String) -> Void = { id in
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
            let source = list.first
        else { return }
        TISSelectInputSource(source)
    }

    /// What the command bar switched away from, and to.
    private static var switched: (from: String, to: String)?

    static func useASCII() {
        guard let now = current(), let ascii = ascii(), now != ascii else { return }
        select(ascii)
        switched = (now, ascii)
    }

    static func restore() {
        guard let switched else { return }
        self.switched = nil
        // Changed by hand while the bar was open: that choice stays.
        if current() == switched.to { select(switched.from) }
    }

    /// The checks' own layouts, so a test run never changes the keyboard of
    /// whoever works at this Mac.
    static var fakeLayout = ""
    static func useFake(_ layout: String) {
        fakeLayout = layout
        current = { fakeLayout }
        ascii = { "com.apple.keylayout.ABC" }
        select = { fakeLayout = $0 }
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
