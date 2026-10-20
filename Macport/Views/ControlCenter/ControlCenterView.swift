import AppKit
import SwiftUI
import MacportKit

/// The Parallels Desktop style Control Center: a modern gallery of virtual machine
/// cards with live preview viewports, interactive hover controls, OS badges, and
/// instant power actions.
@MainActor
struct ControlCenterView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState

    @State private var searchText = ""
    @State private var filterState: VMFilter = .all

    enum VMFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case running = "Running"
        case stopped = "Stopped"
        var id: String { rawValue }
    }

    private var filteredMachines: [VMConfiguration] {
        store.machines.filter { config in
            let matchesSearch = searchText.isEmpty ||
                config.name.localizedCaseInsensitiveContains(searchText) ||
                config.guest.displayName.localizedCaseInsensitiveContains(searchText)

            let isMachineActive = state.state(for: config.id).isActive
            switch filterState {
            case .all:
                return matchesSearch
            case .running:
                return matchesSearch && isMachineActive
            case .stopped:
                return matchesSearch && !isMachineActive
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topControlBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if store.machines.isEmpty {
                        emptyGalleryState
                    } else {
                        gridSection
                    }
                }
                .padding(24)
            }

            Divider()
            hostCapacityFooter
        }
        .background(Color.macportWindow)
    }

    // MARK: - Top Bar

    private var topControlBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                TextField("Search machines…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.macportInset))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.macportBorderSubtle, lineWidth: 1))
            .frame(maxWidth: 260)

            Picker("Filter", selection: $filterState) {
                ForEach(VMFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)

            Spacer()

            HStack(spacing: 10) {
                Button {
                    ui.isPresentingImport = true
                } label: {
                    Label("Import", systemImage: "arrow.down.doc")
                }
                .controlSize(.regular)

                Button {
                    state.isPresentingCreateSheet = true
                } label: {
                    Label("New Machine", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.macportCard.opacity(0.6))
    }

    // MARK: - Machine Grid

    private var gridSection: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 20)],
            spacing: 20
        ) {
            ForEach(filteredMachines) { config in
                ControlCenterVMCard(config: config)
            }

            newMachineCard
        }
    }

    // MARK: - New Machine Card (Parallels Style)

    private var newMachineCard: some View {
        Button {
            state.isPresentingCreateSheet = true
        } label: {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.macportAccent.opacity(0.12))
                        .frame(width: 54, height: 54)
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.macportAccent)
                }

                VStack(spacing: 4) {
                    Text("Add Machine")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Install Windows, Linux or macOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.macportCard.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(Color.macportBorderStrong.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty Gallery State

    private var emptyGalleryState: some View {
        VStack(spacing: 20) {
            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)

            VStack(spacing: 6) {
                Text("Parallels-Class Control Center")
                    .font(.title2.weight(.bold))
                Text("No virtual machines created yet. Get started in seconds.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Button {
                    state.isPresentingCreateSheet = true
                } label: {
                    Label("Create Virtual Machine…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    ui.isPresentingImport = true
                } label: {
                    Label("Import Disk Image…", systemImage: "arrow.down.doc")
                }
                .controlSize(.large)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Host Capacity Footer

    private var hostCapacityFooter: some View {
        let allocatedMem = state.allocatedMemoryBytes()
        let totalMem = state.registry.capacity.physicalMemory
        let allocatedCores = state.allocatedProcessors()
        let totalCores = state.registry.capacity.processorCount

        let memFraction = totalMem > 0 ? Double(allocatedMem) / Double(totalMem) : 0
        let cpuFraction = totalCores > 0 ? Double(allocatedCores) / Double(totalCores) : 0

        return HStack(spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "memorychip")
                    .foregroundStyle(Color.macportAccent)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Guest RAM: \(allocatedMem.gbString) of \(totalMem.gbString)")
                        .font(.system(size: 11, weight: .medium))
                    ProgressView(value: memFraction)
                        .progressViewStyle(.linear)
                        .frame(width: 130)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .foregroundStyle(Color.macportAccent)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Guest vCPUs: \(allocatedCores) of \(totalCores) cores")
                        .font(.system(size: 11, weight: .medium))
                    ProgressView(value: cpuFraction)
                        .progressViewStyle(.linear)
                        .frame(width: 130)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(ui.activeCount > 0 ? Color.macportRunning : Color.macportOff)
                    .frame(width: 8, height: 8)
                Text(ui.activeCount == 0 ? "All VMs Inactive" : "\(ui.activeCount) VM\(ui.activeCount == 1 ? "" : "s") Active")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.macportCard)
    }
}

// MARK: - Control Center VM Card

@MainActor
struct ControlCenterVMCard: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState

    let config: VMConfiguration

    @State private var isHovered = false

    private var vmState: VMState { state.state(for: config.id) }
    private var engineType: any VMEngine.Type { state.hostingEngine(for: config) }

    var body: some View {
        VStack(spacing: 0) {
            previewHeader
            cardFooter
        }
        .background(Color.macportCard)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isHovered ? Color.macportAccent.opacity(0.4) : Color.macportBorderSubtle, lineWidth: isHovered ? 1.5 : 1)
        )
        .shadow(color: isHovered ? Color.black.opacity(0.3) : Color.black.opacity(0.12), radius: isHovered ? 12 : 5, y: isHovered ? 6 : 2)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            ui.selection = config.id
            ui.viewMode = .split
        }
        .contextMenu {
            cardContextMenu
        }
    }

    // MARK: - Preview Header with OS Artwork and Hover Controls

    private var previewHeader: some View {
        ZStack {
            // Background OS Theme
            guestWallpaperBackground
                .frame(height: 140)

            // Top pill overlay
            VStack {
                HStack {
                    StatusPill(state: vmState)
                    Spacer()
                    EngineChip(config: config)
                }
                .padding(10)
                Spacer()
            }

            // Center Content: OS logo or live status
            if vmState.isActive {
                VStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.macportRunning)
                        .shadow(color: Color.macportRunning.opacity(0.5), radius: 8)

                    if let startedAt = state.startedAt(for: config.id) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(MacportFormat.uptime(since: startedAt, now: context.date))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.black.opacity(0.6)))
                        }
                    }
                }
            } else {
                guestCenteredIcon
            }

            // Hover Action Overlay (Parallels Style)
            if isHovered {
                hoverControlsOverlay
            }
        }
        .frame(height: 140)
        .clipped()
    }

    private var guestWallpaperBackground: some View {
        Group {
            switch config.guest {
            case .windowsARM:
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.15, blue: 0.35), Color(red: 0.10, green: 0.35, blue: 0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .linuxARM:
                LinearGradient(
                    colors: [Color(red: 0.20, green: 0.02, blue: 0.18), Color(red: 0.45, green: 0.15, blue: 0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .macOSGuest:
                LinearGradient(
                    colors: [Color(red: 0.15, green: 0.16, blue: 0.20), Color(red: 0.25, green: 0.28, blue: 0.34)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var guestCenteredIcon: some View {
        Group {
            switch config.guest {
            case .windowsARM:
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 6)
            case .linuxARM:
                Image(systemName: "terminal.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 6)
            case .macOSGuest:
                Image(systemName: "apple.logo")
                    .font(.system(size: 38))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 6)
            }
        }
    }

    private var hoverControlsOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.92)

            HStack(spacing: 16) {
                if vmState.isActive {
                    Button {
                        if vmState == .paused {
                            Task { await state.resume(id: config.id) }
                        } else {
                            Task { await state.pause(id: config.id) }
                        }
                    } label: {
                        Circle()
                            .fill(Color.macportPaused.opacity(0.2))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: vmState == .paused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(Color.macportPaused)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(vmState == .paused ? "Resume machine" : "Pause machine")

                    Button {
                        Task { await state.stop(id: config.id, graceful: true) }
                    } label: {
                        Circle()
                            .fill(Color.macportDanger.opacity(0.2))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(Color.macportDanger)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Shut down machine")
                } else {
                    Button {
                        state.start(config, in: store)
                    } label: {
                        Circle()
                            .fill(Color.macportRunning)
                            .frame(width: 52, height: 52)
                            .shadow(color: Color.macportRunning.opacity(0.4), radius: 8, y: 3)
                            .overlay(
                                Image(systemName: "play.fill")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Start machine")
                }
            }

            // Top right quick buttons on hover
            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Button {
                            ui.selection = config.id
                            ui.isPresentingSnapshots = true
                        } label: {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 12))
                                .padding(6)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Snapshots")

                        Button {
                            ui.selection = config.id
                            ui.isPresentingSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 12))
                                .padding(6)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Machine Settings")
                    }
                    .padding(8)
                }
                Spacer()
            }
        }
        .transition(.opacity)
    }

    // MARK: - Card Footer

    private var cardFooter: some View {
        HStack(alignment: .center, spacing: 10) {
            GuestAvatar(guest: config.guest, size: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(config.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(config.cpuCount) vCPU · \(config.memoryBytes.gbString) RAM · \(config.diskBytes.gbString) Disk")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Menu {
                cardContextMenu
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.macportCard)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var cardContextMenu: some View {
        if vmState.isActive {
            Button("Shut Down") {
                Task { await state.stop(id: config.id, graceful: true) }
            }
            Button("Force Off", role: .destructive) {
                Task { await state.stop(id: config.id, graceful: false) }
            }
            if vmState == .paused {
                Button("Resume") {
                    Task { await state.resume(id: config.id) }
                }
            } else {
                Button("Pause") {
                    Task { await state.pause(id: config.id) }
                }
            }
        } else {
            Button("Start") {
                state.start(config, in: store)
            }
        }

        Divider()

        Button("Open Machine") {
            ui.selection = config.id
            ui.viewMode = .split
        }

        Button("Machine Settings…") {
            ui.selection = config.id
            ui.isPresentingSettings = true
        }

        Button("Snapshots…") {
            ui.selection = config.id
            ui.isPresentingSnapshots = true
        }

        Divider()

        Button("Clone…") {
            ui.cloneTarget = config
        }
        .disabled(vmState.isActive)

        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([store.bundleURL(for: config)])
        }

        Divider()

        Button("Delete…", role: .destructive) {
            ui.deleteTarget = config
        }
        .disabled(state.deleteRefusal(for: config) != nil)
    }
}
