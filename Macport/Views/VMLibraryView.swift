import AppKit
import SwiftUI
import MacportKit

/// Authentic CrossOver-style Left Sidebar.
///
/// Features:
/// 1. Top Macport Brand Header (Apple Pro squircle emblem + bold letter-spaced logo)
/// 2. "Home" navigation row with blue house icon
/// 3. "BOTTLES" section listing all Windows bottles with subtle active pill selection
/// 4. "VIRTUAL MACHINES" section for any other hypervisor guests (Linux, macOS, Windows ARM)
/// 5. Docked "+ Install" button at the bottom
@MainActor
struct VMLibraryView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState

    @Binding var selection: VMConfiguration.ID?

    @State private var hoveredBottleId: UUID?

    private var bottleConfigs: [VMConfiguration] {
        store.machines.filter { $0.guest == .windowsApp }
    }

    private var hypervisorConfigs: [VMConfiguration] {
        store.machines.filter { $0.guest != .windowsApp }
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Brand Logo Header
            brandHeader
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 20)

            // MARK: - Navigation List
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Home Row
                    homeNavRow

                    // Bottles Section
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("BOTTLES")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(white: 0.5))
                                .tracking(0.5)

                            Spacer()

                            Button {
                                state.isPresentingCreateSheet = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color(white: 0.6))
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("New Bottle…")
                        }
                        .padding(.horizontal, 12)

                        if bottleConfigs.isEmpty {
                            Text("No bottles created")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(white: 0.4))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                        } else {
                            VStack(spacing: 2) {
                                ForEach(bottleConfigs) { config in
                                    bottleRow(config)
                                }
                            }
                        }
                    }

                    // Virtual Machines Section (if any non-Wine VMs exist)
                    if !hypervisorConfigs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("VIRTUAL MACHINES")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(white: 0.5))
                                .tracking(0.5)
                                .padding(.horizontal, 12)

                            VStack(spacing: 2) {
                                ForEach(hypervisorConfigs) { config in
                                    vmRow(config)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            // MARK: - Bottom Docked Install Bar
            Divider()
                .background(Color.white.opacity(0.08))

            bottomInstallBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 210, idealWidth: 230, maxWidth: 260)
        .background(Color.crossoverSidebar)
    }

    // MARK: - Brand Header

    private var brandHeader: some View {
        HStack(spacing: 12) {
            MacportAppLogoView(size: 38)

            // Stylized Title
            VStack(alignment: .leading, spacing: 1) {
                Text("MACPORT")
                    .font(.system(size: 16, weight: .heavy, design: .default))
                    .tracking(2.5)
                    .foregroundStyle(.white)

                Text("PRO EDITION")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Color.crossoverBlue)
            }

            Spacer()
        }
    }

    // MARK: - Home Navigation Row

    private var homeNavRow: some View {
        let isSelected = (selection == nil)

        return Button {
            selection = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "house.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.crossoverBlue)
                    .frame(width: 18)

                Text("Home")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.crossoverCard : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottle Row

    private func bottleRow(_ config: VMConfiguration) -> some View {
        let isSelected = (selection == config.id)
        let isHovered = (hoveredBottleId == config.id)
        let vmState = state.state(for: config.id)

        return Button {
            selection = config.id
        } label: {
            HStack(spacing: 8) {
                // Active state dot / Bottle icon
                if vmState.isActive {
                    Circle()
                        .fill(Color.macportRunning)
                        .frame(width: 7, height: 7)
                        .shadow(color: Color.macportRunning.opacity(0.8), radius: 3)
                } else {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.crossoverBlue : Color(white: 0.5))
                        .frame(width: 14)
                }

                Text(config.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : Color(white: 0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if vmState.isActive {
                    Text("RUNNING")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.macportRunning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.macportRunning.opacity(0.18)))
                } else if isHovered {
                    Menu {
                        Button("Run Application") {
                            state.start(config, in: store)
                        }
                        Button("Open C: Drive") {
                            let driveC = WineBottleManager.driveCURL(for: store.bundleURL(for: config))
                            NSWorkspace.shared.open(driveC)
                        }
                        Button("Wine Configuration") {
                            launchWinecfg(config)
                        }
                        Divider()
                        Button("Duplicate Bottle…") {
                            ui.cloneTarget = config
                        }
                        Button("Delete Bottle…", role: .destructive) {
                            ui.deleteTarget = config
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.6))
                            .frame(width: 16, height: 16)
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.crossoverCard : (isHovered ? Color(white: 0.16) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredBottleId = hovering ? config.id : nil
        }
        .contextMenu {
            if vmState.isActive {
                Button("Quit All Applications in Bottle", role: .destructive) {
                    Task { await state.stop(id: config.id, graceful: true) }
                }
            } else {
                Button("Run Application") {
                    state.start(config, in: store)
                }
            }

            Button("Open C: Drive") {
                let driveC = WineBottleManager.driveCURL(for: store.bundleURL(for: config))
                NSWorkspace.shared.open(driveC)
            }

            Button("Wine Configuration (winecfg)") {
                launchWinecfg(config)
            }

            Divider()

            Button("Add to Applications…") {
                exportBottle(config, to: .applications)
            }

            Button("Add to Desktop…") {
                exportBottle(config, to: .desktop)
            }

            Divider()

            Button("Duplicate Bottle…") {
                ui.cloneTarget = config
            }

            Button("Delete Bottle…", role: .destructive) {
                ui.deleteTarget = config
            }
        }
    }

    private func launchWinecfg(_ config: VMConfiguration) {
        let bundleURL = store.bundleURL(for: config)
        Task {
            let engine = (state.instance(for: config.id)?.engine as? WineEngine) ?? WineEngine()
            try? await engine.launchExecutable("winecfg", in: bundleURL, metal: true)
        }
    }

    private func exportBottle(_ config: VMConfiguration, to destination: MacportAppPublisher.Destination) {
        let bundleURL = store.bundleURL(for: config)
        let shortcuts = WineBottleManager.scanInstalledShortcuts(in: bundleURL)
        let primary = config.wineSettings?.primaryExecutable
        let match = shortcuts.first(where: { $0.executable == primary })
        let targetName = match?.name ?? config.name
        let exec = primary ?? shortcuts.first?.executable ?? "explorer.exe"
        let icon = match?.iconURL ?? shortcuts.first?.iconURL

        do {
            let appURL = try MacportAppPublisher.exportLauncherApp(
                bottleId: config.id,
                bottleName: config.name,
                appName: targetName,
                executable: exec,
                iconURL: icon,
                to: destination
            )
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } catch {
            print("Failed to export bottle: \(error.localizedDescription)")
        }
    }

    // MARK: - Hypervisor VM Row

    private func vmRow(_ config: VMConfiguration) -> some View {
        let isSelected = (selection == config.id)
        let vmState = state.state(for: config.id)

        return Button {
            selection = config.id
        } label: {
            HStack(spacing: 8) {
                StateDot(state: vmState)

                Text(config.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : Color(white: 0.85))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.crossoverCard : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if vmState.isActive {
                Button("Shut Down") {
                    Task { await state.stop(id: config.id, graceful: true) }
                }
                Button("Force Off", role: .destructive) {
                    Task { await state.stop(id: config.id, graceful: false) }
                }
            } else {
                Button("Start Virtual Machine") {
                    state.start(config, in: store)
                }
            }

            Divider()

            Button("Add to Applications…") {
                exportVM(config, to: .applications)
            }

            Button("Add to Desktop…") {
                exportVM(config, to: .desktop)
            }

            Divider()

            Button("Hardware Settings…") {
                selection = config.id
                ui.isPresentingSettings = true
            }

            Button("Snapshots…") {
                selection = config.id
                ui.isPresentingSnapshots = true
            }

            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.bundleURL(for: config)])
            }

            Divider()

            Button("Clone Machine…") {
                ui.cloneTarget = config
            }
            .disabled(vmState.isActive)

            Button("Delete Machine…", role: .destructive) {
                ui.deleteTarget = config
            }
            .disabled(state.deleteRefusal(for: config) != nil)
        }
    }

    private func exportVM(_ config: VMConfiguration, to destination: MacportAppPublisher.Destination) {
        do {
            let appURL = try MacportAppPublisher.exportVMLauncherApp(
                vmId: config.id,
                vmName: config.name,
                guest: config.guest,
                to: destination
            )
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } catch {
            print("Failed to export VM: \(error.localizedDescription)")
        }
    }

    // MARK: - Bottom Install Bar

    private var bottomInstallBar: some View {
        Button {
            state.isPresentingCreateSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.crossoverBlue)

                Text("Install Application…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: 0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
