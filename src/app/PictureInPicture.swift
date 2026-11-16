import AppKit

// Picture in picture, as Arc does it: ⌥⌘P sends the playing (or largest)
// video of the page to a floating window and back; leaving a tab while a
// video plays with sound takes it along in picture in picture, and coming
// back to the tab returns it to the page. The floating window is Chromium's.
//
// requestPictureInPicture only works from a user action, so the scripts run
// through DevTools with a user gesture (ChaTab.executeJavaScriptWithUserGesture).
enum PictureInPicture {
    // The video worth floating: one that plays, else the biggest one ready.
    static let pickVideo = """
        const videos = [...document.querySelectorAll('video')]
          .filter(v => v.readyState >= 1 && !v.disablePictureInPicture);
        const video = videos.find(v => !v.paused && !v.ended)
          || videos.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
        """

    static let toggle = """
        (() => {
          if (document.pictureInPictureElement) { document.exitPictureInPicture(); return 'exit'; }
          \(pickVideo)
          if (!video) return 'none';
          video.requestPictureInPicture();
          return 'enter';
        })()
        """

    // Leaving the tab: only a video that is playing and can be heard.
    static let enterIfPlaying = """
        (() => {
          if (document.pictureInPictureElement) return;
          const video = [...document.querySelectorAll('video')]
            .find(v => !v.paused && !v.ended && !v.muted && v.volume > 0
                       && v.readyState >= 2 && !v.disablePictureInPicture);
          if (video) video.requestPictureInPicture();
        })()
        """

    static let exitIfFloating = """
        if (document.pictureInPictureElement) document.exitPictureInPicture();
        """
}

extension BrowserController {
    static var autoPictureInPicture: Bool {
        UserDefaults.standard.object(forKey: "autoPictureInPicture") as? Bool ?? true
    }

    func togglePictureInPicture() {
        activeTab?.executeJavaScript(withUserGesture: PictureInPicture.toggle)
    }

    // Called on every tab change, the space switches included.
    func pictureInPictureForSwitch(from old: UUID?, to new: UUID?) {
        guard Self.autoPictureInPicture, old != new else { return }
        if let old, let tab = liveTabs[old] {
            tab.executeJavaScript(withUserGesture: PictureInPicture.enterIfPlaying)
        }
        if let new, let tab = liveTabs[new] {
            tab.executeJavaScript(withUserGesture: PictureInPicture.exitIfFloating)
        }
    }
}
