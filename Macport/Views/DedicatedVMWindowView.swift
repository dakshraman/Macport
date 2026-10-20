import AppKit
import SwiftUI
import Virtualization
import MacportKit

/// Dedicated Standalone Virtual Machine Window: matches Parallels Desktop's
/// signature single-VM window architecture. Each running machine opens in its
/// own dedicated macOS window with an edge-to-edge console surface and unified toolbar.
@MainActor
struct DedicatedVMWindowView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState
    @Environment(\.dismiss) private var dismiss

    let config: VMConfiguration

    @State private var scalingMode: DisplayScalingMode = .aspectFit
    @State private var isPresentingSettings = false
    @State private var isPresentingSnapshots = false

    private var vmState: VMState { state.state(for: config.id) }
    private var engineType: any VMEngine.Type { state.hostingEngine(for: config) }
    private var capabilities: EngineCapabilities { state.capabilities(for: config) }

    var body: some View {
        VStack(spacing: 0) {
            // Dedicated Parallels Window Top Bar
            windowToolbar
            Divider()

            // Full Window Edge-to-Edge Console Canvas
            ZStack {
                Color.black.ignoresSafeArea()

                if vmState.isActive, let machine = state.liveMachine(for: config.id) {
                    VMDisplayView(machine: machine)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vmState.isActive, let vncPath = state.vncSocketPath(for: config.id) {
                    EmbeddedVNCDisplayView(socketPath: vncPath)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    stoppedStatePlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Color.macportWindow)
        .sheet(isPresented: $isPresentingSettings) {
            MachineSettingsSheet(config: config)
        }
        .sheet(isPresented: $isPresentingSnapshots) {
            SnapshotsSheet(config: config)
        }
    }

    // MARK: - Toolbar

    private var windowToolbar: some View {
        HStack(spacing: 12) {
            // Machine Avatar & Identity
            GuestAvatar(guest: config.guest, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(config.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(config.guest.displayName)
                    Text("·")
                    Text(engineType.displayName)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            if let startedAt = state.startedAt(for: config.id), vmState.isActive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Up \(MacportFormat.uptime(since: startedAt, now: context.date))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }

            StatusPill(state: vmState)

            Spacer()

            // Quick Sizing & Window Snapping
            HStack(spacing: 4) {
                Button {
                    snapWindowToGuestResolution()
                } label: {
                    Label("Snap Window", systemImage: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Snap window size to guest resolution (⌘1)")
                .keyboardShortcut("1", modifiers: .command)
            }

            Divider()
                .frame(height: 18)

            // Power Actions
            if vmState.isActive {
                if capabilities.pauseResume {
                    Button {
                        if vmState == .paused {
                            Task { await state.resume(id: config.id) }
                        } else {
                            Task { await state.pause(id: config.id) }
                        }
                    } label: {
                        Label(vmState == .paused ? "Resume" : "Pause",
                              systemImage: vmState == .paused ? "play.fill" : "pause.fill")
                    }
                    .controlSize(.small)
                    .help(vmState == .paused ? "Resume VM" : "Pause VM in memory")
                }

                Button(role: .destructive) {
                    Task { await state.stop(id: config.id, graceful: true) }
                } label: {
                    Label("Shut Down", systemImage: "stop.fill")
                }
                .controlSize(.small)
                .help("Shut down guest OS cleanly")
            } else {
                Button {
                    state.start(config, in: store)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Color.macportRunning)
            }

            Divider()
                .frame(height: 18)

            // Snapshots & Settings
            Button {
                isPresentingSnapshots = true
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            .help("Snapshots")

            Button {
                isPresentingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            .help("Configuration")

            // Shared Folders Quick Reveal
            if !config.sharedFolders.isEmpty {
                Menu {
                    ForEach(config.sharedFolders) { folder in
                        Button(folder.displayName) {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.hostPath)
                        }
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                .help("Open Mac Shared Folders in Finder")
            }

            // Fullscreen
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            .help("Enter Full Screen")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.macportCard.opacity(0.95))
    }

    private var stoppedStatePlaceholder: some View {
        VStack(spacing: 16) {
            GuestAvatar(guest: config.guest, size: 64)
            Text(config.name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
            Text("Virtual Machine is Stopped")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))

            Button {
                state.start(config, in: store)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("Start Machine")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.macportRunning)
        }
    }

    // MARK: - Actions

    private func snapWindowToGuestResolution() {
        guard let window = NSApp.keyWindow else { return }
        // Default target 800x600 for Setup or 1024x768
        let targetW: CGFloat = 800
        let targetH: CGFloat = 600
        let titlebarHeight = window.frame.height - (window.contentView?.frame.height ?? window.frame.height)
        var newFrame = window.frame
        newFrame.size = CGSize(width: targetW, height: targetH + titlebarHeight)
        newFrame.origin.y = window.frame.maxY - newFrame.height
        window.setFrame(newFrame, display: true, animate: true)
    }
}
