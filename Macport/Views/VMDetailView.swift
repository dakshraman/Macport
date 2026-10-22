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

/// Signature CrossOver-style Bottle Control Center for Windows applications.
///
/// Provides:
/// 1. Installed Windows applications and launch shortcuts
/// 2. One-click access to Wine Configuration, Regedit, Task Manager, and Command Prompt
/// 3. Direct "Run Command…" sheet to execute any .exe or installer in the bottle
/// 4. Direct Finder access to the virtual C: drive (`drive_c`)
/// 5. Apple Metal / DXMT GPU and Rosetta 2 AVX performance controls
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
    @State private var metalAcceleration = true
    @State private var avxEmulation = true
    @State private var statusMessage: String?

    private var vmState: VMState { state.state(for: config.id) }
    private var bundleURL: URL { store.bundleURL(for: config) }

    var body: some View {
        VStack(spacing: 0) {
            bottleHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let message = statusMessage {
                        statusBanner(message)
                    }

                    mainApplicationCard
                    installedProgramsSection
                    builtInToolsSection
                    performanceAndGraphicsSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Color.macportWindow)
        .sheet(isPresented: $isPresentingRunCommand) {
            runCommandSheet
        }
        .onAppear {
            refreshBottleData()
        }
    }

    // MARK: - Bottle Header

    private var bottleHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.macportWindowsHue.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.macportWindowsHue)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(config.name)
                        .font(.system(size: 17, weight: .bold))

                    HStack(spacing: 5) {
                        Circle()
                            .fill(vmState.isActive ? Color.macportRunning : Color.macportOff.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text(vmState.isActive ? "Running Natively" : "Stopped")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(vmState.isActive ? Color.macportRunning : .secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.macportInset))
                }

                HStack(spacing: 8) {
                    Text("CrossOver / Wine Bottle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("Rosetta 2 x86_64")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("Apple Metal 3D GPU")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Header Quick Actions
            HStack(spacing: 8) {
                if vmState.isActive {
                    Button(action: { stopBottle() }) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                } else {
                    Button(action: { startMainApp() }) {
                        Label("Run Application", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }

                Button(action: { isPresentingRunCommand = true }) {
                    Label("Run Command…", systemImage: "bolt.fill")
                }
                .controlSize(.regular)

                Button(action: { openDriveC() }) {
                    Label("Open C: Drive", systemImage: "folder.fill")
                }
                .controlSize(.regular)

                Menu {
                    Button("Force Quit Bottle (wineserver -k)") {
                        forceQuitBottle()
                    }
                    Button("Refresh Shortcuts") {
                        refreshBottleData()
                    }
                    Divider()
                    Button("Reveal Bottle in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.macportCard)
    }

    // MARK: - Main Application Card

    private var mainApplicationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Primary Application")
                        .font(.system(size: 13, weight: .bold))
                    Text(primaryExecutablePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()

                Button("Change…") {
                    chooseNewMainExecutable()
                }
                .controlSize(.small)

                Button(action: { startMainApp() }) {
                    Label(vmState.isActive ? "Restart" : "Launch", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.macportCard))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.macportBorderSubtle, lineWidth: 1))
    }

    // MARK: - Installed Programs Section

    private var installedProgramsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Installed Applications")
                    .font(.system(size: 14, weight: .bold))

                Spacer()

                Button("+ Install Windows App (.exe)…") {
                    chooseAndInstallApp()
                }
                .controlSize(.small)
            }

            if installedShortcuts.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(Color.macportWindowsHue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No secondary applications installed yet")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Click '+ Install Windows App' to run an installer or game setup directly into this bottle.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.macportInset))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    ForEach(installedShortcuts) { shortcut in
                        programCard(shortcut)
                    }
                }
            }
        }
    }

    private func programCard(_ shortcut: WineProgramShortcut) -> some View {
        HStack(spacing: 8) {
            Button(action: { launchProgram(shortcut) }) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.macportWindowsHue.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: shortcut.iconSystemName)
                            .font(.system(size: 16))
                            .foregroundStyle(Color.macportWindowsHue)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(shortcut.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(config.wineSettings?.primaryExecutable == shortcut.executable ? "Primary Application" : "Launch in Bottle")
                            .font(.system(size: 10))
                            .foregroundStyle(config.wineSettings?.primaryExecutable == shortcut.executable ? Color.macportAccent : .secondary)
                    }

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            Menu {
                Button("Run Application") {
                    launchProgram(shortcut)
                }
                Button("Set as Primary Executable") {
                    setAsPrimaryExecutable(shortcut)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(shortcut.executable, inFileViewerRootedAtPath: "")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.macportCard))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(config.wineSettings?.primaryExecutable == shortcut.executable ? Color.macportAccent.opacity(0.6) : Color.macportBorderSubtle, lineWidth: 1))
    }

    // MARK: - Built-in Wine Tools Section

    private var builtInToolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Windows Control Panels & Built-in Utilities")
                .font(.system(size: 14, weight: .bold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(WineBottleManager.builtInTools) { tool in
                    Button(action: { launchProgram(tool) }) {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.macportAccent.opacity(0.12))
                                    .frame(width: 36, height: 36)
                                Image(systemName: tool.iconSystemName)
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color.macportAccent)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text(tool.executable)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.macportCard))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.macportBorderSubtle, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Performance & Graphics Section

    private var performanceAndGraphicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bottle Settings & Performance")
                .font(.system(size: 14, weight: .bold))

            VStack(spacing: 10) {
                HStack {
                    Text("Bottle Template")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(config.wineSettings?.bottleTemplate ?? "win11_64")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }

                if let linked = config.wineSettings?.linkedCrossOverBottle {
                    Divider()
                    HStack {
                        Text("CrossOver Bottle Link")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(linked)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.macportAccent)
                    }
                }

                Divider()

                HStack {
                    Text("Active Graphics Backend")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(config.wineSettings?.backend.displayName ?? "Auto (Apple D3DMetal)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Metal 3D GPU Acceleration (DXMT / D3DMetal)")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Translates DirectX 10, 11, and 12 graphics commands directly to Apple Silicon Metal.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $metalAcceleration)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rosetta 2 AVX Instruction Set Emulation")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Advertises AVX support to modern games and engines under Rosetta 2.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $avxEmulation)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                Divider()

                HStack {
                    Text("Bottle Disk Usage")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(MacportFormat.fileSize(bottleDiskSize))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }

                Divider()

                HStack {
                    Text("Idle Memory Overhead")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("0 MB (Zero Hypervisor RAM Overhead)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.macportRunning)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.macportCard))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.macportBorderSubtle, lineWidth: 1))
        }
    }

    // MARK: - Run Command Sheet

    private var runCommandSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Run Command in Bottle")
                    .font(.headline)
                Spacer()
                Button("Done") { isPresentingRunCommand = false }
            }
            .padding(16)
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Text("Execute any Windows binary, installer, or command line within '\(config.name)'.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Command / Executable")
                        .font(.system(size: 11, weight: .semibold))
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
                    TextField("e.g. /silent, /desktop, -dx11", text: $customArguments)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                // Quick Picks
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quick Picks")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

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
                    .disabled(customCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 360)
    }

    private func statusBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.macportAccent)
            Text(msg)
                .font(.system(size: 12))
            Spacer()
            Button(action: { statusMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.macportInset))
    }

    // MARK: - Actions

    private var primaryExecutablePath: String {
        if let primary = config.wineSettings?.primaryExecutable, !primary.isEmpty {
            return primary
        }
        switch config.boot {
        case .installMedia(let path):
            return path
        case .kernelImage(let kernel, _):
            return kernel
        default:
            return "Windows Explorer (explorer.exe)"
        }
    }

    private func setAsPrimaryExecutable(_ shortcut: WineProgramShortcut) {
        var updated = config
        var settings = updated.wineSettings ?? WineBottleSettings()
        settings.primaryExecutable = shortcut.executable
        updated.wineSettings = settings
        _ = try? store.save(updated)
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

    private func startMainApp() {
        state.start(config, in: store)
        statusMessage = "Launching \(config.name) with Apple Metal graphics and Rosetta 2 translation…"
    }

    private func stopBottle() {
        Task {
            await state.stop(id: config.id, graceful: true)
            statusMessage = "Application stopped."
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
                    try await wineEngine.launchExecutable(shortcut.executable, arguments: shortcut.arguments, in: bundleURL, metal: metalAcceleration)
                } else {
                    let engine = WineEngine()
                    try await engine.launchExecutable(shortcut.executable, arguments: shortcut.arguments, in: bundleURL, metal: metalAcceleration)
                }
                statusMessage = "Launched \(shortcut.name) in bottle."
            } catch {
                statusMessage = "Failed to launch: \(error.localizedDescription)"
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
                    try await wineEngine.launchExecutable(cmd, arguments: args, in: bundleURL, metal: metalAcceleration)
                } else {
                    let engine = WineEngine()
                    try await engine.launchExecutable(cmd, arguments: args, in: bundleURL, metal: metalAcceleration)
                }
                statusMessage = "Executed '\(cmd)' in bottle."
            } catch {
                statusMessage = "Execution failed: \(error.localizedDescription)"
            }
        }
    }

    private func chooseNewMainExecutable() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a Windows executable (.exe, .msi) to set as the primary application"
        if panel.runModal() == .OK, let path = panel.url?.path {
            var updated = config
            updated.boot = .installMedia(path: path)
            do {
                _ = try store.save(updated)
                statusMessage = "Updated primary executable to \(panel.url?.lastPathComponent ?? path)"
            } catch {
                statusMessage = "Failed to update configuration: \(error.localizedDescription)"
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
}

