import SwiftUI

// Sound, as Arc shows it: a speaker on the tab that plays (a click mutes
// it), and a mini player at the bottom of the sidebar for what plays in a
// tab you have left: what it is, play/pause, back/forward, mute, and a
// click to go back to it.
struct MediaState: Equatable {
    var playing = false
    var paused = false  // Something stopped part-way that can go on.
    var muted = false
    var title = ""
    var artist = ""

    var shown: Bool { playing || muted }  // The tab row's speaker.
}

extension BrowserController {
    /// Called with every tab update: what the tab's page plays.
    func noteMedia(tabID id: UUID, tab: ChaTab) {
        let state = MediaState(
            playing: tab.isPlayingMedia, paused: tab.hasPausedMedia, muted: tab.audioMuted,
            title: tab.mediaTitle, artist: tab.mediaArtist)
        let empty = !state.playing && !state.paused && !state.muted
        if empty {
            if media[id] != nil { media[id] = nil }
        } else if media[id] != state {
            if state.playing { lastPlayedTab = id; miniPlayerDismissed.remove(id) }
            media[id] = state
        }
    }

    func forgetMedia(_ id: UUID) {
        media[id] = nil
        if lastPlayedTab == id { lastPlayedTab = nil }
    }

    /// The tab the mini player is for: the one that played last, while it is
    /// not the tab in front, still has something to play, and was not closed
    /// from the player.
    var miniPlayerTab: UUID? {
        guard let id = lastPlayedTab, id != activeTabID, let state = media[id],
            state.playing || state.paused, !miniPlayerDismissed.contains(id), tabData(id) != nil
        else { return nil }
        return id
    }

    func toggleMute(_ id: UUID) {
        guard let tab = liveTabs[id] else { return }
        tab.audioMuted = !tab.audioMuted
        noteMedia(tabID: id, tab: tab)
    }

    func mediaCommand(_ id: UUID, _ command: String) {
        liveTabs[id]?.sendMediaCommand(command)
    }

    func dismissMiniPlayer(_ id: UUID) {
        if media[id]?.playing == true { mediaCommand(id, "toggle") }
        miniPlayerDismissed.insert(id)
    }
}

/// The speaker on a tab row; a click mutes or unmutes the tab.
struct TabSpeaker: View {
    @ObservedObject var controller: BrowserController
    let tabID: UUID

    var body: some View {
        if let state = controller.media[tabID], state.shown {
            Button {
                controller.toggleMute(tabID)
            } label: {
                Image(systemName: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(state.muted ? "Unmute tab" : "Mute tab")
            .uiFrame("speaker:\(tabID)")
        }
    }
}

struct MiniPlayer: View {
    @ObservedObject var controller: BrowserController
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        if let id = controller.miniPlayerTab, let state = controller.media[id], let tab = controller.tabData(id) {
            player(id, state, tab)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func player(_ id: UUID, _ state: MediaState, _ tab: TabData) -> some View {
        let style = SidebarStyle(dark: scheme == .dark)
        let title = state.title.isEmpty ? tab.displayTitle : state.title
        let subtitle = state.artist.isEmpty ? (URL(string: tab.url)?.host ?? "") : state.artist
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                TabIcon(controller: controller, tab: tab, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if hovered {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { controller.dismissMiniPlayer(id) }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Pause and hide")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { controller.showTab(id) }
            HStack(spacing: 18) {
                control("backward.fill", "Back") { controller.mediaCommand(id, "previoustrack") }
                control(state.playing ? "pause.fill" : "play.fill", state.playing ? "Pause" : "Play") {
                    controller.mediaCommand(id, "toggle")
                }
                .uiFrame("miniPlayerToggle")
                control("forward.fill", "Forward") { controller.mediaCommand(id, "nexttrack") }
                control(state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", state.muted ? "Unmute" : "Mute") {
                    controller.toggleMute(id)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.tile))
        .onHover { hovered = $0 }
        .uiFrame("miniPlayer")
    }

    private func control(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 22, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
