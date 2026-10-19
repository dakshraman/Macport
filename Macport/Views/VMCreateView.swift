import SwiftUI
import MacportKit

/// Creation sheet.
///
/// The capability warning block is the important part. It renders the engine's
/// declared limits for the selected guest *before* the user commits to an
/// install, so nobody downloads a 6 GB ISO and then learns about the TPM
/// requirement.
struct VMCreateView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let onCreate: (VMConfiguration) -> Void

    @State private var name = "New VM"
    @State private var guest: GuestKind = .linuxARM
    @State private var cpuCount = 4
    @State private var memoryGB = 4
    @State private var diskGB = 64
    @State private var network: NetworkMode = .sharedNAT
    @State private var installMediaPath: String?

    /// An explicit engine pin, or `automaticEngine` to let the guest decide.
    @State private var engineChoice = VMConfiguration.automaticEngine

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }

                Section("Operating system") {
                    Picker("Guest", selection: $guest) {
                        ForEach(GuestKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }

                Section("Engine") {
                    Picker("Engine", selection: $engineChoice) {
                        Text("Automatic").tag(VMConfiguration.automaticEngine)
                        ForEach(EngineRegistry.descriptors) { engine in
                            Text(engine.displayName).tag(engine.id)
                        }
                    }
                    Text(engineExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Hardware") {
                    LabeledContent("Processors") {
                        Stepper("\(cpuCount)", value: $cpuCount, in: 1...maxCPUs)
                    }
                    LabeledContent("Memory") {
                        Stepper("\(memoryGB) GB", value: $memoryGB, in: 1...maxMemoryGB)
                    }
                    LabeledContent("Disk") {
                        Stepper("\(diskGB) GB", value: $diskGB, in: 8...1024)
                    }
                }

                Section("Networking") {
                    Picker("Mode", selection: $network) {
                        ForEach(NetworkMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                Section("Install media") {
                    HStack {
                        Text(installMediaPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                             ?? "None — boot an existing disk")
                            .foregroundStyle(installMediaPath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseMedia() }
                        if installMediaPath != nil {
                            Button("Clear") { installMediaPath = nil }
                        }
                    }
                }

                if !capabilityWarnings.isEmpty {
                    Section("What to expect") {
                        ForEach(capabilityWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(makeConfiguration())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 620)
    }

    // MARK: - Derived

    /// What the engine that will host this guest can do.
    ///
    /// Resolved from a full configuration rather than the guest alone, because the
    /// engine depends on the guest *and* any explicit pin — the registry is the only
    /// thing that knows both.
    private var capabilities: EngineCapabilities {
        state.capabilities(for: makeConfiguration())
    }

    /// Spells out which engine a given choice resolves to. The routing rule is
    /// worth stating: a Windows guest is sent to QEMU because no other engine can
    /// boot its installer, and a user should not have to read the source to learn
    /// that.
    private var engineExplanation: String {
        if engineChoice == VMConfiguration.automaticEngine {
            let chosen = EngineRegistry.preferredType(for: guest)
            return "Automatic — \(chosen.displayName) will run this machine."
        }
        return "Pinned. \(guest.displayName) may not run correctly on an engine that "
            + "cannot supply what it needs."
    }

    private var capabilityWarnings: [String] {
        let config = makeConfiguration()
        return state.warnings(for: config)
    }

    private var maxCPUs: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    private var maxMemoryGB: Int {
        let physical = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        return max(1, min(physical, 64))
    }

    private func makeConfiguration() -> VMConfiguration {
        let boot: BootSource = installMediaPath.map { .installMedia(path: $0) } ?? .diskOnly
        return VMConfiguration(
            name: name,
            guest: guest,
            cpuCount: cpuCount,
            memoryBytes: UInt64(memoryGB) * 1024 * 1024 * 1024,
            diskBytes: UInt64(diskGB) * 1024 * 1024 * 1024,
            network: network,
            boot: boot,
            // The default engine cannot provide a vTPM, so never claim one.
            tpmEnabled: false,
            engineIdentifier: engineChoice == VMConfiguration.automaticEngine
                ? nil
                : engineChoice
        )
    }

    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an ISO or disk image to boot"
        if panel.runModal() == .OK {
            installMediaPath = panel.url?.path
        }
    }
}
