import AppKit
import SwiftUI
import Virtualization
import MacportKit

/// Detail pane for the selected machine: power actions, host capacity, an
/// honest capability table, and the console path the engine can actually
/// provide.
@MainActor
struct VMDetailView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState

    let config: VMConfiguration

    private var vmState: VMState { state.state(for: config.id) }
    private var engineType: any VMEngine.Type { state.hostingEngine(for: config) }
    private var capabilities: EngineCapabilities { state.capabilities(for: config) }
    private var host: HostCapacity { state.registry.capacity }

    @State private var showTechnicalDetails = false
    @State private var vmStatusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if config.guest != .windowsApp {
                ParallelsVMToolbar(config: config)
                Divider()
            }
            content
        }
        .background(Color.macportWindow)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if config.guest == .windowsApp {
            WineBottleDetailView(config: config)
        } else if vmState.isActive, let machine = state.liveMachine(for: config.id) {
            VMDisplayView(machine: machine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vmState.isActive, let vncPath = state.vncSocketPath(for: config.id) {
            EmbeddedVNCDisplayView(socketPath: vncPath, showOverlayBar: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            hypervisorVMOverview
        }
    }

    // MARK: - Modern Uncluttered Hypervisor VM Overview

    private var hypervisorVMOverview: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let error = state.lastError(for: config.id) {
                    ProblemCard(
                        title: "This machine stopped with an error",
                        message: error,
                        fix: "Open the machine's settings or log, correct the cause, then start it again."
                    )
                }

                if config.guest == .windowsARM, MacportTools.resolve() == nil {
                    ProblemCard(
                        title: "Windows driver media is missing",
                        message: "Windows Setup does not include the Arm64 virtio drivers "
                            + "for Macport's network device and accelerated display. Macport "
                            + "builds a Tools disc from a virtio-win ISO, and none is available yet.",
                        detail: "Looked for \(MacportTools.cachedISOURL.path)\n"
                            + "or \(MacportTools.environmentOverride) in the environment.",
                        fix: "Place the virtio-win \(MacportTools.version) ISO at that path, "
                            + "or point \(MacportTools.environmentOverride) at a copy, then "
                            + "start the machine again. Macport does not redistribute it."
                    )
                }

                if let message = vmStatusMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.macportRunning)
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                        Spacer()
                        Button(action: { vmStatusMessage = nil }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.crossoverCard))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.macportRunning.opacity(0.3), lineWidth: 1))
                }

                if let message = vmStatusMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.macportRunning)
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                        Spacer()
                        Button(action: { vmStatusMessage = nil }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.crossoverCard))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.macportRunning.opacity(0.3), lineWidth: 1))
                }

                // MARK: - Hero VM Console Card (Clean & Modern)
                VStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.crossoverCard, Color.crossoverSidebar],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                            .frame(height: 220)

                        VStack(spacing: 14) {
                            GuestAvatar(guest: config.guest, size: 54)
                                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

                            VStack(spacing: 4) {
                                Text(config.name)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)

                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(vmState.isActive ? Color.macportRunning : Color(white: 0.45))
                                        .frame(width: 7, height: 7)
                                    Text(vmState.isActive ? "Running" : "Powered Off")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.crossoverTextSecondary)
                                }
                            }

                            Button {
                                if vmState.isActive {
                                    Task { await state.stop(id: config.id, graceful: true) }
                                } else {
                                    state.start(config, in: store)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: vmState.isActive ? "stop.fill" : "play.fill")
                                        .font(.system(size: 12, weight: .bold))
                                    Text(vmState.isActive ? "Shut Down" : "Start Virtual Machine")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(vmState.isActive ? Color.crossoverDangerBg : Color.crossoverBlue))
                                .overlay(Capsule().stroke(vmState.isActive ? Color.crossoverDangerText.opacity(0.4) : Color.white.opacity(0.2), lineWidth: 1))
                                .shadow(color: (vmState.isActive ? Color.crossoverDangerText : Color.crossoverBlue).opacity(0.3), radius: 6, y: 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // MARK: - Hardware Specs Strip
                    HStack(spacing: 10) {
                        specPill(icon: "cpu", label: "\(config.cpuCount) vCPUs")
                        specPill(icon: "memorychip", label: "\(config.memoryBytes.gbString) RAM")
                        specPill(icon: "internaldrive", label: "\(config.diskBytes.gbString) NVMe")
                        specPill(icon: "network", label: config.network.rawValue.capitalized)
                        specPill(icon: "bolt.fill", label: engineType.displayName)
                    }

                    // MARK: - Quick Action Controls
                    HStack(spacing: 10) {
                        actionCardButton(title: "Hardware Settings…", icon: "slider.horizontal.3") {
                            ui.isPresentingSettings = true
                        }
                        actionCardButton(title: "Snapshots…", icon: "camera.badge.clock") {
                            ui.isPresentingSnapshots = true
                        }
                        actionCardButton(title: "Add to Applications", icon: "app.badge.checkmark") {
                            exportVM(to: .applications)
                        }
                        actionCardButton(title: "Add to Desktop", icon: "desktopcomputer") {
                            exportVM(to: .desktop)
                        }
                        actionCardButton(title: "Show in Finder", icon: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.bundleURL(for: config)])
                        }
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.crossoverCanvas)
                )

                // MARK: - Collapsed Diagnostics & Telemetry (No Clutter by default)
                DisclosureGroup(
                    isExpanded: $showTechnicalDetails,
                    content: {
                        VStack(spacing: 16) {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)],
                                alignment: .leading,
                                spacing: 16
                            ) {
                                capacityCard
                                capabilityCard
                                storageCard
                                bootCard
                                if needsRuntimeInstall { runtimeCard }
                            }
                        }
                        .padding(.top, 14)
                    },
                    label: {
                        HStack(spacing: 8) {
                            Image(systemName: "gauge.with.needle")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.crossoverBlue)
                            Text("Advanced Hardware Telemetry & Engine Diagnostics")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                    }
                )
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.crossoverCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.crossoverBorder, lineWidth: 1)
                )
            }
            .padding(24)
        }
        .background(Color.crossoverCanvas)
    }

    private func specPill(icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Color.crossoverBlue)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.crossoverCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.crossoverBorder, lineWidth: 1)
        )
    }

    private func actionCardButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.crossoverButton)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.crossoverBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func exportVM(to destination: MacportAppPublisher.Destination) {
        do {
            let appURL = try MacportAppPublisher.exportVMLauncherApp(
                vmId: config.id,
                vmName: config.name,
                guest: config.guest,
                to: destination
            )
            vmStatusMessage = "Added '\(config.name)' to \(destination.displayName). Launch directly from Spotlight or Launchpad!"
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } catch {
            vmStatusMessage = "Failed to export virtual machine: \(error.localizedDescription)"
        }
    }

    private var externalWindowCard: some View {
        let isWine = engineType.identifier == WineEngine.identifier
        return InfoCard(
            title: isWine ? "Running Natively on macOS" : "Running in its own window",
            subtitle: isWine ? "Wine Translation Layer renders directly on your Mac desktop." : "\(engineType.displayName) draws this guest outside Macport."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if isWine {
                    Text("This Windows application runs natively on macOS with floating Cocoa windows, Dock integration, and Apple Metal GPU acceleration. No virtual machine hypervisor is needed, consuming 0 MB idle RAM.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The guest console is the engine's own window, not a view inside Macport. "
                         + "Embedding needs a capture path this engine does not expose yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("Reveal Bundle") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.bundleURL(for: config)])
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Capacity

    private var capacityCard: some View {
        let allocatedMemory = state.allocatedMemoryBytes()
        let allocatedCPUs = state.allocatedProcessors()
        let reserve = max(AdmissionControl.minimumReserve, host.physicalMemory / 8)
        let memoryFraction = host.physicalMemory > 0
            ? Double(allocatedMemory) / Double(host.physicalMemory)
            : 0
        let cpuFraction = host.processorCount > 0
            ? Double(allocatedCPUs) / Double(host.processorCount)
            : 0

        return InfoCard(
            title: "Host capacity",
            subtitle: "Counted across every active machine, not just this one."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                CapacityBar(
                    caption: "Guest memory allocated, of \(host.physicalMemory.gbString) physical memory",
                    valueText: "\(allocatedMemory.gbString) of \(host.physicalMemory.gbString)",
                    fraction: memoryFraction,
                    detail: "Macport reserves \(reserve.gbString) for macOS before admitting a start."
                )

                CapacityBar(
                    caption: "Guest processors allocated, of \(host.processorCount) host cores",
                    valueText: "\(allocatedCPUs) of \(host.processorCount)",
                    fraction: cpuFraction,
                    detail: "One host core is kept for macOS and the interface."
                )

                if let free = host.freeDiskBytes {
                    if let total = volumeTotalBytes, total > 0 {
                        let used = total > free ? total - free : 0
                        CapacityBar(
                            caption: "Disk used on the volume holding VM bundles",
                            valueText: "\(free.gbString) free of \(total.gbString)",
                            fraction: Double(used) / Double(total),
                            detail: "Each start additionally needs 2 GB plus 5% of that machine's disk free."
                        )
                    } else {
                        KeyValueRow(label: "Free disk", value: free.gbString)
                    }
                } else {
                    KeyValueRow(label: "Free disk", value: "Unavailable")
                }
            }
        }
    }

    private var volumeTotalBytes: UInt64? {
        let url = VMStore.defaultRoot
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        return UInt64(total)
    }

    // MARK: - Capabilities

    private var capabilityCard: some View {
        InfoCard(
            title: "Engine — \(engineType.displayName)",
            subtitle: "What this engine can and cannot do for \(config.guest.displayName)."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(capabilityRows) { row in
                    CapabilityRow(
                        name: row.name,
                        supported: row.supported,
                        verdict: row.verdict,
                        reason: row.reason,
                        nextStep: row.nextStep
                    )
                    if row.id != capabilityRows.last?.id {
                        Divider()
                    }
                }

                if let rationale = EngineRegistry.rationale(for: config) {
                    Divider()
                    Label(rationale, systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private struct CapabilityDescriptor: Identifiable {
        let id: String
        let name: String
        let supported: Bool
        let verdict: String
        let reason: String?
        let nextStep: String?
    }

    private var capabilityRows: [CapabilityDescriptor] {
        var rows: [CapabilityDescriptor] = []

        rows.append(CapabilityDescriptor(
            id: "installer",
            name: "Installer media",
            supported: capabilities.opticalMedia,
            verdict: capabilities.opticalMedia ? "Supported" : "Not available",
            reason: capabilities.opticalMedia
                ? "Attached as a USB CD-ROM, which vendor installers boot from."
                : "Virtualization.framework has no optical device; firmware only reads an ISO's El Torito record on media it identifies as a CD-ROM.",
            nextStep: capabilities.opticalMedia
                ? nil
                : "Windows machines are routed to QEMU, which supplies a real CD-ROM."
        ))

        rows.append(CapabilityDescriptor(
            id: "tpm",
            name: "Virtual TPM 2.0",
            supported: capabilities.tpm,
            verdict: capabilities.tpm ? "Supported" : "Not available",
            reason: capabilities.tpm
                ? "A vTPM device is attached."
                : "No engine Macport ships exposes a virtual TPM yet.",
            nextStep: capabilities.tpm
                ? nil
                : "Windows setup asks for a TPM 2.0 device. Macport supplies the setup answer "
                    + "file automatically — that screen will not stop the install."
        ))

        rows.append(CapabilityDescriptor(
            id: "snapshots",
            name: "Snapshots",
            supported: capabilities.snapshots,
            verdict: capabilities.snapshots ? "Supported" : "Not available",
            reason: capabilities.snapshots
                ? "QEMU stores snapshots in the qcow2 disk; a raw disk must be converted with `macportctl disk convert` first."
                : "Virtualization.framework exposes no snapshot primitive.",
            nextStep: capabilities.snapshots
                ? nil
                : "Use a QEMU machine with a qcow2 disk when you need rollback points."
        ))

        rows.append(CapabilityDescriptor(
            id: "pause",
            name: "Pause and resume",
            supported: capabilities.pauseResume,
            verdict: capabilities.pauseResume ? "Supported" : "Not available",
            reason: capabilities.pauseResume
                ? "The guest is suspended in host memory; it does not survive the app quitting."
                : "This engine has no suspend primitive.",
            nextStep: capabilities.pauseResume
                ? nil
                : "Stop the machine instead; there is no in-memory suspend here."
        ))

        rows.append(CapabilityDescriptor(
            id: "shared-folders",
            name: "Shared folders",
            supported: capabilities.sharedFolders,
            verdict: capabilities.sharedFolders ? "Supported" : "Not available",
            reason: capabilities.sharedFolders
                ? "Host directories are exposed read-only through virtiofs."
                : "QEMU shared folders are not wired up in Macport yet.",
            nextStep: capabilities.sharedFolders
                ? nil
                : "Use Virtualization.framework for guests that need host folders."
        ))

        rows.append(CapabilityDescriptor(
            id: "background",
            name: "Background hosting",
            supported: capabilities.backgroundHosting,
            verdict: capabilities.backgroundHosting ? "Supported" : "Not available",
            reason: capabilities.backgroundHosting
                ? "The guest runs in its own host process and keeps running when Macport quits."
                : "Virtualization.framework's display is bound to this process, so the guest stops when Macport quits.",
            nextStep: capabilities.backgroundHosting
                ? nil
                : "Use QEMU for machines that must keep running after the app is closed."
        ))

        rows.append(CapabilityDescriptor(
            id: "graphics",
            name: "Graphics",
            supported: capabilities.graphics != GraphicsSupport.none,
            verdict: capabilities.graphics.displayName,
            reason: graphicsReason,
            nextStep: capabilities.graphics == .none
                ? "Accelerated 3D needs the engine's GPU path, which is not wired up."
                : nil
        ))

        rows.append(CapabilityDescriptor(
            id: "foreign-arch",
            name: "Foreign-architecture emulation",
            supported: capabilities.foreignArchitectureEmulation,
            verdict: capabilities.foreignArchitectureEmulation ? "Supported" : "Not available",
            reason: capabilities.foreignArchitectureEmulation
                ? "The engine can emulate a different CPU architecture."
                : "Macport runs Arm64 guests; x86 emulation is not offered.",
            nextStep: capabilities.foreignArchitectureEmulation
                ? nil
                : "Use an Arm64 guest. QEMU's TCG emulation is not wired up in Macport."
        ))

        return rows
    }

    private var graphicsReason: String {
        switch capabilities.graphics {
        case .none:
            return "Software framebuffer only — no accelerated 2D or 3D."
        case .accelerated:
            return "Accelerated virtio GPU with a 1920×1080 scanout."
        case .acceleratedDX12:
            return "Accelerated graphics with a DirectX 12 capable path."
        }
    }

    // MARK: - Storage and boot

    private var storageCard: some View {
        let bundle = store.bundleURL(for: config)
        return InfoCard(title: "Storage", subtitle: "One self-contained .macport bundle.") {
            VStack(alignment: .leading, spacing: 8) {
                KeyValueRow(label: "Bundle", value: bundle.lastPathComponent, mono: true)
                KeyValueRow(label: "Folder", value: bundle.deletingLastPathComponent().path, mono: true)
                KeyValueRow(label: "Disk ceiling", value: config.diskBytes.gbString)
                HStack {
                    Button("Reveal Bundle") {
                        NSWorkspace.shared.activateFileViewerSelecting([bundle])
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    private var bootCard: some View {
        InfoCard(title: "Install media") {
            VStack(alignment: .leading, spacing: 8) {
                switch config.boot {
                case .installMedia(let path):
                    KeyValueRow(label: "Image", value: URL(fileURLWithPath: path).lastPathComponent, mono: true)
                    KeyValueRow(label: "Path", value: path, mono: true)
                    Text(bootNote)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Eject") { eject() }
                            .controlSize(.small)
                        Button("Change…") { ui.isPresentingSettings = true }
                            .controlSize(.small)
                        Spacer()
                    }
                case .kernelImage(let kernel, let commandLine):
                    KeyValueRow(label: "Kernel", value: kernel, mono: true)
                    KeyValueRow(label: "Command line", value: commandLine, mono: true)
                    Text("This machine boots a kernel directly; install media is not used.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                case .diskOnly:
                    Text("None — the machine boots from its own disk.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Choose Install Media…") { ui.isPresentingSettings = true }
                        .controlSize(.small)
                }
            }
        }
    }

    private var bootNote: String {
        if engineType.identifier == QEMUEngine.identifier {
            return "Attached as a USB CD-ROM. QEMU presses the boot prompt once so Windows Setup starts."
        }
        return "Presented as a read-only disk: this engine has no optical device, which is why Windows installers cannot boot here."
    }

    private func eject() {
        var updated = config
        updated.boot = .diskOnly
        do {
            _ = try store.save(updated)
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Runtime

    private var needsRuntimeInstall: Bool {
        engineType.identifier == QEMUEngine.identifier && !state.isQEMURuntimeInstalled
    }

    private var runtimeCard: some View {
        InfoCard(title: "QEMU runtime", subtitle: "Macport owns this dependency.") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Not installed", systemImage: "arrow.down.circle")
                    .font(.system(size: 12, weight: .medium))

                Text("QEMU runtime is not installed. Macport installs it for you — 167 MB, about a minute. "
                     + "Nothing is installed system-wide.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let progress = state.runtimeInstallProgress {
                    Text(progress)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }

                Button("Install QEMU") { state.installQEMURuntime() }
                    .controlSize(.small)
                    .disabled(state.isInstallingRuntime)
            }
        }
    }
}

// MARK: - CrossOver-style Wine Bottle Detail View

/// Authentic CrossOver / SaaS-grade Bottle Workspace for Windows applications.
///
/// Features a two-column SaaS layout:
/// - Center Canvas: Curated icon grid for installed games/apps with authentic artwork,
///   quick hover-to-play, and primary application configuration.
/// - Right Inspector: CrossOver-style bottle actions, graphics backends (D3DMetal, DXMT),
///   gaming engine toggles (MSync, MetalFX, HUD), and Windows control panels.
@MainActor
struct WineBottleDetailView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState

    let config: VMConfiguration

    @State private var installedShortcuts: [WineProgramShortcut] = []
    @State private var bottleDiskSize: UInt64 = 0
    @State private var isPresentingRunCommand = false
    @State private var customCommand = ""
    @State private var customArguments = ""
    @State private var statusMessage: String?
    @State private var hoveredShortcutId: String?
    @State private var appSearchQuery = ""
    @State private var hoveredPanelId: String?
    @State private var uninstallShortcutTarget: WineProgramShortcut?
    @State private var isConfirmingShortcutUninstall = false

    private var vmState: VMState { state.state(for: config.id) }
    private var bundleURL: URL { store.bundleURL(for: config) }
    private var wineSettings: WineBottleSettings { config.wineSettings ?? WineBottleSettings() }

    private var bottleTypeDisplayString: String {
        switch wineSettings.bottleTemplate {
        case "win11_64":
            return "Windows 11 64-bit"
        case "win10_64":
            return "Windows 10 64-bit"
        case "win7_64":
            return "Windows 7 64-bit"
        default:
            return wineSettings.bottleTemplate
        }
    }

    private var displayedShortcuts: [WineProgramShortcut] {
        let q = appSearchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return installedShortcuts }
        return installedShortcuts.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            bottleHeader

            HStack(spacing: 0) {
                // Left & Center: Main Applications Grid
                mainCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                    .background(Color.crossoverBorder)

                // Right: CrossOver Bottle Actions & Settings Inspector
                inspectorSidebar
                    .frame(width: 280)
            }
        }
        .background(Color.crossoverCanvas)
        .sheet(isPresented: $isPresentingRunCommand) {
            runCommandSheet
        }
        .confirmationDialog(
            "Uninstall \(uninstallShortcutTarget?.name ?? "Application")?",
            isPresented: $isConfirmingShortcutUninstall,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                if let sc = uninstallShortcutTarget {
                    performUninstallShortcut(sc)
                }
            }
            Button("Cancel", role: .cancel) {
                uninstallShortcutTarget = nil
            }
        } message: {
            Text("This will launch the application's uninstaller in '\(config.name)' and clean up its Mac launcher wrappers in Applications and Desktop.")
        }
        .onAppear {
            refreshBottleData()
        }
    }

    // MARK: - Bottle Header (CrossOver-Parity)

    private var bottleHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(config.name)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)

                        Button {
                            ui.renameTarget = config
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.crossoverTextSecondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Rename Bottle")
                    }

                    Text("Bottle Type: \(bottleTypeDisplayString)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.crossoverTextSecondary)
                }

                Spacer()

                HStack(spacing: 16) {
                    // Inline shortcut search bar if bottle has multiple apps
                    if installedShortcuts.count > 3 {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(white: 0.5))

                            TextField("Filter apps…", text: $appSearchQuery)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(.white)

                            if !appSearchQuery.isEmpty {
                                Button {
                                    appSearchQuery = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color(white: 0.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.2)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .frame(width: 150)
                    }

                    // Bottle Status with Pulsing Green Indicator
                    HStack(spacing: 6) {
                        Circle()
                            .fill(vmState.isActive ? Color.macportRunning : Color(white: 0.4))
                            .frame(width: 8, height: 8)
                            .shadow(color: vmState.isActive ? Color.macportRunning.opacity(0.8) : Color.clear, radius: 4)

                        Text(vmState.isActive ? "Running" : "Ready")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(vmState.isActive ? Color.macportRunning : Color.crossoverTextSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(vmState.isActive ? Color.macportRunning.opacity(0.12) : Color.white.opacity(0.05))
                    )
                }
            }

            Divider()
                .background(Color.crossoverBorder)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .background(Color.crossoverCanvas)
    }

    // MARK: - Main Canvas (Applications Grid)

    private var mainCanvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let message = statusMessage {
                    statusBanner(message)
                }

                if installedShortcuts.isEmpty {
                    emptyApplicationsCard
                } else if displayedShortcuts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(Color(white: 0.4))
                        Text("No applications found matching '\(appSearchQuery)'")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                        Button("Clear Filter") {
                            appSearchQuery = ""
                        }
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 50)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 110, maximum: 130), spacing: 28)],
                        alignment: .leading,
                        spacing: 28
                    ) {
                        ForEach(displayedShortcuts) { shortcut in
                            appGridItem(shortcut)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .background(Color.crossoverCanvas)
    }

    // MARK: - App Grid Item (CrossOver-style Icon)

    private func appGridItem(_ shortcut: WineProgramShortcut) -> some View {
        let isPrimary = (wineSettings.primaryExecutable == shortcut.executable)
        let isHovered = (hoveredShortcutId == shortcut.id)

        return VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // Application Icon Container (CrossOver squircle)
                if let iconURL = shortcut.iconURL, let img = NSImage(contentsOf: iconURL) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(isHovered ? 0.45 : 0.25), radius: isHovered ? 8 : 4, y: isHovered ? 4 : 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.crossoverCard, Color.crossoverSidebar],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 72, height: 72)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(isHovered ? 0.3 : 0.1), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(isHovered ? 0.35 : 0.2), radius: isHovered ? 8 : 4, y: 3)
                        .overlay(
                            Image(systemName: shortcut.iconSystemName)
                                .font(.system(size: 30))
                                .foregroundStyle(Color.crossoverBlue)
                        )
                }

                // Hover Play Button Overlay
                if isHovered {
                    Circle()
                        .fill(Color.crossoverBlue)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: 1)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                        .transition(.scale.combined(with: .opacity))
                }

                // Primary App Star Badge
                if isPrimary {
                    Circle()
                        .fill(Color.crossoverBlue)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Image(systemName: "star.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        )
                        .offset(x: 4, y: -4)
                        .shadow(color: Color.crossoverBlue.opacity(0.6), radius: 3)
                }
            }
            .frame(width: 76, height: 76)

            // App Title
            Text(shortcut.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovered ? Color.crossoverBlue : .white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 120)
        }
        .padding(8)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredShortcutId = hovering ? shortcut.id : nil
            }
        }
        .onTapGesture(count: 2) {
            launchProgram(shortcut)
        }
        .contextMenu {
            Button {
                launchProgram(shortcut)
            } label: {
                Label("Launch in Bottle", systemImage: "play.fill")
            }

            Button {
                setAsPrimaryExecutable(shortcut)
            } label: {
                Label("Set as Primary Executable", systemImage: "star")
            }

            Divider()

            Button {
                exportShortcut(shortcut, to: .applications)
            } label: {
                Label("Add to Applications", systemImage: "app.badge.checkmark")
            }

            Button {
                exportShortcut(shortcut, to: .desktop)
            } label: {
                Label("Add to Desktop", systemImage: "desktopcomputer")
            }

            Divider()

            Button {
                NSWorkspace.shared.selectFile(shortcut.executable, inFileViewerRootedAtPath: "")
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive) {
                uninstallShortcutTarget = shortcut
                isConfirmingShortcutUninstall = true
            } label: {
                Label("Uninstall Application…", systemImage: "trash")
            }
        }
    }

    // MARK: - Empty Applications State

    private var emptyApplicationsCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color(white: 0.35))

            VStack(spacing: 4) {
                Text("No Applications in this Bottle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Install software, games, or run commands into this Windows environment.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.5))
            }

            Button {
                chooseAndInstallApp()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("Install Application into Bottle…")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.crossoverBlue))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Right Inspector Sidebar (CrossOver Actions & Settings)

    private var inspectorSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Top: Run Command Button
                runCommandButton

                // Section 1: Bottle Actions
                bottleActionsSection

                // Section 2: Advanced Settings
                advancedSettingsSection

                // Section 3: Control Panels
                controlPanelsSection

                // Section 4: Bottle Details
                bottleDetailsSection
            }
            .padding(18)
        }
        .background(Color.crossoverInspector)
    }

    // MARK: - Inspector Components

    private var runCommandButton: some View {
        Button {
            isPresentingRunCommand = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
                Text("Run Command…")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.crossoverButton)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var bottleActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BOTTLE ACTIONS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(white: 0.5))
                .tracking(0.5)

            VStack(spacing: 6) {
                inspectorStandardButton(title: "Rename Bottle…", icon: "pencil") {
                    ui.renameTarget = config
                }

                inspectorStandardButton(title: "Uninstall an Application…", icon: "xmark.bin.fill") {
                    ui.bottleUninstallTarget = config
                }

                inspectorStandardButton(title: "Add to Applications", icon: "app.badge.checkmark") {
                    exportPrimaryApp(to: .applications)
                }

                inspectorStandardButton(title: "Add to Desktop", icon: "desktopcomputer") {
                    exportPrimaryApp(to: .desktop)
                }

                inspectorStandardButton(title: "Open C: Drive", icon: "folder.fill") {
                    openDriveC()
                }

                inspectorStandardButton(title: "Install Application into Bottle", icon: "plus.square.fill") {
                    chooseAndInstallApp()
                }

                inspectorDangerButton(title: "Quit All Applications", icon: "xmark.octagon.fill") {
                    forceQuitBottle()
                }

                inspectorDangerButton(title: "Delete Bottle", icon: "trash.fill") {
                    ui.deleteTarget = config
                }
            }
        }
    }

    private func inspectorStandardButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.crossoverCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.crossoverBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func inspectorDangerButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.crossoverDangerText)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.crossoverDangerText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.crossoverDangerBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.crossoverDangerText.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var advancedSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADVANCED SETTINGS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(white: 0.5))
                .tracking(0.5)

            VStack(spacing: 0) {
                // Graphics Backend
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Graphics Backend")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                        Text("D3DMetal (GPTK), DXMT, or DXVK")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.5))
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { wineSettings.backend },
                        set: { newBackend in updateSettings { $0.backend = newBackend } }
                    )) {
                        ForEach(GraphicsBackend.allCases) { b in
                            Text(b.displayName).tag(b)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider().background(Color.white.opacity(0.06))

                // DLSS / MetalFX
                Toggle(isOn: Binding(
                    get: { wineSettings.metalFXEnabled },
                    set: { val in updateSettings { $0.metalFXEnabled = val } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DLSS / MetalFX")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                        Text("Apple MetalFX AI Upscaling")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.5))
                    }
                }
                .toggleStyle(.switch)
                .tint(Color.crossoverBlue)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider().background(Color.white.opacity(0.06))

                // MSync
                Toggle(isOn: Binding(
                    get: { wineSettings.msyncEnabled },
                    set: { val in updateSettings { $0.msyncEnabled = val } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MSync")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                        Text("Mach-port fast synchronization")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.5))
                    }
                }
                .toggleStyle(.switch)
                .tint(Color.crossoverBlue)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider().background(Color.white.opacity(0.06))

                // High Resolution Mode
                Toggle(isOn: Binding(
                    get: { wineSettings.retinaMode },
                    set: { val in updateSettings { $0.retinaMode = val } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("High Resolution Mode")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                        Text("Retina display HiDPI scaling")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.5))
                    }
                }
                .toggleStyle(.switch)
                .tint(Color.crossoverBlue)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider().background(Color.white.opacity(0.06))

                // Metal Performance HUD
                Toggle(isOn: Binding(
                    get: { wineSettings.hudEnabled },
                    set: { val in updateSettings { $0.hudEnabled = val } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Metal Performance HUD")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                        Text("Real-time FPS & GPU telemetry")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.5))
                    }
                }
                .toggleStyle(.switch)
                .tint(Color.crossoverBlue)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.crossoverCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.crossoverBorder, lineWidth: 1)
            )
        }
    }

    private var controlPanelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONTROL PANELS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(white: 0.5))
                .tracking(0.5)

            VStack(spacing: 0) {
                controlPanelRow(title: "Add/Remove Programs", icon: "xmark.bin") {
                    ui.bottleUninstallTarget = config
                }
                Divider().background(Color.white.opacity(0.06))
                controlPanelRow(title: "Wine Configuration", icon: "gearshape.fill") {
                    executeCommandString("winecfg")
                }
                Divider().background(Color.white.opacity(0.06))
                controlPanelRow(title: "Game Controllers", icon: "gamecontroller.fill") {
                    executeCommandString("control joy.cpl")
                }
                Divider().background(Color.white.opacity(0.06))
                controlPanelRow(title: "Simulate Reboot", icon: "arrow.clockwise") {
                    rebootBottle()
                }
                Divider().background(Color.white.opacity(0.06))
                controlPanelRow(title: "Task Manager", icon: "list.bullet.rectangle") {
                    executeCommandString("taskmgr")
                }
                Divider().background(Color.white.opacity(0.06))
                controlPanelRow(title: "Command Prompt", icon: "terminal.fill") {
                    executeCommandString("cmd.exe")
                }
                Divider().background(Color.white.opacity(0.06))
                controlPanelRow(title: "Internet Settings", icon: "globe") {
                    executeCommandString("control inetcpl.cpl")
                }
                Divider().background(Color.white.opacity(0.06))
                controlPanelRow(title: "Registry Editor", icon: "slider.horizontal.3") {
                    executeCommandString("regedit")
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.crossoverCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.crossoverBorder, lineWidth: 1)
            )
        }
    }

    private func controlPanelRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.crossoverBlue)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var bottleDetailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BOTTLE DETAILS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(white: 0.5))
                .tracking(0.5)

            VStack(spacing: 8) {
                detailRow(label: "Disk Usage", value: MacportFormat.fileSize(bottleDiskSize))
                detailRow(label: "Architecture", value: "Windows 64-bit")
                detailRow(label: "Template", value: bottleTypeDisplayString)
                if let linked = wineSettings.linkedCrossOverBottle {
                    detailRow(label: "Linked Bottle", value: linked)
                }

                Divider().background(Color.white.opacity(0.06))

                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: bundleURL.path)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text("Show Bottle in Finder")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Color.crossoverBlue)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.crossoverCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.crossoverBorder, lineWidth: 1)
            )
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.6))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Run Command Sheet

    private var runCommandSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Run Command in Bottle")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button("Done") { isPresentingRunCommand = false }
            }
            .padding(16)
            Divider().background(Color.crossoverBorder)

            VStack(alignment: .leading, spacing: 16) {
                Text("Execute any Windows binary, installer, or command line within '\(config.name)'.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.crossoverTextSecondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Command / Executable")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                    HStack {
                        TextField("e.g. setup.exe, winecfg, cmd.exe, regedit", text: $customCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                        Button("Browse…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = []
                            panel.allowsOtherFileTypes = true
                            panel.message = "Choose a Windows executable (.exe, .msi, .bat)"
                            if panel.runModal() == .OK, let path = panel.url?.path {
                                customCommand = path
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Arguments (Optional)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                    TextField("e.g. /silent, /desktop, -dx11", text: $customArguments)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                // Quick Picks
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quick Picks")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.crossoverTextSecondary)

                    HStack(spacing: 8) {
                        ForEach(["winecfg", "regedit", "taskmgr", "cmd.exe", "explorer.exe"], id: \.self) { cmd in
                            Button(cmd) {
                                customCommand = cmd
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Spacer()

                HStack {
                    Button("Cancel") { isPresentingRunCommand = false }
                    Spacer()
                    Button("Run in Bottle") {
                        executeCustomCommand()
                        isPresentingRunCommand = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.crossoverBlue)
                    .disabled(customCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 360)
        .background(Color.crossoverInspector)
    }

    private func statusBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.crossoverBlue)
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(.white)
            Spacer()
            Button(action: { statusMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.crossoverCard))
    }

    // MARK: - Actions

    private func updateSettings(_ mutator: (inout WineBottleSettings) -> Void) {
        var updated = config
        var settings = updated.wineSettings ?? WineBottleSettings()
        mutator(&settings)
        updated.wineSettings = settings
        _ = try? store.save(updated)
    }

    private func setAsPrimaryExecutable(_ shortcut: WineProgramShortcut) {
        updateSettings { $0.primaryExecutable = shortcut.executable }
        statusMessage = "Set '\(shortcut.name)' as primary application."
    }

    private func refreshBottleData() {
        Task {
            let shortcuts = WineBottleManager.scanInstalledShortcuts(in: bundleURL)
            let size = WineBottleManager.calculateBottleSize(in: bundleURL)
            await MainActor.run {
                self.installedShortcuts = shortcuts
                self.bottleDiskSize = size
            }
        }
    }

    private func rebootBottle() {
        Task {
            do {
                if let wineEngine = state.instance(for: config.id)?.engine as? WineEngine {
                    try await wineEngine.launchExecutable("wineboot", arguments: ["-r"], in: bundleURL)
                } else {
                    let engine = WineEngine()
                    try await engine.launchExecutable("wineboot", arguments: ["-r"], in: bundleURL)
                }
                statusMessage = "Simulated Windows reboot."
            } catch {
                statusMessage = "Reboot failed: \(error.localizedDescription)"
            }
        }
    }

    private func forceQuitBottle() {
        do {
            try WineBottleManager.killBottleProcesses(in: bundleURL)
            statusMessage = "All bottle processes terminated."
        } catch {
            statusMessage = "Failed to terminate bottle: \(error.localizedDescription)"
        }
    }

    private func performUninstallShortcut(_ shortcut: WineProgramShortcut) {
        Task {
            do {
                let cmd = WineBottleManager.findUninstallCommand(for: shortcut, in: bundleURL)
                let engine = (state.instance(for: config.id)?.engine as? WineEngine) ?? WineEngine()
                try await engine.launchExecutable(cmd.executable, arguments: cmd.arguments, in: bundleURL, metal: true)

                // Clean up exported Mac launcher apps
                WineBottleManager.removeLauncherApps(appName: shortcut.name)

                statusMessage = "Launched uninstaller for '\(shortcut.name)'. Follow on-screen instructions to complete uninstallation."

                try? await Task.sleep(nanoseconds: 1_500_000_000)
                refreshBottleData()
            } catch {
                statusMessage = "Failed to launch uninstaller: \(error.localizedDescription)"
            }
        }
    }

    private func openDriveC() {
        let driveC = WineBottleManager.driveCURL(for: bundleURL)
        if !FileManager.default.fileExists(atPath: driveC.path) {
            try? FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(driveC)
    }

    private func launchProgram(_ shortcut: WineProgramShortcut) {
        Task {
            do {
                if let wineEngine = state.instance(for: config.id)?.engine as? WineEngine {
                    try await wineEngine.launchExecutable(shortcut.executable, arguments: shortcut.arguments, in: bundleURL, metal: true)
                } else {
                    let engine = WineEngine()
                    try await engine.launchExecutable(shortcut.executable, arguments: shortcut.arguments, in: bundleURL, metal: true)
                }
                statusMessage = "Launched \(shortcut.name) in bottle."
            } catch {
                statusMessage = "Failed to launch: \(error.localizedDescription)"
            }
        }
    }

    private func executeCommandString(_ cmdLine: String) {
        let parts = cmdLine.components(separatedBy: .whitespaces)
        guard let cmd = parts.first, !cmd.isEmpty else { return }
        let args = Array(parts.dropFirst())

        Task {
            do {
                if let wineEngine = state.instance(for: config.id)?.engine as? WineEngine {
                    try await wineEngine.launchExecutable(cmd, arguments: args, in: bundleURL, metal: true)
                } else {
                    let engine = WineEngine()
                    try await engine.launchExecutable(cmd, arguments: args, in: bundleURL, metal: true)
                }
                statusMessage = "Executed '\(cmdLine)' in bottle."
            } catch {
                statusMessage = "Execution failed: \(error.localizedDescription)"
            }
        }
    }

    private func executeCustomCommand() {
        let cmd = customCommand.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        let args = customArguments.isEmpty ? [] : customArguments.components(separatedBy: .whitespaces)

        Task {
            do {
                if let wineEngine = state.instance(for: config.id)?.engine as? WineEngine {
                    try await wineEngine.launchExecutable(cmd, arguments: args, in: bundleURL, metal: true)
                } else {
                    let engine = WineEngine()
                    try await engine.launchExecutable(cmd, arguments: args, in: bundleURL, metal: true)
                }
                statusMessage = "Executed '\(cmd)' in bottle."
            } catch {
                statusMessage = "Execution failed: \(error.localizedDescription)"
            }
        }
    }

    private func chooseAndInstallApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Choose an installer or executable to run inside this bottle"
        if panel.runModal() == .OK, let path = panel.url?.path {
            customCommand = path
            customArguments = ""
            executeCustomCommand()
        }
    }

    // MARK: - Native Mac App Publishing (.app)

    private func exportPrimaryApp(to destination: MacportAppPublisher.Destination) {
        let primary = wineSettings.primaryExecutable
        let match = installedShortcuts.first(where: { $0.executable == primary })
        let targetName = match?.name ?? config.name
        let exec = primary ?? installedShortcuts.first?.executable ?? "explorer.exe"
        let icon = match?.iconURL ?? installedShortcuts.first?.iconURL

        do {
            let appURL = try MacportAppPublisher.exportLauncherApp(
                bottleId: config.id,
                bottleName: config.name,
                appName: targetName,
                executable: exec,
                iconURL: icon,
                to: destination
            )
            statusMessage = "Added '\(targetName)' to \(destination.displayName). Launch directly from Spotlight or Launchpad!"
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } catch {
            statusMessage = "Failed to export application: \(error.localizedDescription)"
        }
    }

    private func exportShortcut(_ shortcut: WineProgramShortcut, to destination: MacportAppPublisher.Destination) {
        do {
            let appURL = try MacportAppPublisher.exportLauncherApp(
                bottleId: config.id,
                bottleName: config.name,
                appName: shortcut.name,
                executable: shortcut.executable,
                iconURL: shortcut.iconURL,
                to: destination
            )
            statusMessage = "Added '\(shortcut.name)' to \(destination.displayName). Launch directly from Spotlight or Launchpad!"
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } catch {
            statusMessage = "Failed to export shortcut: \(error.localizedDescription)"
        }
    }
}

