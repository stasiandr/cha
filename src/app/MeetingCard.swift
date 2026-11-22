import SwiftUI

// The next meeting at the bottom of the sidebar, as in Arc: its name, when
// (in 12 min, now · until 11:30) and Join for one with a call link. Shown
// from 30 minutes before until it ends; × hides that one meeting.
struct MeetingCard: View {
    @ObservedObject var calendar: GoogleCalendar
    let join: (URL) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    static let lead: TimeInterval = 30 * 60

    var body: some View {
        if let event = calendar.next, event.start.timeIntervalSince(calendar.now) <= Self.lead {
            card(event)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func card(_ event: CalendarEvent) -> some View {
        let style = SidebarStyle(dark: scheme == .dark)
        let started = event.start <= calendar.now
        return HStack(spacing: 8) {
            Image(systemName: event.joinURL == nil ? "calendar" : "video.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(started ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(Self.when(event, now: calendar.now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let url = event.joinURL {
                Button("Join") { join(url) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .uiFrame("meetingJoin")
            }
            if hovered {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { _ = calendar.dismissed.insert(event.id) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide this meeting")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.tile))
        .contentShape(Rectangle())
        .onTapGesture { if let link = event.link { join(link) } }
        .onHover { hovered = $0 }
        .help(event.link == nil ? "" : "Open in Google Calendar")
        .uiFrame("meetingCard")
    }

    static func when(_ event: CalendarEvent, now: Date) -> String {
        let time = MeetingReminders.time
        if event.start <= now { return "Now · until \(time.string(from: event.end))" }
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 1 { return "Starting · \(time.string(from: event.start))" }
        return "In \(minutes) min · \(time.string(from: event.start))"
    }
}
