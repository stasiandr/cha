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
          if (window.documentPictureInPicture?.window) { documentPictureInPicture.window.close(); return 'exit'; }
          if (window.__chaEnterPiP) { try { window.__chaEnterPiP({ action: 'enterpictureinpicture' }); return 'site'; } catch (e) {} }
          \(pickVideo)
          if (!video) return 'none';
          video.requestPictureInPicture();
          return 'enter';
        })()
        """

    // Leaving the tab. A site with its own automatic picture in picture
    // (Meet and other calls: a floating window with the call's tiles and
    // buttons) gets it, as in Chrome, when it is in a call or plays sound.
    // Otherwise a playing video that can be heard floats; in a call, the
    // biggest playing video even with no sound of its own (the tiles are
    // muted, the call's sound plays apart).
    static func enterOnLeaving(call: Bool, fallback: Bool = false) -> String {
        """
        (() => {
          const call = \(call) || !!(window.__chaCall && window.__chaCall());
          if (document.pictureInPictureElement || window.documentPictureInPicture?.window) return 'already';
          const playing = () => [...document.querySelectorAll('video')]
            .filter(v => !v.paused && !v.ended && v.readyState >= 2 && !v.disablePictureInPicture);
          const pick = () => playing().find(v => !v.muted && v.volume > 0)
            || (call ? playing().sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0] : null);
          const audible = [...document.querySelectorAll('video, audio')]
            .some(m => !m.paused && !m.ended && !m.muted && m.volume > 0);
          if (window.__chaEnterPiP && (call || audible)) {
            try { window.__chaEnterPiP({ action: 'enterpictureinpicture' }); } catch (e) {}
            // The site's own window didn't come: its video floats instead.
            if (\(fallback)) setTimeout(() => {
              if (document.pictureInPictureElement || window.documentPictureInPicture?.window) return;
              const video = pick();
              console.log('__cha_probe__ ' + location.host + ' opened no window of its own: ' + (video ? 'its video floats' : 'no video to float'));
              if (video) video.requestPictureInPicture().catch(e => console.log('__cha_probe__ video refused: ' + e.name));
            }, 1500);
            return call ? 'site (in a call)' : 'site';
          }
          const video = pick();
          if (video) { video.requestPictureInPicture(); return call ? 'video (in a call)' : 'video'; }
          return call ? 'none (in a call)' : 'none';
        })()
        """
    }

    // The same, with what it did in tabs.log when there was something to do.
    static func loggedLeaving(call: Bool, fallback: Bool) -> String {
        "(() => { const r = \(enterOnLeaving(call: call, fallback: fallback)); if (r !== 'none') "
            + "console.log('__cha_probe__ left ' + location.host + ' (' + document.visibilityState + '): ' + r); })()"
    }

    // Back to the tab: whatever floated comes home.
    static let exitIfFloating = """
        if (document.pictureInPictureElement) document.exitPictureInPicture();
        if (window.documentPictureInPicture?.window) documentPictureInPicture.window.close();
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
            // Once the tab is out of sight, as Chrome does: Meet ignores the
            // call while its page is still visible.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.activeTabID != old, !tab.isClosed else { return }
                tab.executeJavaScript(withUserGesture: PictureInPicture.loggedLeaving(
                    call: tab.usesCameraOrMicrophone, fallback: ChaTab.allowsFloatingWindows))
            }
        }
        if let new, let tab = liveTabs[new] {
            tab.executeJavaScript(withUserGesture: PictureInPicture.exitIfFloating)
        }
    }
}
