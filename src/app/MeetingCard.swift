import SwiftUI

// The next meeting at the bottom of the sidebar, as in Arc: its name, when
// (in 12 min, now · until 11:30) and Join for one with a call link. Today's
// next meeting is always there; × hides that one meeting.
struct MeetingCard: View {
    @ObservedObject var calendar: GoogleCalendar
    let join: (URL) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    @State private var detailsShown = false
    @State private var overDetails = false
    @State private var hoverTask: DispatchWorkItem?

    var body: some View {
        if let event = calendar.next {
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
        .onHover { inside in
            hovered = inside
            schedule(inside: inside, overDetails: overDetails)
        }
        .popover(isPresented: Binding(
            get: { detailsShown || calendar.detailsFor == event.id },
            set: { if !$0 { detailsShown = false; calendar.detailsFor = nil } }
        ), arrowEdge: .trailing) {
            MeetingDetails(event: event, now: calendar.now, join: join)
                .onHover { inside in
                    overDetails = inside
                    schedule(inside: inside, overDetails: inside)
                }
        }
        .uiFrame("meetingCard")
    }

    // Details after 0.4 s on the card; they stay while the pointer is on the
    // card or on them, and go a moment after it leaves both.
    private func schedule(inside: Bool, overDetails: Bool) {
        hoverTask?.cancel()
        let show = inside || overDetails
        let task = DispatchWorkItem { detailsShown = show ? true : (hovered || self.overDetails) }
        hoverTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (show ? 0.4 : 0.25), execute: task)
    }

    static func when(_ event: CalendarEvent, now: Date) -> String {
        let time = MeetingReminders.time
        if event.start <= now { return "Now · until \(time.string(from: event.end))" }
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 1 { return "Starting · \(time.string(from: event.start))" }
        if minutes < 60 { return "In \(minutes) min · \(time.string(from: event.start))" }
        return "At \(time.string(from: event.start))"
    }
}

// What's in the meeting: full name, when, where, the call, who comes and
// who answered what, the first lines of its description.
struct MeetingDetails: View {
    let event: CalendarEvent
    let now: Date
    let join: (URL) -> Void
    static let shownGuests = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(Self.timeLine(event))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if event.location != nil || event.joinURL != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let place = event.location {
                        Label(place, systemImage: "mappin.and.ellipse").lineLimit(2)
                    }
                    if let url = event.joinURL {
                        Label((url.host ?? "") + url.path, systemImage: "video").lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 12))
            }
            if !event.guests.isEmpty { guests }
            if let notes = event.notes {
                Text(notes)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                if let url = event.joinURL {
                    Button("Join") { join(url) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
                if let link = event.link {
                    Button("Open in Calendar") { join(link) }
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .uiFrame("meetingDetails")
    }

    private var guests: some View {
        let all = event.guests.sorted { a, b in
            if a.organizer != b.organizer { return a.organizer }
            if a.answer != b.answer { return Self.order(a.answer) < Self.order(b.answer) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(Self.summary(event.guests))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(all.prefix(Self.shownGuests), id: \.self) { guest in
                        HStack(spacing: 6) {
                            Image(systemName: Self.symbol(guest.answer))
                                .foregroundStyle(Self.color(guest.answer))
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 12)
                            Text(guest.name).lineLimit(1)
                            if guest.organizer { tag("organizer") }
                            if guest.isMe { tag("you") }
                            if guest.optional { tag("optional") }
                        }
                        .font(.system(size: 12))
                        .help(guest.email)
                    }
                    if all.count > Self.shownGuests {
                        Text("and \(all.count - Self.shownGuests) more")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
    }

    static func summary(_ guests: [CalendarEvent.Guest]) -> String {
        func count(_ a: CalendarEvent.Guest.Answer) -> Int { guests.filter { $0.answer == a }.count }
        var parts = ["\(guests.count) \(guests.count == 1 ? "guest" : "guests")"]
        if count(.yes) > 0 { parts.append("\(count(.yes)) yes") }
        if count(.no) > 0 { parts.append("\(count(.no)) no") }
        if count(.maybe) > 0 { parts.append("\(count(.maybe)) maybe") }
        if count(.none) > 0 { parts.append("\(count(.none)) awaiting") }
        return parts.joined(separator: " · ")
    }

    static func timeLine(_ event: CalendarEvent) -> String {
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        let time = MeetingReminders.time
        let minutes = Int(event.end.timeIntervalSince(event.start) / 60)
        let length = minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60) h"
            : minutes > 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return "\(day.string(from: event.start)), \(time.string(from: event.start))–\(time.string(from: event.end)) · \(length)"
    }

    static func order(_ a: CalendarEvent.Guest.Answer) -> Int {
        switch a { case .yes: 0; case .maybe: 1; case .none: 2; case .no: 3 }
    }
    static func symbol(_ a: CalendarEvent.Guest.Answer) -> String {
        switch a { case .yes: "checkmark"; case .no: "xmark"; case .maybe: "questionmark"; case .none: "circle.dotted" }
    }
    static func color(_ a: CalendarEvent.Guest.Answer) -> Color {
        switch a { case .yes: .green; case .no: .red; case .maybe: .orange; case .none: .secondary }
    }
}
