import AppKit
import SwiftUI
import MacportKit

/// The Parallels Desktop + UTM style Left Sidebar / Virtual Machine Library.
///
/// Features:
/// 1. Top Macport Brand Header (Apple Pro squircle emblem + bold typography)
/// 2. Control Center / Gallery quick-access row (`⌘0`)
/// 3. Organized Virtual Machine categories (Windows, Linux, macOS)
/// 4. Rich VM list items with OS badges, hardware specs summary, and live status dots
/// 5. Docked "+ New Machine" and "Import" buttons at the bottom
@MainActor
struct VMLibraryView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState

    @Binding var selection: VMConfiguration.ID?

    @State private var hoveredVMId: UUID?
    @State private var searchText = ""

    private var allMachines: [VMConfiguration] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return store.machines
        }
        let query = searchText.lowercased()
        return store.machines.filter {
            $0.name.lowercased().contains(query) ||
            $0.guest.displayName.lowercased().contains(query)
        }
    }

    private var windowsMachines: [VMConfiguration] {
        allMachines.filter { $0.guest == .windowsARM }
    }

    private var linuxMachines: [VMConfiguration] {
        allMachines.filter { $0.guest == .linuxARM }
    }

    private var macosMachines: [VMConfiguration] {
        allMachines.filter { $0.guest == .macOSGuest }
    }

    private var otherMachines: [VMConfiguration] {
        allMachines.filter { $0.guest != .windowsARM && $0.guest != .linuxARM && $0.guest != .macOSGuest }
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Brand Logo Header
            brandHeader
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 14)

            // Search Filter Field
            searchBar
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            // MARK: - Navigation List
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Control Center Gallery Row
                    controlCenterRow

                    Divider()
                        .padding(.horizontal, 4)

                    if store.machines.isEmpty {
                        emptyLibraryPrompt
                    } else {
                        // Windows Section
                        if !windowsMachines.isEmpty {
                            machineSection(title: "WINDOWS", icon: "square.grid.2x2.fill", color: .blue, machines: windowsMachines)
                        }

                        // Linux Section
                        if !linuxMachines.isEmpty {
                            machineSection(title: "LINUX", icon: "terminal.fill", color: .orange, machines: linuxMachines)
                        }

                        // macOS Section
                        if !macosMachines.isEmpty {
                            machineSection(title: "MACOS", icon: "apple.logo", color: .secondary, machines: macosMachines)
                        }

                        // Other / Custom Section
                        if !otherMachines.isEmpty {
                            machineSection(title: "VIRTUAL MACHINES", icon: "opticaldisc.fill", color: .purple, machines: otherMachines)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            // MARK: - Bottom Actions Bar
            Divider()

            bottomActionsBar
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 230, idealWidth: 250, maxWidth: 290)
        .background(Color.macportWindow)
    }

    // MARK: - Brand Header

    private var brandHeader: some View {
        HStack(spacing: 10) {
            MacportAppLogoView(size: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("Macport")
                    .font(.system(size: 15, weight: .bold))
                Text("Hypervisor Manager")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                state.isPresentingCreateSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.macportCard))
                    .overlay(Circle().stroke(Color.macportBorderSubtle, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("New Virtual Machine… (⌘N)")
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Search virtual machines…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.macportCard))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.macportBorderSubtle, lineWidth: 1))
    }

    // MARK: - Control Center Gallery Row

    private var controlCenterRow: some View {
        let isGallerySelected = (selection == nil && ui.viewMode == .gallery)

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selection = nil
                ui.viewMode = .gallery
            }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.macportAccent.opacity(0.18))
                        .frame(width: 24, height: 24)
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.macportAccent)
                }

                Text("Control Center")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(store.machines.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.macportInset))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isGallerySelected ? Color.macportCard : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isGallerySelected ? Color.macportAccent.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Machine Section

    private func machineSection(title: String, icon: String, color: Color, machines: [VMConfiguration]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)

                Spacer()

                Text("\(machines.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)

            VStack(spacing: 2) {
                ForEach(machines) { config in
                    machineRow(config)
                }
            }
        }
    }

    // MARK: - Machine Row

    private func machineRow(_ config: VMConfiguration) -> some View {
        let isSelected = (selection == config.id)
        let isHovered = (hoveredVMId == config.id)
        let vmState = state.state(for: config.id)

        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                selection = config.id
                ui.viewMode = .split
            }
        } label: {
            HStack(spacing: 9) {
                // OS Avatar Tile
                GuestAvatar(guest: config.guest, size: 26)

                // Info
                VStack(alignment: .leading, spacing: 1) {
                    Text(config.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 4) {
                        Text("\(config.cpuCount) vCPU")
                        Text("•")
                        Text(config.memoryBytes.gbString)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                // Status Indicator
                HStack(spacing: 5) {
                    if vmState.isActive {
                        Circle()
                            .fill(Color.macportRunning)
                            .frame(width: 8, height: 8)
                            .shadow(color: Color.macportRunning.opacity(0.6), radius: 3)
                    } else if vmState == .paused {
                        Circle()
                            .fill(Color.macportPaused)
                            .frame(width: 8, height: 8)
                    } else {
                        Circle()
                            .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                            .frame(width: 7, height: 7)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.macportCard : (isHovered ? Color.macportCard.opacity(0.5) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.macportAccent.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredVMId = hovering ? config.id : nil
        }
        .contextMenu {
            if vmState.isActive {
                Button("Shut Down (Graceful)") {
                    Task { await state.stop(id: config.id, graceful: true) }
                }
                Button("Force Off (Instant)", role: .destructive) {
                    Task { await state.stop(id: config.id, graceful: false) }
                }

                Divider()

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
                Button("Start Virtual Machine") {
                    state.start(config, in: store)
                }
            }

            Divider()

            Button("Machine Settings…") {
                ui.selection = config.id
                ui.isPresentingSettings = true
            }

            Button("Snapshots…") {
                ui.selection = config.id
                ui.isPresentingSnapshots = true
            }

            Button("Clone Machine…") {
                ui.cloneTarget = config
            }

            Button("Rename…") {
                ui.renameTarget = config
            }

            Divider()

            Button("Add to Applications") {
                exportVM(config, to: .applications)
            }

            Button("Add to Desktop") {
                exportVM(config, to: .desktop)
            }

            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.bundleURL(for: config)])
            }

            Divider()

            Button("Delete…", role: .destructive) {
                ui.deleteTarget = config
            }
        }
    }

    // MARK: - Empty Library Prompt

    private var emptyLibraryPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No Virtual Machines")
                .font(.system(size: 12, weight: .semibold))
            Text("Click '+ New Machine' below to install Windows 11, Linux, or macOS.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom Actions Bar

    private var bottomActionsBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    ui.isPresentingImport = true
                } label: {
                    Label("Import", systemImage: "arrow.down.doc")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)

                Button {
                    state.isPresentingCreateSheet = true
                } label: {
                    Label("New Machine", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            // Host Capacity Mini Pill
            HStack {
                Text("\(state.registry.capacity.processorCount) Apple Silicon Cores")
                Text("•")
                Text(MacportFormat.fileSize(state.registry.capacity.physicalMemory))
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
    }

    private func exportVM(_ config: VMConfiguration, to destination: MacportAppPublisher.Destination) {
        do {
            let appURL = try MacportAppPublisher.exportLauncherApp(
                bottleId: config.id,
                bottleName: config.name,
                appName: config.name,
                executable: "macport-vm",
                iconURL: nil,
                to: destination
            )
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } catch {
            // Ignored
        }
    }
}
