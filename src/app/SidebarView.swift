import SwiftUI

struct SidebarView: View {
    @ObservedObject var controller: BrowserController
    @FocusState private var addressFocused: Bool
    @State private var hoveredTab: UUID?
    @State private var editingSpace: UUID?
    @State private var spaceNameDraft = ""
    @FocusState private var nameFieldFocused: Bool
    @State private var dragStartWidth: CGFloat?

    private var space: SpaceData { controller.activeSpace }

    var body: some View {
        ZStack(alignment: .trailing) {
            content
            resizeHandle
        }
    }

    private var content: some View {
        VStack(spacing: 8) {
            navigationRow
            addressField
            tabSections
            Spacer(minLength: 0)
            spaceSwitcher
        }
        .padding(.horizontal, 10)
        .padding(.top, controller.isFullscreen ? 12 : 38)  // Clear the traffic lights.
        .padding(.bottom, 10)
        .onChange(of: controller.focusAddressToken) { _, _ in
            addressFocused = true
        }
    }

    // Dragging the right edge changes the sidebar width, as in Arc.
    private var resizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = controller.sidebarWidth
                        }
                        controller.setSidebarWidth(
                            (dragStartWidth ?? controller.sidebarWidth)
                                + value.translation.width)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }

    private var navigationRow: some View {
        HStack(spacing: 4) {
            navButton("chevron.left", enabled: controller.canGoBack) {
                controller.goBack()
            }
            navButton("chevron.right", enabled: controller.canGoForward) {
                controller.goForward()
            }
            navButton("arrow.clockwise", enabled: true) { controller.reload() }
            Spacer(minLength: 0)
            navButton("sidebar.left", enabled: true) { controller.toggleSidebar() }
        }
        .padding(.horizontal, 2)
    }

    private func navButton(
        _ symbol: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Address bar

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField("Search or enter address", text: $controller.addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($addressFocused)
                .onSubmit {
                    controller.navigate(to: controller.addressText)
                    addressFocused = false
                }
                .onTapGesture { controller.openCommandBar(mode: .current) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Tabs

    private var tabSections: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !space.pinnedTabs.isEmpty {
                    sectionTitle("Pinned")
                    ForEach(space.pinnedTabs) { tab in
                        tabRow(tab)
                    }
                    Divider().padding(.vertical, 6)
                }

                Button {
                    controller.openCommandBar(mode: .newTab)
                } label: {
                    Label("New Tab", systemImage: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                ForEach(space.unpinnedTabs) { tab in
                    tabRow(tab)
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.top, 4)
    }

    private func tabRow(_ tab: TabData) -> some View {
        let isActive = space.activeTabID == tab.id
        let isHovered = hoveredTab == tab.id
        return HStack(spacing: 7) {
            icon(for: tab)
            Text(tab.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if isHovered {
                Button {
                    controller.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    isActive
                        ? AnyShapeStyle(Color(space.tint.color).opacity(0.22))
                        : isHovered
                            ? AnyShapeStyle(.quaternary.opacity(0.5))
                            : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in hoveredTab = hovering ? tab.id : nil }
        .onTapGesture { controller.activateTab(tab.id) }
        .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first.flatMap(UUID.init(uuidString:))
            else { return false }
            controller.moveTab(dragged, before: tab.id)
            return true
        }
        .contextMenu {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") {
                controller.togglePin(tab.id)
            }
            Button("Close Tab") { controller.closeTab(tab.id) }
        }
    }

    @ViewBuilder
    private func icon(for tab: TabData) -> some View {
        if controller.loadingTabs.contains(tab.id) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        } else if let favicon = controller.favicons[tab.id] {
            Image(nsImage: favicon)
                .resizable()
                .frame(width: 14, height: 14)
                .cornerRadius(3)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
    }

    // MARK: - Spaces

    private var spaceSwitcher: some View {
        VStack(spacing: 6) {
            Divider()
            HStack(spacing: 4) {
                ForEach(controller.spaces) { item in
                    Button {
                        controller.selectSpace(item.id)
                    } label: {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12))
                            .frame(width: 26, height: 22)
                            .foregroundStyle(
                                item.id == controller.activeSpaceID
                                    ? Color(item.tint.color) : .secondary
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        item.id == controller.activeSpaceID
                                            ? Color(item.tint.color).opacity(0.18)
                                            : .clear))
                    }
                    .buttonStyle(.plain)
                    .help(item.name)
                    .dropDestination(for: String.self) { items, _ in
                        guard let dragged = items.first.flatMap(UUID.init(uuidString:))
                        else { return false }
                        controller.moveTab(dragged, toSpace: item.id)
                        return true
                    }
                    .contextMenu {
                        Button("Rename Space…") {
                            editingSpace = item.id
                            spaceNameDraft = item.name
                        }
                    }
                }
                Button {
                    controller.addSpace()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("New space")
                Spacer(minLength: 0)
            }
            HStack {
                if editingSpace == space.id {
                    TextField("Space name", text: $spaceNameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .focused($nameFieldFocused)
                        .onSubmit {
                            controller.renameSpace(space.id, to: spaceNameDraft)
                            editingSpace = nil
                        }
                        .onAppear { nameFieldFocused = true }
                } else {
                    Text(space.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .onTapGesture(count: 2) {
                            editingSpace = space.id
                            spaceNameDraft = space.name
                        }
                }
                Spacer()
            }
        }
    }
}
