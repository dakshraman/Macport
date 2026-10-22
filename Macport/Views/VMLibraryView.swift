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
                        Text("BOTTLES")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(white: 0.5))
                            .tracking(0.5)
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
            // Apple Pro Titanium Squircle Icon with glow
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.25), Color(white: 0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)

                // Hypervisor gateway emblem with cyan accent
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.crossoverBlue, lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                        .rotationEffect(.degrees(45))

                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.crossoverBlue)
                }
            }

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
        let vmState = state.state(for: config.id)

        return Button {
            selection = config.id
        } label: {
            HStack(spacing: 8) {
                // Active state dot
                Circle()
                    .fill(vmState.isActive ? Color.macportRunning : Color.clear)
                    .frame(width: 5, height: 5)

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
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.macportRunning.opacity(0.15)))
                }
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

            Divider()

            Button("Delete Bottle…", role: .destructive) {
                ui.deleteTarget = config
            }
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
    }

    // MARK: - Bottom Install Bar

    private var bottomInstallBar: some View {
        Button {
            state.isPresentingCreateSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.square.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.crossoverBlue)

                Text("Install")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
