import AppKit
import SwiftUI
import MacportKit

/// Per-machine settings. Every section states whether its values reach the
/// running engine or wait for the next boot; nothing pretends a change applied
/// when the engine already consumed the old value.
@MainActor
struct MachineSettingsSheet: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let config: VMConfiguration

    @State private var draft: VMConfiguration
    @State private var engineChoice: String
    @State private var problem: SettingsProblem?

    init(config: VMConfiguration) {
        self.config = config
        _draft = State(initialValue: config)
        _engineChoice = State(initialValue: config.engineIdentifier ?? VMConfiguration.automaticEngine)
    }

    private struct SettingsProblem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let fix: String
    }

    // MARK: - Derived

    private var host: HostCapacity { state.registry.capacity }
    private var maxCores: Int { max(1, host.processorCount) }
    private var maxMemoryBytes: UInt64 {
        let usable = host.physicalMemory > AdmissionControl.minimumReserve
            ? host.physicalMemory - AdmissionControl.minimumReserve
            : AdmissionControl.gibibyte
        return max(AdmissionControl.gibibyte, usable)
    }
    private var maxMemoryGB: Double {
        Double(maxMemoryBytes) / Double(AdmissionControl.gibibyte)
    }
    private var capabilities: EngineCapabilities { state.capabilities(for: draft) }
    private var engineName: String { state.hostingEngine(for: draft).displayName }
    private var isActive: Bool { state.state(for: config.id).isActive }

    private var hardwareDirty: Bool {
        draft.cpuCount != config.cpuCount || draft.memoryBytes != config.memoryBytes
    }
    private var networkDirty: Bool { draft.network != config.network }
    private var foldersDirty: Bool { draft.sharedFolders != config.sharedFolders }
    private var bootDirty: Bool { draft.boot != config.boot }
    private var engineDirty: Bool { draft.engineIdentifier != config.engineIdentifier }

    /// Admission's own answer for the draft, minus this machine's existing
    /// allocation if it is already running.
    private var admissionWarning: String? {
        let running = state.runningConfigurations(excluding: config.id)
        switch HostCapacity.check(draft, running: running, capacity: host) {
        case .success:
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }

    private var validationProblem: SettingsProblem? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SettingsProblem(
                title: "The machine needs a name",
                message: "A name is used in the library, the window title and QEMU's own window.",
                fix: "Enter a name that is not blank, then save again."
            )
        }
        if draft.cpuCount < 1 || draft.cpuCount > maxCores {
            return SettingsProblem(
                title: "Processor count is outside what this Mac can give",
                message: "This Mac has \(host.processorCount) cores; a machine may request 1 to \(maxCores).",
                fix: "Lower the processor count to \(maxCores) or fewer."
            )
        }
        if draft.memoryBytes > maxMemoryBytes {
            return SettingsProblem(
                title: "Memory exceeds the host limit",
                message: "This Mac has \(host.physicalMemory.gbString); Macport keeps "
                    + "\(AdmissionControl.minimumReserve.gbString) for macOS, so a machine may request "
                    + "at most \(maxMemoryBytes.gbString).",
                fix: "Lower the memory allocation to \(maxMemoryBytes.gbString) or less."
            )
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Machine Settings")
                        .font(.title3.weight(.semibold))
                    Text(config.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                EngineChip(config: draft)
            }
            .padding(20)

            Divider()

            Form {
                if isActive {
                    Section {
                        Label(
                            "This machine is running. Hardware, network, shared folder and boot changes apply the next time it starts.",
                            systemImage: "info.circle"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    TextField("Name", text: $draft.name)
                    Text("The name is shown in the library, the window title and the engine's own window.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } header: {
                    Text("General")
                }

                Section {
                    SettingsRow("Processors") {
                        Stepper(
                            value: $draft.cpuCount,
                            in: 1...maxCores
                        ) {
                            Text("\(draft.cpuCount) of \(host.processorCount) cores")
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Memory")
                            Spacer()
                            Text(draft.memoryBytes.gbString)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        Slider(
                            value: Binding(
                                get: { Double(draft.memoryBytes) / Double(AdmissionControl.gibibyte) },
                                set: { draft.memoryBytes = UInt64(($0 * Double(AdmissionControl.gibibyte)).rounded()) }
                            ),
                            in: 1...maxMemoryGB,
                            step: 1
                        )
                        HStack {
                            Text("1 GB")
                            Spacer()
                            Text("Maximum \(Int(maxMemoryGB)) GB — host memory minus \(AdmissionControl.minimumReserve.gbString)")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    }

                    if let admissionWarning {
                        Label(admissionWarning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.macportPaused)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    sectionHeader("Hardware", restart: hardwareDirty)
                }

                Section {
                    SettingsRow("Disk size") {
                        Text(draft.diskBytes.gbString)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    Text("Growing a disk in place is not supported yet. The ceiling is fixed when the machine is created; the file itself is sparse.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reveal Bundle") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.bundleURL(for: draft)])
                    }
                    .controlSize(.small)
                } header: {
                    Text("Storage")
                }

                Section {
                    Picker("Mode", selection: $draft.network) {
                        ForEach(NetworkMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    HStack {
                        Text("Bridged")
                        Spacer()
                        Text("Unavailable")
                            .foregroundStyle(.tertiary)
                    }
                    Text("Bridged networking needs com.apple.vm.networking, an entitlement Apple has not granted Macport. "
                         + "This is a missing entitlement, not a bug.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    sectionHeader("Network", restart: networkDirty)
                }

                Section {
                    if capabilities.sharedFolders {
                        if draft.sharedFolders.isEmpty {
                            Text("No folders shared with this guest.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach($draft.sharedFolders) { $folder in
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                    Text(folder.hostPath)
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Toggle("Read-only", isOn: $folder.readOnly)
                                        .toggleStyle(.checkbox)
                                        .font(.system(size: 11))
                                    Button {
                                        draft.sharedFolders.removeAll { $0.id == folder.id }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove shared folder \(folder.hostPath)")
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Quick Presets")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Button("+ Desktop") { addPresetFolder(.desktopDirectory) }
                                    .controlSize(.small)
                                    .disabled(isSharedPreset(.desktopDirectory))

                                Button("+ Documents") { addPresetFolder(.documentDirectory) }
                                    .controlSize(.small)
                                    .disabled(isSharedPreset(.documentDirectory))

                                Button("+ Downloads") { addPresetFolder(.downloadsDirectory) }
                                    .controlSize(.small)
                                    .disabled(isSharedPreset(.downloadsDirectory))

                                Button("+ Choose Other…") { addFolder() }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.top, 4)
                    } else {
                        HStack {
                            Text("Shared folders")
                            Spacer()
                            Text("Not available")
                                .foregroundStyle(.tertiary)
                        }
                        Text("\(engineName) cannot expose host folders to the guest yet. This is a missing engine path, not a setting you can change.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !draft.sharedFolders.isEmpty {
                            Text("\(draft.sharedFolders.count) folder(s) are configured but will be ignored by this engine.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.macportPaused)
                        }
                    }
                } header: {
                    sectionHeader("Shared Folders", restart: foldersDirty)
                }

                Section {
                    switch draft.boot {
                    case .installMedia(let path):
                        HStack(spacing: 8) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                            Button("Clear") { draft.boot = .diskOnly }
                                .controlSize(.small)
                        }
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    case .kernelImage:
                        Text("This machine boots a kernel directly.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Choosing an ISO replaces the kernel boot with installer media.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    case .diskOnly:
                        Text("None — the machine boots from its own disk.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Button("Choose ISO…") { chooseISO() }
                        .controlSize(.small)

                    Text("Install media is attached read-only at boot. QEMU exposes it as a USB CD-ROM; "
                         + "Virtualization.framework presents it as a disk.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    sectionHeader("Boot", restart: bootDirty)
                }

                Section {
                    Picker("Engine", selection: $engineChoice) {
                        Text("Automatic").tag(VMConfiguration.automaticEngine)
                        ForEach(EngineRegistry.descriptors) { engine in
                            Text(engine.displayName).tag(engine.id)
                        }
                    }
                    .onChange(of: engineChoice) { _, newValue in
                        draft.engineIdentifier = newValue == VMConfiguration.automaticEngine
                            ? nil
                            : newValue
                    }

                    Text(engineReason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if engineDirty {
                        Text("Changing the engine keeps the existing bundle. Macport does not convert "
                             + "the disk when engines change; each engine expects its own disk image.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.macportPaused)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    sectionHeader("Advanced", restart: engineDirty)
                }
            }
            .formStyle(.grouped)

            if let problem {
                ProblemCard(
                    title: problem.title,
                    message: problem.message,
                    fix: problem.fix,
                    onDismiss: { self.problem = nil }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 720, height: 780)
        .tint(.macportAccent)
    }

    private var engineReason: String {
        if let rationale = EngineRegistry.rationale(for: draft) {
            return rationale
        }
        if draft.engineIdentifier != nil {
            return "Pinned. Automatic routing is off, so \(draft.guest.displayName) may not run "
                + "correctly on an engine that cannot supply what it needs."
        }
        return "Automatic chooses the engine that can host this guest, then the leanest one available."
    }

    private func sectionHeader(_ title: String, restart: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
            if restart { RestartBadge() }
        }
    }

    // MARK: - Actions

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose a host folder to expose to the guest read-only"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if !draft.sharedFolders.contains(where: { $0.hostPath == url.path }) {
                draft.sharedFolders.append(SharedFolder(hostPath: url.path, readOnly: false))
            }
        }
    }

    private func isSharedPreset(_ searchDir: FileManager.SearchPathDirectory) -> Bool {
        guard let url = FileManager.default.urls(for: searchDir, in: .userDomainMask).first else { return false }
        return draft.sharedFolders.contains(where: { $0.hostPath == url.path })
    }

    private func addPresetFolder(_ searchDir: FileManager.SearchPathDirectory) {
        guard let url = FileManager.default.urls(for: searchDir, in: .userDomainMask).first else { return }
        if !draft.sharedFolders.contains(where: { $0.hostPath == url.path }) {
            draft.sharedFolders.append(SharedFolder(hostPath: url.path, readOnly: false))
        }
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.message = "Choose installer media (ISO)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.boot = .installMedia(path: url.path)
    }

    private func save() {
        if let validationProblem {
            problem = validationProblem
            return
        }
        do {
            _ = try store.save(draft)
            dismiss()
        } catch {
            problem = SettingsProblem(
                title: "Could not save settings",
                message: error.localizedDescription,
                fix: "Check that the VM folder is writable, then save again."
            )
        }
    }
}

/// `LabeledContent` without depending on a particular macOS 14 spelling.
@MainActor
private struct SettingsRow<Content: View>: View {
    let label: String
    private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            content
        }
    }
}
