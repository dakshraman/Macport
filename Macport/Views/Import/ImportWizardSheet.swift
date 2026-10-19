import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacportKit

/// Import a foreign disk image as a new machine.
///
/// The sequence matters: inspect, route, convert into the exact filename and
/// format the routed engine reads, prepare the bundle, then save. The machine is
/// never started, so an import cannot surprise the host with a boot.
@MainActor
struct ImportWizardSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: VMStore
    let state: AppState
    let onImported: (VMConfiguration) -> Void

    @State private var phase: Phase = .pick
    @State private var source: URL?
    @State private var inspected: DiskImporter.DiskInfo?
    @State private var name = ""
    @State private var guest: GuestKind = .linuxARM
    @State private var isInspecting = false
    @State private var failureTitle = "Import failed"
    @State private var failureFix = "Resolve the condition above, then try again."
    @State private var failure: String?
    @State private var notice: String?
    @State private var isConverting = false
    @State private var cancelRequested = false
    @State private var conversionTask: Task<Void, Never>?
    @State private var imported: VMConfiguration?

    private enum Phase {
        case pick
        case review
        case converting
    }

    /// Values crossing the detached boundary. `DiskInfo` is Sendable; errors
    /// are flattened to their user-facing sentence so no non-Sendable error has
    /// to leave the worker.
    private struct InspectOutcome: Sendable {
        let info: DiskImporter.DiskInfo?
        let error: String?
    }

    private struct ConvertOutcome: Sendable {
        let error: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepIndicator

                    if let notice {
                        Label(notice, systemImage: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let failure {
                        ProblemCard(
                            title: failureTitle,
                            message: failure,
                            fix: failureFix,
                            onDismiss: { self.failure = nil }
                        )
                    }

                    switch phase {
                    case .pick:
                        pickStep
                    case .review:
                        reviewStep
                    case .converting:
                        convertingStep
                    }
                }
                .padding(20)
            }

            Divider()

            footer
        }
        .frame(width: 680, height: 620)
        .interactiveDismissDisabled(isConverting)
        .onChange(of: imported) { _, configuration in
            guard let configuration else { return }
            onImported(configuration)
            dismiss()
        }
    }

    // MARK: - Header and steps

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import a Disk Image")
                    .font(.title3.weight(.semibold))
                Text("Macport converts a foreign disk once, then boots it as an ordinary machine.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let source {
                Text(source.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(20)
    }

    private var stepIndicator: some View {
        HStack(spacing: 16) {
            step("1", "Choose", active: phase == .pick)
            step("2", "Review", active: phase == .review)
            step("3", "Convert", active: phase == .converting)
            Spacer()
        }
    }

    private func step(_ number: String, _ title: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(active ? Color.macportAccent : Color.secondary)
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.macportAccent : Color.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(title)\(active ? ", current" : "")")
    }

    // MARK: - Pick

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.macportAccent)
                    .accessibilityHidden(true)
                Text("Choose a disk image")
                    .font(.system(size: 13, weight: .medium))
                Text("qcow2, img, raw, vmdk, vdi, vhdx or ova")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Button("Choose File…") { chooseFile() }
                    .disabled(isInspecting)
                if isInspecting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading the image with qemu-img…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.macportInset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        Color.macportBorderStrong,
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                accept(url)
                return true
            }

            Text("The source file is read, never modified. Importing needs qemu-img from "
                 + "Macport's managed QEMU runtime; the runtime screen can install it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let inspected {
                InfoCard(
                    title: "Disk image",
                    subtitle: source?.path ?? inspected.source.path
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        KeyValueRow(label: "Detected format", value: inspected.format, mono: true)
                        KeyValueRow(
                            label: "Virtual size",
                            value: MacportFormat.fileSize(inspected.virtualSize)
                        )
                        KeyValueRow(
                            label: "Actual size",
                            value: MacportFormat.fileSize(inspected.actualSize)
                        )
                    }
                }
            }

            InfoCard(title: "Machine") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Machine name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                    }

                    HStack {
                        Text("Guest")
                        Spacer()
                        Picker("Guest", selection: $guest) {
                            ForEach(GuestKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320)
                    }

                    Text("Macport does not guess the guest from the disk. Choose what the image actually contains.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if guest == .macOSGuest {
                        Label(
                            "macOS guests are restored from an IPSW image, not a disk image. Choose Linux or Windows.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(Color.macportPaused)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            InfoCard(title: "Engine", subtitle: engineName) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(engineNote)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(conversionNote)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Converting

    private var convertingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Converting \(source?.lastPathComponent ?? "the image")…")
                        .font(.system(size: 13, weight: .medium))
                    Text("qemu-img writes a staged copy and renames it when complete. This can take a few minutes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if cancelRequested {
                ProblemCard(
                    title: "This conversion cannot be interrupted safely yet",
                    message: "qemu-img is already writing the disk and Macport has no supported way to stop "
                        + "it mid-write. Macport will let it finish, remove its output, and import nothing.",
                    fix: "Wait for the conversion to finish. The source image was not modified."
                )
            } else {
                Text("The source image is not modified. Cancel is offered, but a running qemu-img "
                     + "conversion cannot be killed safely yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if phase == .converting, !cancelRequested {
                Button("Cancel Conversion") { requestCancel() }
            } else if phase == .review {
                Button("Back") {
                    phase = .pick
                    inspected = nil
                    failure = nil
                }
            } else if phase == .pick {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Spacer()

            switch phase {
            case .pick:
                EmptyView()
            case .review:
                Button("Import") { startImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            case .converting:
                if cancelRequested {
                    Text("Waiting for qemu-img…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    // MARK: - Derived

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var diskBytes: UInt64 {
        guard let inspected else { return AdmissionControl.gibibyte }
        return max(inspected.virtualSize ?? 0, AdmissionControl.gibibyte)
    }

    private var draftConfig: VMConfiguration {
        VMConfiguration(
            name: trimmedName.isEmpty ? "Imported Machine" : trimmedName,
            guest: guest,
            cpuCount: 4,
            memoryBytes: 4 * AdmissionControl.gibibyte,
            diskBytes: diskBytes,
            boot: .diskOnly
        )
    }

    private var routedEngine: any VMEngine.Type {
        EngineRegistry.engineType(for: draftConfig)
    }

    private var engineName: String { routedEngine.displayName }

    private var engineNote: String {
        if let rationale = EngineRegistry.rationale(for: draftConfig) {
            return rationale
        }
        return "\(guest.displayName) runs on \(engineName), the leanest engine available for this guest. "
            + "An explicit engine pin can be set later in Machine Settings."
    }

    private var conversionNote: String {
        if routedEngine.identifier == QEMUEngine.identifier {
            return "The disk will be converted to qcow2 at disk.qcow2, the filename QEMUEngine.create "
                + "expects. qcow2 is also the only format that can hold snapshots."
        }
        return "The disk will be converted to raw at disk.img, the filename Virtualization.framework "
            + "expects. Raw disks cannot hold snapshots."
    }

    private var canImport: Bool {
        !trimmedName.isEmpty
            && guest != .macOSGuest
            && inspected != nil
            && !isConverting
    }

    // MARK: - Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = DiskImporter.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a disk image to import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        accept(url)
    }

    private func accept(_ url: URL) {
        guard !isConverting else { return }
        failure = nil
        notice = nil

        guard DiskImporter.isSupported(url) else {
            failureTitle = "Unsupported disk image"
            failure = DiskImporterError.unsupportedFormat(
                url.pathExtension.isEmpty ? "that file" : url.pathExtension
            ).localizedDescription
            failureFix = "Choose a qcow2, img, raw, vmdk, vdi, vhdx or ova image."
            return
        }

        source = url
        if trimmedName.isEmpty {
            name = url.deletingPathExtension().lastPathComponent
        }
        isInspecting = true

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return InspectOutcome(info: try DiskImporter.inspect(url), error: nil)
                } catch {
                    return InspectOutcome(info: nil, error: error.localizedDescription)
                }
            }.value

            isInspecting = false
            if let info = outcome.info {
                inspected = info
                phase = .review
            } else {
                failureTitle = "Could not read that disk image"
                failure = outcome.error
                failureFix = "If the managed QEMU runtime is not installed, install it and try again. "
                    + "Otherwise check that the file is a complete disk image."
            }
        }
    }

    private func startImport() {
        guard let source, inspected != nil else { return }

        let configuration = draftConfig
        let engineType = routedEngine
        let isQEMU = engineType.identifier == QEMUEngine.identifier
        let destinationName = isQEMU ? "disk.qcow2" : "disk.img"
        let targetFormat: DiskImporter.TargetFormat = isQEMU ? .qcow2 : .raw
        let bundle = store.bundleURL(for: configuration)
        let destination = bundle.appendingPathComponent(destinationName)

        failure = nil
        notice = nil
        isConverting = true
        cancelRequested = false
        phase = .converting

        let sourceURL = source
        conversionTask = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                    _ = try DiskImporter.convert(sourceURL, to: destination, format: targetFormat)
                    return ConvertOutcome(error: nil)
                } catch {
                    return ConvertOutcome(error: error.localizedDescription)
                }
            }.value

            if cancelRequested || Task.isCancelled {
                await discard(bundle)
                isConverting = false
                phase = .pick
                notice = "The conversion could not be interrupted safely yet. Macport let it finish, "
                    + "removed its output, and imported nothing. The source image was not modified."
                return
            }

            if let error = outcome.error {
                await discard(bundle)
                isConverting = false
                failureTitle = "Import failed"
                failure = error
                failureFix = "The source image was not modified. Check free disk space and the "
                    + "image's integrity, then try again."
                phase = .review
                return
            }

            // The disk is in place. Prepare firmware/variables through the same
            // engine entry point a normal start uses, then publish the machine.
            do {
                let engine = EngineRegistry.makeEngine(for: configuration)
                try await engine.create(configuration, in: bundle)
                _ = try store.save(configuration)
                isConverting = false
                imported = configuration
            } catch {
                await discard(bundle)
                isConverting = false
                failureTitle = "The machine could not be prepared"
                failure = error.localizedDescription
                failureFix = "The imported disk was removed and no machine was saved. "
                    + "Resolve the condition above, then import again."
                phase = .review
            }
        }
    }

    private func requestCancel() {
        cancelRequested = true
        conversionTask?.cancel()
    }

    private func discard(_ bundle: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: bundle)
        }.value
    }
}
