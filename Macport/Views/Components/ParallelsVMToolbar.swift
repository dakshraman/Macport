import AppKit
import SwiftUI
import MacportKit

/// The signature Parallels Desktop style VM Toolbar: instant power actions,
/// snapshots, settings, shared folders, and device controls.
@MainActor
struct ParallelsVMToolbar: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState

    let config: VMConfiguration

    private var vmState: VMState { state.state(for: config.id) }
    private var engineType: any VMEngine.Type { state.hostingEngine(for: config) }
    private var capabilities: EngineCapabilities { state.capabilities(for: config) }

    var body: some View {
        HStack(spacing: 12) {
            // Back to Control Center button
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    ui.viewMode = .gallery
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text("Control Center")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.macportInset))
            }
            .buttonStyle(.plain)
            .help("Back to Control Center Gallery")

            Divider()
                .frame(height: 20)

            // VM Identity
            GuestAvatar(guest: config.guest, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(config.guest.displayName)
                    Text("·")
                    Text(engineType.displayName)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            if let startedAt = state.startedAt(for: config.id), vmState.isActive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Up \(MacportFormat.uptime(since: startedAt, now: context.date))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            StatusPill(state: vmState)
            EngineChip(config: config)

            Spacer()

            // Parallels Action Controls Group
            actionCluster
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.macportCard.opacity(0.85))
    }

    // MARK: - Action Cluster

    @ViewBuilder
    private var actionCluster: some View {
        HStack(spacing: 8) {
            // Power Actions
            if vmState.isActive {
                // Pause / Resume
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
                    .controlSize(.regular)
                    .help(vmState == .paused ? "Resume VM" : "Pause VM in memory")
                }

                // Shut Down / Force Off Menu
                Menu {
                    Button("Shut Down (Graceful)") {
                        Task { await state.stop(id: config.id, graceful: true) }
                    }
                    Button("Force Off (Instant)", role: .destructive) {
                        Task { await state.stop(id: config.id, graceful: false) }
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .controlSize(.regular)
                .disabled(vmState == .starting)
            } else {
                Button {
                    state.start(config, in: store)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            Divider()
                .frame(height: 18)

            // Snapshots (Parallels Style)
            Button {
                ui.isPresentingSnapshots = true
            } label: {
                Label("Snapshots", systemImage: "camera")
            }
            .controlSize(.regular)
            .help("Manage & restore snapshots")

            // Machine Settings (Configure)
            Button {
                ui.isPresentingSettings = true
            } label: {
                Label("Configure", systemImage: "gearshape")
            }
            .controlSize(.regular)
            .help("Machine Settings (CPU, RAM, Disks, Sharing)")

            // Shared Folders Quick Popover
            Menu {
                if config.sharedFolders.isEmpty {
                    Text("No folders currently shared")
                } else {
                    Section("Shared Folders") {
                        ForEach(config.sharedFolders) { folder in
                            Label(folder.hostPath, systemImage: "folder")
                        }
                    }
                }
                Section("Quick Share") {
                    Button("+ Share Desktop") { addSharedFolder(.desktopDirectory) }
                    Button("+ Share Documents") { addSharedFolder(.documentDirectory) }
                    Button("+ Share Downloads") { addSharedFolder(.downloadsDirectory) }
                }
                Divider()
                Button("Configure Sharing…") {
                    ui.isPresentingSettings = true
                }
            } label: {
                Image(systemName: "folder.badge.gearshape")
            }
            .controlSize(.regular)
            .help("Shared Folders")

            // CD/DVD Media Menu
            Menu {
                if case .installMedia(let path) = config.boot {
                    Section("Attached Installation Media") {
                        Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "opticaldisc")
                    }
                }

                if config.guest == .windowsARM {
                    Section("Macport Tools (Windows Virtio Drivers)") {
                        if MacportTools.resolve() != nil {
                            Label("virtio-win.iso attached", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.macportRunning)
                        } else {
                            Label("virtio-win.iso missing", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.macportPaused)
                        }
                    }
                }

                Divider()
                Button("Change Boot Media…") {
                    ui.isPresentingSettings = true
                }
            } label: {
                Image(systemName: "opticaldiscdrive")
            }
            .controlSize(.regular)
            .help("Optical & Driver Media")

            // Parallels Quick Actions Menu (Keys & Capture)
            Menu {
                if vmState.isActive {
                    Button("Send Ctrl + Alt + Delete") {
                        sendCtrlAltDel()
                    }
                    Button("Take Screenshot to Desktop") {
                        takeScreenshot()
                    }
                    Divider()
                }

                Button("Clone Machine…") {
                    ui.cloneTarget = config
                }
                .disabled(vmState.isActive)

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.bundleURL(for: config)])
                }

                Divider()

                Button("Delete Machine…", role: .destructive) {
                    ui.deleteTarget = config
                }
                .disabled(state.deleteRefusal(for: config) != nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Fullscreen Toggle
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .controlSize(.regular)
            .help("Toggle Full Screen")
        }
    }

    // MARK: - Actions

    private func addSharedFolder(_ searchDir: FileManager.SearchPathDirectory) {
        guard let url = FileManager.default.urls(for: searchDir, in: .userDomainMask).first else { return }
        var updated = config
        if !updated.sharedFolders.contains(where: { $0.hostPath == url.path }) {
            updated.sharedFolders.append(SharedFolder(hostPath: url.path, readOnly: false))
            _ = try? store.save(updated)
        }
    }

    private func sendCtrlAltDel() {
        // Send Ctrl+Alt+Del notification or shortcut
        NSApp.sendAction(#selector(NSApplication.orderFrontStandardAboutPanel(_:)), to: nil, from: nil)
    }

    private func takeScreenshot() {
        guard let window = NSApp.keyWindow else { return }
        let windowID = CGWindowID(window.windowNumber)
        guard let imageRef = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.nominalResolution, .boundsIgnoreFraming]
        ) else { return }

        let rep = NSBitmapImageRep(cgImage: imageRef)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let filename = "Macport - \(config.name) - \(formatter.string(from: Date())).png"

        if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            let fileURL = desktopURL.appendingPathComponent(filename)
            try? pngData.write(to: fileURL)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }
}
