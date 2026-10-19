import SwiftUI
import MacportKit

/// Snapshots for one machine, read from the engine every time. There is no
/// local snapshot cache: the engine tag is the only identity a restore can use,
/// so a stale list would offer rollbacks that do not exist.
@MainActor
struct SnapshotsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let config: VMConfiguration

    @State private var snapshots: [VMSnapshot] = []
    @State private var isLoading = false
    @State private var busyAction: String?
    @State private var failure: String?
    @State private var newName = ""
    @State private var restoreTarget: VMSnapshot?
    @State private var deleteTarget: VMSnapshot?

    private var capabilities: EngineCapabilities { state.capabilities(for: config) }
    private var engineName: String { state.hostingEngine(for: config).displayName }
    private var instance: VMInstance? { state.registry.instance(config.id) }
    private var machineState: VMState { state.state(for: config.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snapshots")
                        .font(.title3.weight(.semibold))
                    Text(config.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                EngineChip(config: config)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !capabilities.snapshots {
                        unsupportedCard
                    }

                    if let failure {
                        ProblemCard(
                            title: "Snapshot action failed",
                            message: failure,
                            fix: "Fix the condition described above, then reload the list or retry.",
                            onDismiss: { self.failure = nil }
                        )
                    }

                    if capabilities.snapshots {
                        createCard
                        if instance == nil {
                            stoppedCard
                        } else {
                            listContent
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                if let busyAction {
                    ProgressView()
                        .controlSize(.small)
                    Text(busyAction)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 640)
        .task { await load() }
        .confirmationDialog(
            restoreTarget.map { "Restore “\($0.name)”?" } ?? "Restore snapshot?",
            isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            ),
            presenting: restoreTarget
        ) { snapshot in
            Button("Restore", role: .destructive) { restore(snapshot) }
            Button("Cancel", role: .cancel) { restoreTarget = nil }
        } message: { snapshot in
            Text("Everything written to \(config.name) since "
                 + "\(MacportFormat.snapshotDate(snapshot.createdAt)) will be lost. "
                 + "The machine returns to that snapshot's disk"
                 + (snapshot.includesMemory ? " and memory state." : " state."))
        }
        .confirmationDialog(
            deleteTarget.map { "Delete snapshot “\($0.name)”?" } ?? "Delete snapshot?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { snapshot in
            Button("Delete Snapshot", role: .destructive) { delete(snapshot) }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { snapshot in
            Text("This permanently removes the rollback point “\(snapshot.name)”. "
                 + "The machine's current state is unchanged.")
        }
    }

    // MARK: - Cards

    private var unsupportedCard: some View {
        InfoCard(
            title: "Snapshots are not available on \(engineName)",
            subtitle: "This is an engine limit, not a missing setting."
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshotReason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(snapshotNextStep)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var createCard: some View {
        InfoCard(title: "Create a snapshot") {
            VStack(alignment: .leading, spacing: 8) {
                Text("QEMU snapshots save guest RAM and the disk state together. Restoring rolls the "
                     + "machine back to both.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField("Snapshot name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Button("Create Snapshot") { create() }
                        .disabled(
                            newName.trimmingCharacters(in: .whitespaces).isEmpty
                                || instance == nil
                                || busyAction != nil
                        )
                }

                if instance == nil {
                    Text("The machine must be running: the engine holds the snapshot list and the open disk.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var stoppedCard: some View {
        InfoCard(title: "Start the machine to see its snapshots") {
            Text("Snapshots live inside the machine's qcow2 disk, and only the running engine can "
                 + "list, create or restore them. Start \(config.name), then reopen this window.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading snapshots from \(engineName)…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if snapshots.isEmpty {
            InfoCard(title: "No snapshots yet") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A snapshot is a point you can return to: the disk image, and the guest's "
                         + "RAM when the engine can save it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Raw disk images cannot hold snapshots. Convert this machine's disk with "
                         + "`macportctl disk convert` first, which rewrites it as qcow2 without "
                         + "losing its contents.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            if let blocked = restoreBlockedReason {
                Label(blocked, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(snapshots) { snapshot in
                    snapshotRow(snapshot)
                    if snapshot.id != snapshots.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.macportCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.macportBorderSubtle, lineWidth: 1)
            )
        }
    }

    private func snapshotRow(_ snapshot: VMSnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(MacportFormat.snapshotDate(snapshot.createdAt))
                    Text("·")
                    Text(snapshot.includesMemory ? "RAM + disk" : "Disk only")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer()

            if snapshot.includesMemory {
                Text("Includes memory")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.macportAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.macportAccentSubtle))
            }

            Button("Restore…") { restoreTarget = snapshot }
                .controlSize(.small)
                .disabled(restoreBlockedReason != nil || busyAction != nil)
                .help(restoreBlockedReason ?? "Roll the machine back to this snapshot.")
            Button("Delete…") { deleteTarget = snapshot }
                .controlSize(.small)
                .disabled(busyAction != nil)
                .help("Remove this snapshot permanently.")
        }
        .padding(.vertical, 10)
    }

    // MARK: - Reasons

    private var snapshotReason: String {
        if capabilities.snapshots { return "" }
        if state.hostingEngine(for: config).identifier == VZEngine.identifier {
            return "Virtualization.framework exposes no snapshot primitive: it can stop, pause and "
                + "resume a guest, but it cannot write a disk delta or RAM image to the bundle."
        }
        return "\(engineName) does not report snapshot support."
    }

    private var snapshotNextStep: String {
        if capabilities.snapshots { return "" }
        return "Use a QEMU machine with a qcow2 disk when you need rollback points. "
            + "QEMU saves RAM and disk state in one snapshot."
    }

    private var restoreBlockedReason: String? {
        guard capabilities.snapshots else { return "\(engineName) does not support snapshots." }
        switch machineState {
        case .starting, .pausing, .stopping:
            return "Wait for the machine to finish \(machineState.label.lowercased()) before restoring."
        case .running where !capabilities.saveState:
            return "Pause or stop the machine before restoring on this engine."
        default:
            return nil
        }
    }

    // MARK: - Engine actions

    private func load() async {
        failure = nil
        guard let instance else {
            snapshots = []
            return
        }
        isLoading = true
        do {
            let list = try await instance.engine.listSnapshots()
            snapshots = list.sorted { $0.createdAt > $1.createdAt }
        } catch {
            snapshots = []
            failure = error.localizedDescription
        }
        isLoading = false
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            failure = "Give the snapshot a name."
            return
        }
        guard let instance else {
            failure = "Start \(config.name) before creating a snapshot."
            return
        }

        busyAction = "Creating snapshot…"
        Task {
            do {
                _ = try await instance.engine.takeSnapshot(named: name)
                newName = ""
                busyAction = nil
                await load()
            } catch {
                failure = error.localizedDescription
                busyAction = nil
            }
        }
    }

    private func restore(_ snapshot: VMSnapshot) {
        guard let instance else {
            failure = "Start \(config.name) before restoring a snapshot."
            return
        }
        busyAction = "Restoring “\(snapshot.name)”…"
        Task {
            do {
                try await instance.engine.restoreSnapshot(id: snapshot.id)
                busyAction = nil
                await load()
            } catch {
                failure = error.localizedDescription
                busyAction = nil
            }
        }
    }

    private func delete(_ snapshot: VMSnapshot) {
        guard let instance else {
            failure = "Start \(config.name) before deleting a snapshot."
            return
        }
        busyAction = "Deleting “\(snapshot.name)”…"
        Task {
            do {
                try await instance.engine.deleteSnapshot(id: snapshot.id)
                busyAction = nil
                await load()
            } catch {
                failure = error.localizedDescription
                busyAction = nil
            }
        }
    }
}
