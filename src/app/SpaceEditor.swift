import SwiftUI

// Arc makes and edits a space on a page of the sidebar: name, icon, colour.
// Every change shows at once (the window takes the colour as you pick it).
struct SpaceEditorView: View {
    @ObservedObject var controller: BrowserController
    let spaceID: UUID
    let isNew: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var emojiDraft = ""
    @FocusState private var nameFocused: Bool

    static let symbols = [
        "person", "briefcase", "book", "house", "star", "heart", "bolt", "leaf",
        "gamecontroller", "cart", "music.note", "paintbrush", "hammer", "graduationcap",
        "airplane", "globe",
    ]
    static let emojis = ["🏠", "💼", "📚", "🎮", "🛒", "🎵", "🎨", "✈️", "🌱", "🔥", "⭐️", "🧪"]

    private var space: SpaceData? { controller.space(spaceID) }

    var body: some View {
        let style = SidebarStyle(dark: scheme == .dark)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                Text(isNew ? "New Space" : "Edit Space")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 4)

                TextField("Space name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($nameFocused)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(style.pill))
                    .onChange(of: name) { _, value in controller.renameSpace(spaceID, to: value) }
                    .onSubmit { controller.finishEditing() }

                section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6),
                        spacing: 4)
                    {
                        ForEach(Self.symbols + Self.emojis, id: \.self) { icon in
                            iconChoice(icon, style: style)
                        }
                    }
                    HStack(spacing: 6) {
                        TextField("Any emoji", text: $emojiDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(style.pill))
                            .onChange(of: emojiDraft) { _, value in
                                guard let last = value.last, isEmojiIcon(String(last)) else { return }
                                controller.updateSpace(spaceID) { $0.symbol = String(last) }
                            }
                    }
                }

                section("Colour") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                        spacing: 6)
                    {
                        ForEach(SpaceTheme.presets, id: \.self) { theme in
                            swatch(theme)
                        }
                        ColorPicker(
                            "",
                            selection: Binding(
                                get: { Color(space?.theme.color ?? .systemBlue) },
                                set: { color in
                                    controller.updateSpace(spaceID) {
                                        $0.theme = SpaceTheme(NSColor(color))
                                    }
                                }),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        .help("Any colour")
                    }
                }

                HStack {
                    if isNew {
                        Button("Cancel") { controller.finishEditing(cancelled: true) }
                    } else {
                        Button("Delete Space…") { controller.deleteSpace(spaceID) }
                            .disabled(controller.spaces.count < 2)
                    }
                    Spacer()
                    Button(isNew ? "Create Space" : "Done") { controller.finishEditing() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 6)
        }
        .scrollIndicators(.never)
        .onAppear {
            name = space?.name ?? ""
            nameFocused = true
        }
        .onExitCommand { controller.finishEditing(cancelled: isNew) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func iconChoice(_ icon: String, style: SidebarStyle) -> some View {
        let selected = space?.symbol == icon
        return Button {
            controller.updateSpace(spaceID) { $0.symbol = icon }
        } label: {
            Group {
                if isEmojiIcon(icon) {
                    Text(icon).font(.system(size: 14))
                } else {
                    Image(systemName: icon).font(.system(size: 13, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .foregroundStyle(selected ? Color(space?.theme.color ?? .systemBlue) : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? style.activeTile : style.tile))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func swatch(_ theme: SpaceTheme) -> some View {
        let selected = space?.theme == theme
        return Button {
            controller.updateSpace(spaceID) { $0.theme = theme }
        } label: {
            Circle()
                .fill(Color(theme.color))
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().strokeBorder(.primary.opacity(selected ? 0.8 : 0), lineWidth: 2)
                        .padding(-3))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Archived tabs, newest first; clicking one brings it back into its space.
struct ArchiveView: View {
    @ObservedObject var controller: BrowserController
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: UUID?

    var body: some View {
        let style = SidebarStyle(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    controller.sidebarPage = .tabs
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Text("Archive")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !controller.archive.isEmpty {
                    Button("Clear") {
                        controller.archive.removeAll()
                        controller.scheduleSave()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)

            if controller.archive.isEmpty {
                Text("Tabs you close or clear, and today's tabs left alone for 12 hours, land here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                Spacer()
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(controller.archive) { item in row(item, style: style) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func row(_ item: ArchivedTab, style: SidebarStyle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title.isEmpty ? item.url : item.title)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Text(
                [displayHost(item.url), controller.space(item.spaceID)?.name,
                 item.archivedAt.formatted(.relative(presentation: .named))]
                    .compactMap { $0 }.joined(separator: " · ")
            )
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(style.card(active: false, hovered: hovered == item.id)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? item.id : nil }
        .onTapGesture { controller.restoreArchived(item.id) }
        .help(item.url)
    }
}
