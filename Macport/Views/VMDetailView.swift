import SwiftUI
import Virtualization
import MacportKit

/// Detail pane: configuration summary, an honest capability table, power
/// controls, and the live display when the machine is up.
struct VMDetailView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState

    let config: VMConfiguration

    private var isRunning: Bool { state.runningVMID == config.id }

    /// The engine that owns this VM. Resolved through the registry, so the pane
    /// describes the engine that will *actually* run the machine rather than a
    /// hardcoded default.
    private var engineType: any VMEngine.Type { state.hostingEngine(for: config) }
    private var capabilities: EngineCapabilities { state.capabilities(for: config) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle(config.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isRunning {
                    Button("Stop") {
                        Task { await state.stop(graceful: true) }
                    }
                    Button("Force Off") {
                        Task { await state.stop(graceful: false) }
                    }
                } else {
                    Button("Start") {
                        state.start(config, in: store)
                    }
                    .disabled(state.isBusy)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isRunning, let machine = state.liveMachine {
            VMDisplayView(machine: machine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isRunning, state.runsInExternalWindow {
            externalWindowPanel
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hardwareSection
                    engineSection
                    if needsRuntimeInstall { runtimeSection }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Shown while a QEMU-backed guest is up.
    ///
    /// QEMU draws the guest into its own window, and pretending otherwise with a
    /// blank pane would read as a failure. Saying so plainly is better, and it
    /// names the exact next step for this engine.
    private var externalWindowPanel: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("\(state.runningEngineName ?? engineType.displayName) is displaying this machine in its own window")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("QEMU draws the guest directly rather than through a view Macport can host, "
                 + "so the console opens separately. Embedding it over VNC or SPICE is the "
                 + "next step for this engine.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Text(config.guest.displayName)
                    Text("·")
                    Text(engineType.displayName)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(isRunning ? "Running" : "Stopped")
                .font(.callout.weight(.medium))
                .foregroundStyle(isRunning ? .green : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        isRunning ? Color.green.opacity(0.12) : Color.secondary.opacity(0.12)
                    )
                )
        }
        .padding(20)
    }

    // MARK: - Sections

    private var hardwareSection: some View {
        GroupBox("Hardware") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                row("Processors", "\(config.cpuCount)")
                row("Memory", config.memoryBytes.gbString)
                row("Disk", config.diskBytes.gbString)
                row("Networking", config.network.displayName)
                row("Shared folders", config.sharedFolders.isEmpty
                    ? "None"
                    : "\(config.sharedFolders.count)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    /// The capability table is shown to the user on purpose.
    ///
    /// Every outlet in this space either hides these limits or lets the user
    /// discover them by failure. Stating them is the product decision.
    private var engineSection: some View {
        GroupBox("Engine — \(engineType.displayName)") {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    capabilityRow(
                        "Boot installer media",
                        supported: capabilities.opticalMedia,
                        note: "A CD-ROM device, which Windows installers require"
                    )
                    capabilityRow(
                        "Virtual TPM",
                        supported: capabilities.tpm,
                        note: "Windows 11 setup requires a TPM 2.0 device"
                    )
                    capabilityRow("Snapshots", supported: capabilities.snapshots, note: nil)
                    capabilityRow("Shared folders", supported: capabilities.sharedFolders, note: nil)
                    capabilityRow("USB passthrough", supported: capabilities.usbPassthrough, note: nil)
                    capabilityRow(
                        "Nested virtualisation",
                        supported: capabilities.nestedVirtualization,
                        note: "Not exposed by Apple silicon to any guest"
                    )
                    capabilityRow(
                        "x86 guest emulation",
                        supported: capabilities.foreignArchitectureEmulation,
                        note: "This engine runs ARM64 guests only"
                    )
                }

                if let rationale = EngineRegistry.rationale(for: config) {
                    Divider()
                    Label(rationale, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !capabilities.tpm && config.guest.requiresTPM {
                    Divider()
                    Label(
                        "Windows 11 setup requires a TPM 2.0 device and no engine Macport "
                            + "ships provides one yet. Setup will need its check bypassed — "
                            + "Macport prints the exact steps when you press Start.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - Runtime install

    /// Only offered when the VM's engine is QEMU and QEMU is not present.
    private var needsRuntimeInstall: Bool {
        engineType.identifier == QEMUEngine.identifier && !state.isQEMURuntimeInstalled
    }

    private var runtimeSection: some View {
        GroupBox("QEMU runtime") {
            VStack(alignment: .leading, spacing: 10) {
                Label("Not installed", systemImage: "arrow.down.circle")
                    .font(.callout.weight(.medium))

                Text("This machine needs QEMU, which Macport installs and manages for you. "
                     + "It is a one-time download of a few hundred megabytes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let progress = state.runtimeInstallProgress {
                    Text(progress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }

                Button("Install QEMU") { state.installQEMURuntime() }
                    .disabled(state.isInstallingRuntime)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - Builders

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func capabilityRow(_ label: String, supported: Bool, note: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(supported ? Color.green : Color.orange)
                Text(supported ? "Supported" : "Not available")
                if let note {
                    Text("— \(note)")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }
            }
        }
    }
}
