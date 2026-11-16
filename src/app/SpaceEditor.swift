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
                        customColorButton
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

    // Any colour: a rainbow swatch that opens the system colour panel, which
    // recolours the space live as you drag.
    private var customColorButton: some View {
        let custom = space.map { !SpaceTheme.presets.contains($0.theme) } ?? false
        return Button {
            ThemeColorPanel.shared.open(for: spaceID, current: space?.theme, controller: controller)
        } label: {
            Circle()
                .fill(
                    AngularGradient(
                        colors: [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .red],
                        center: .center)
                )
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().strokeBorder(.primary.opacity(custom ? 0.8 : 0), lineWidth: 2)
                        .padding(-3))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Any colour")
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

// Bridges NSColorPanel to a space's theme.
final class ThemeColorPanel: NSObject {
    static let shared = ThemeColorPanel()
    private weak var controller: BrowserController?
    private var spaceID: UUID?

    func open(for spaceID: UUID, current: SpaceTheme?, controller: BrowserController) {
        attach(for: spaceID, controller: controller)
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        if let current { panel.color = current.color }
        panel.orderFront(nil)
    }

    // Points the panel's changes at a space without showing it (the checks).
    func attach(for spaceID: UUID, controller: BrowserController) {
        self.spaceID = spaceID
        self.controller = controller
    }

    @objc func colorChanged(_ panel: NSColorPanel) {
        guard let spaceID, let controller else { return }
        controller.updateSpace(spaceID) { $0.theme = SpaceTheme(panel.color) }
    }
}
