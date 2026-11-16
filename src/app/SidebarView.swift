import SwiftUI

// Arc's sidebar: the space's colour washes over it, favourites sit as a grid
// of tiles at the top, the open tabs are rounded rows below, and the bottom
// bar holds the new-tab button next to the space switcher.
struct SidebarView: View {
    @ObservedObject var controller: BrowserController
    @FocusState private var addressFocused: Bool
    @State private var hoveredTab: UUID?
    @State private var hoveringChrome = false
    @State private var editingSpace: UUID?
    @State private var spaceNameDraft = ""
    @FocusState private var nameFieldFocused: Bool
    @State private var dragStartWidth: CGFloat?

    private var space: SpaceData { controller.activeSpace }
    private var tint: Color { Color(space.tint.color) }

    var body: some View {
        ZStack(alignment: .trailing) {
            content
            resizeHandle
        }
        .background(
            LinearGradient(
                colors: [tint.opacity(0.28), tint.opacity(0.10)],
                startPoint: .top, endPoint: .bottom)
        )
        .animation(.easeInOut(duration: 0.25), value: space.id)
    }

    private var content: some View {
        VStack(spacing: 10) {
            navigationRow
            addressField
            favorites
            tabList
            bottomBar
        }
        .padding(.horizontal, 10)
        .padding(.top, controller.isFullscreen ? 12 : 38)  // Clear the traffic lights.
        .padding(.bottom, 10)
        .onChange(of: controller.focusAddressToken) { _, _ in
            addressFocused = true
        }
        .onHover { hoveringChrome = $0 }
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

    // Arc keeps the chrome quiet: the arrows fade in when the pointer is here.
    private var navigationRow: some View {
        HStack(spacing: 2) {
            navButton("sidebar.left", enabled: true) { controller.toggleSidebar() }
            Spacer(minLength: 0)
            navButton("chevron.left", enabled: controller.canGoBack) {
                controller.goBack()
            }
            navButton("chevron.right", enabled: controller.canGoForward) {
                controller.goForward()
            }
            navButton("arrow.clockwise", enabled: true) { controller.reload() }
        }
        .opacity(hoveringChrome ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: hoveringChrome)
    }

    private func navButton(
        _ symbol: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(
                    enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary)
                )
                .background(
                    Circle().fill(.white.opacity(enabled ? 0.18 : 0))
                )
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
                .font(.system(size: 11, weight: .semibold))
            TextField("Search or enter address", text: $controller.addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($addressFocused)
                .onSubmit {
                    controller.navigate(to: controller.addressText)
                    addressFocused = false
                }
                .onTapGesture { controller.openCommandBar(mode: .current) }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        )
    }

    // MARK: - Favourites

    // Pinned tabs become a grid of tiles, the way Arc shows favourites.
    @ViewBuilder
    private var favorites: some View {
        let pinned = space.pinnedTabs
        if !pinned.isEmpty {
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 6), count: 4)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(pinned) { tab in
                    favoriteTile(tab)
                }
            }
        }
    }

    private func favoriteTile(_ tab: TabData) -> some View {
        let isActive = space.activeTabID == tab.id
        return icon(for: tab, size: 17)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(isActive ? 0.85 : 0.25))
                    .shadow(
                        color: .black.opacity(isActive ? 0.12 : 0), radius: 3, y: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { controller.activateTab(tab.id) }
            .help(tab.displayTitle)
            .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
            .dropDestination(for: String.self) { items, _ in
                guard let dragged = items.first.flatMap(UUID.init(uuidString:))
                else { return false }
                controller.moveTab(dragged, before: tab.id)
                return true
            }
            .contextMenu {
                Button("Unpin Tab") { controller.togglePin(tab.id) }
                Button("Close Tab") { controller.closeTab(tab.id) }
            }
    }

    // MARK: - Tabs

    private var tabList: some View {
        ScrollView {
            // A plain stack: a sidebar holds tens of rows, not thousands, and
            // it renders whole for the offscreen checks.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(space.unpinnedTabs) { tab in
                    tabRow(tab)
                }
            }
            .padding(.top, 2)
        }
        .scrollIndicators(.never)
    }

    private func tabRow(_ tab: TabData) -> some View {
        let isActive = space.activeTabID == tab.id
        let isHovered = hoveredTab == tab.id
        return HStack(spacing: 8) {
            icon(for: tab, size: 14)
            Text(tab.displayTitle)
                .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
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
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            // Arc lifts the open tab onto a white card and leaves the rest flat.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    .white.opacity(isActive ? 0.85 : (isHovered ? 0.35 : 0))
                )
                .shadow(color: .black.opacity(isActive ? 0.10 : 0), radius: 3, y: 1)
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
    private func icon(for tab: TabData, size: CGFloat) -> some View {
        if controller.loadingTabs.contains(tab.id) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: size, height: size)
        } else if let favicon = controller.favicons[tab.id] {
            Image(nsImage: favicon)
                .resizable()
                .frame(width: size, height: size)
                .cornerRadius(size / 4)
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    // MARK: - Bottom bar

    // New tab lives at the bottom in Arc, with the spaces beside it.
    private var bottomBar: some View {
        VStack(spacing: 8) {
            Button {
                controller.openCommandBar(mode: .newTab)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("New Tab")
                        .font(.system(size: 12.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            spaceSwitcher
        }
    }

    private var spaceSwitcher: some View {
        VStack(spacing: 5) {
            Divider().opacity(0.4)
            HStack {
                if editingSpace == space.id {
                    TextField("Space name", text: $spaceNameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .focused($nameFieldFocused)
                        .onSubmit {
                            controller.renameSpace(space.id, to: spaceNameDraft)
                            editingSpace = nil
                        }
                        .onAppear { nameFieldFocused = true }
                } else {
                    Text(space.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .onTapGesture(count: 2) {
                            editingSpace = space.id
                            spaceNameDraft = space.name
                        }
                }
                Spacer(minLength: 0)
                Button {
                    controller.addSpace()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("New space")
            }
            .padding(.horizontal, 4)

            HStack(spacing: 4) {
                ForEach(controller.spaces) { item in
                    spaceButton(item)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
    }

    private func spaceButton(_ item: SpaceData) -> some View {
        let isActive = item.id == controller.activeSpaceID
        return Button {
            controller.selectSpace(item.id)
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundStyle(
                    isActive ? AnyShapeStyle(Color(item.tint.color))
                        : AnyShapeStyle(.secondary)
                )
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(isActive ? 0.7 : 0)))
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
}
