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

    var body: some View {
        VStack(spacing: 0) {
            ParallelsVMToolbar(config: config)
            Divider()
            content
        }
        .background(Color.macportWindow)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vmState.isActive, let machine = state.liveMachine(for: config.id) {
            VMDisplayView(machine: machine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vmState.isActive, let vncPath = state.vncSocketPath(for: config.id) {
            EmbeddedVNCDisplayView(socketPath: vncPath, showOverlayBar: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    if vmState.isActive, state.runsInExternalWindow(for: config.id) {
                        externalWindowCard
                    }
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
                    capacityCard
                    capabilityCard
                    storageCard
                    bootCard
                    if needsRuntimeInstall { runtimeCard }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// QEMU draws into its own Cocoa window. Saying so is the honest console
    /// state for this engine; embedding it would be a second, unimplemented
    /// display path.
    private var externalWindowCard: some View {
        InfoCard(
            title: "Running in its own window",
            subtitle: "\(engineType.displayName) draws this guest outside Macport."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("The guest console is the engine's own window, not a view inside Macport. "
                     + "Embedding needs a capture path this engine does not expose yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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
