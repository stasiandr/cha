import SwiftUI

// The spaces side by side, the open one in view. A swipe or a switch slides
// the row; the controller swaps the open space once the slide is done, so
// what was the neighbour simply becomes the middle page.
struct SpacePager: View {
    @ObservedObject var controller: BrowserController

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 0) {
                page(controller.leftSpace, width: width)
                page(controller.activeSpace, width: width)
                page(controller.rightSpace, width: width)
            }
            .frame(width: width * 3, alignment: .leading)
            // The pager's own width is the sidebar's less its padding, so the
            // controller's offset (in sidebar widths) is scaled to it.
            .offset(x: -width + controller.pageOffset * width / max(controller.sidebarWidth, 1))
        }
        .clipped()
    }

    @ViewBuilder
    private func page(_ space: SpaceData?, width: CGFloat) -> some View {
        if let space {
            SpacePageView(controller: controller, space: space)
                .frame(width: width)
        } else {
            Color.clear.frame(width: width)
        }
    }
}

// One space: its name, pinned tabs and folders, then "Clear", "+ New Tab"
// and today's tabs.
struct SpacePageView: View {
    @ObservedObject var controller: BrowserController
    let space: SpaceData
    @Environment(\.colorScheme) private var scheme
    @State private var hoveringDivider = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                // Arc shows no title over the tabs: pinned ones first, then
                // the divider, then New Tab and today's.
                pinnedSection
                if !space.pinnedTabs.isEmpty || !space.folders.isEmpty {
                    divider
                }
                newTabRow
                ForEach(space.unpinnedTabs) { tab in
                    TabRow(controller: controller, space: space, tab: tab)
                }
                // Room to drop below the last tab; right-click for the
                // space's own menu.
                Color.clear.frame(height: 60)
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        guard let id = DragPayload.tabID(items) else { return false }
                        controller.moveTab(id, toSection: false)
                        return true
                    }
                    .contextMenu { spaceMenu }
            }
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var spaceMenu: some View {
        Button("Edit Space…") { controller.editSpace(space.id) }
        Button("New Folder") { _ = controller.addFolder() }
        Divider()
        Button("Delete Space…") { controller.deleteSpace(space.id) }
            .disabled(controller.spaces.count < 2)
    }

    @ViewBuilder
    private var pinnedSection: some View {
        ForEach(space.folders) { folder in
            FolderRow(controller: controller, space: space, folder: folder)
        }
        ForEach(space.loosePinnedTabs) { tab in
            TabRow(controller: controller, space: space, tab: tab)
        }
    }

    // The line between pinned and today; "Clear" on hover archives today's tabs.
    private var divider: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(.primary.opacity(0.12))
                .frame(height: 1)
            if hoveringDivider, !space.unpinnedTabs.isEmpty {
                Button {
                    controller.clearToday(space.id)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                        Text("Clear")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Archive today's tabs")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 20)
        .contentShape(Rectangle())
        .onHover { hoveringDivider = $0 }
        .dropDestination(for: String.self) { items, _ in
            guard let id = DragPayload.tabID(items) else { return false }
            controller.moveTab(id, toSection: false)
            return true
        }
    }

    private var newTabRow: some View {
        Button {
            if space.id != controller.activeSpaceID {
                controller.selectSpace(space.id, animated: false)
            }
            controller.openCommandBar(mode: .newTab)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 16)
                Text("New Tab")
                    .font(.system(size: 13.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rows

struct TabRow: View {
    @ObservedObject var controller: BrowserController
    let space: SpaceData
    let tab: TabData
    var indent: CGFloat = 0
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        let style = SidebarStyle(dark: scheme == .dark)
        let isActive = space.activeTabID == tab.id
        let loaded = controller.isLoaded(tab.id)
        HStack(spacing: 8) {
            TabIcon(controller: controller, tab: tab, size: 16)
                .opacity(tab.isPinned && !loaded && !isActive ? 0.6 : 1)
            Text(tab.displayTitle)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(
                    tab.isPinned && !loaded && !isActive
                        ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                )
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if tab.hasLeftPinnedURL, hovered || isActive {
                Button {
                    controller.resetToPinnedURL(tab.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Back to the pinned address")
            }
            if hovered {
                Button {
                    controller.closeTab(tab.id)
                } label: {
                    Image(systemName: tab.isPinned ? "minus" : "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(tab.isPinned ? "Unload tab" : "Close tab")
            }
        }
        .padding(.leading, 10 + indent)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(style.card(active: isActive, hovered: hovered))
                .shadow(color: isActive ? style.shadow : .clear, radius: 2.5, y: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { controller.activateTab(tab.id) }
        .onDrag { DragPayload.tab(tab.id) }
        .dropDestination(for: String.self) { items, _ in
            guard let id = DragPayload.tabID(items) else { return false }
            controller.moveTab(id, before: tab.id)
            return true
        }
        .contextMenu { TabMenu(controller: controller, space: space, tab: tab) }
    }
}

struct TabMenu: View {
    @ObservedObject var controller: BrowserController
    let space: SpaceData
    let tab: TabData

    var body: some View {
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { controller.togglePin(tab.id) }
        Button("Add to Favorites") { controller.addToFavorites(tab.id) }
        if tab.hasLeftPinnedURL {
            Button("Back to Pinned Address") { controller.resetToPinnedURL(tab.id) }
        }
        let others = controller.spaces.filter { $0.id != space.id }
        if !others.isEmpty {
            Menu("Move to Space") {
                ForEach(others) { other in
                    Button(other.name) { controller.moveTab(tab.id, toSpace: other.id) }
                }
            }
        }
        if !space.folders.isEmpty {
            Menu("Move to Folder") {
                ForEach(space.folders) { folder in
                    Button(folder.name) { controller.moveTab(tab.id, toFolder: folder.id) }
                }
            }
        }
        Divider()
        Button("Copy Link") { controller.copyLink(tab.id) }
        Button("Duplicate") { controller.duplicateTab(tab.id) }
        Divider()
        if tab.isPinned {
            Button("Unload") { controller.unload(tab.id) }
                .disabled(!controller.isLoaded(tab.id))
        }
        Button(tab.isPinned ? "Close and Unpin" : "Close Tab") {
            if tab.isPinned { controller.togglePin(tab.id) }
            controller.closeTab(tab.id)
        }
    }
}

// A folder in the pinned section: click toggles it, double-click renames,
// and tabs dropped on it go inside.
struct FolderRow: View {
    @ObservedObject var controller: BrowserController
    let space: SpaceData
    let folder: FolderData
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    @State private var targeted = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let style = SidebarStyle(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: folder.isOpen ? "folder" : "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                if renaming {
                    TextField("Folder", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($focused)
                        .onSubmit {
                            controller.renameFolder(folder.id, to: draft)
                            renaming = false
                        }
                        .onExitCommand { renaming = false }
                        .onAppear { focused = true }
                } else {
                    Text(folder.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(folder.isOpen ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(style.card(active: false, hovered: hovered || targeted))
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(count: 2) {
                draft = folder.name
                renaming = true
            }
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.18)) { controller.toggleFolder(folder.id) }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let id = DragPayload.tabID(items) else { return false }
                controller.moveTab(id, toFolder: folder.id)
                return true
            } isTargeted: { targeted = $0 }
            .contextMenu {
                Button("Rename Folder") {
                    draft = folder.name
                    renaming = true
                }
                Button("Delete Folder") { controller.deleteFolder(folder.id) }
            }

            if folder.isOpen {
                ForEach(space.tabs(in: folder.id)) { tab in
                    TabRow(controller: controller, space: space, tab: tab, indent: 14)
                }
            }
        }
    }
}

// MARK: - Bottom bar

// Archive on the left, the spaces in the middle, "+" on the right. Space
// icons switch on click, take tabs dropped on them, reorder by dragging, and
// turn into dots when there are too many to fit, as in Arc.
struct BottomBar: View {
    @ObservedObject var controller: BrowserController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ChromeButton(symbol: "archivebox", help: "Archived tabs") {
                controller.sidebarPage = controller.sidebarPage == .archive ? .tabs : .archive
            }
            Spacer(minLength: 0)
            GeometryReader { geometry in
                let compact = CGFloat(controller.spaces.count) * 28 > geometry.size.width
                HStack(spacing: compact ? 1 : 2) {
                    ForEach(Array(controller.spaces.enumerated()), id: \.element.id) {
                        index, space in
                        spaceButton(space, index: index, compact: compact)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 28)
            Spacer(minLength: 0)
            Menu {
                Button("New Space") { controller.addSpace() }
                Button("New Folder") { _ = controller.addFolder() }
                Button("New Tab") { controller.openCommandBar(mode: .newTab) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New space, folder or tab")
        }
    }

    private func spaceButton(_ space: SpaceData, index: Int, compact: Bool) -> some View {
        let isActive = space.id == controller.activeSpaceID
        let style = SidebarStyle(dark: scheme == .dark)
        return Button {
            controller.selectSpace(space.id)
        } label: {
            Group {
                if compact && !isActive {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 5, height: 5)
                } else {
                    SpaceIcon(space: space, size: 12)
                        .foregroundStyle(
                            isActive ? AnyShapeStyle(Color(space.theme.color))
                                : AnyShapeStyle(.secondary))
                }
            }
            .frame(width: compact && !isActive ? 12 : 26, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? style.activeTile : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(index < 9 ? "\(space.name) (⌃\(index + 1))" : space.name)
        .onDrag { DragPayload.space(space.id) }
        .dropDestination(for: String.self) { items, _ in
            if let moved = DragPayload.spaceID(items) {
                controller.moveSpace(moved, before: space.id)
                return true
            }
            guard let id = DragPayload.tabID(items) else { return false }
            controller.moveTab(id, toSpace: space.id)
            return true
        }
        .contextMenu {
            Button("Edit Space…") { controller.editSpace(space.id) }
            Divider()
            Button("Delete Space…") { controller.deleteSpace(space.id) }
                .disabled(controller.spaces.count < 2)
        }
    }
}
