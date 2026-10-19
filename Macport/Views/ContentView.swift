import SwiftUI
import MacportKit

/// The main window: library on the left, the selected machine's dashboard on
/// the right, and every sheet that acts on a machine.
@MainActor
struct ContentView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState

    var body: some View {
        NavigationSplitView {
            VMLibraryView(selection: $ui.selection)
                .navigationSplitViewColumnWidth(min: 232, ideal: 268)
        } detail: {
            detail
        }
        .navigationTitle("Macport")
        .navigationSubtitle(subtitle)
        .background(Color.macportWindow)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.isPresentingCreateSheet = true
                } label: {
                    Label("New Virtual Machine", systemImage: "plus")
                }
                .help("Create a new virtual machine (⌘N)")
                .accessibilityLabel("New virtual machine")
            }
        }
        .sheet(isPresented: $state.isPresentingCreateSheet) {
            VMCreateView { config in
                state.create(config, in: store)
                ui.selection = config.id
            }
        }
        .sheet(isPresented: $ui.isPresentingImport) {
            ImportWizardSheet(store: store, state: state) { config in
                ui.selection = config.id
            }
        }
        .sheet(isPresented: $ui.isPresentingSettings) {
            if let config = selectedConfig {
                MachineSettingsSheet(config: config)
            }
        }
        .sheet(isPresented: $ui.isPresentingSnapshots) {
            if let config = selectedConfig {
                SnapshotsSheet(config: config)
            }
        }
        .sheet(item: $ui.cloneTarget) { config in
            CloneSheet(config: config) { clone in
                ui.selection = clone.id
            }
        }
        .sheet(item: $ui.deleteTarget) { config in
            DeleteMachineSheet(config: config) {
                if ui.selection == config.id { ui.selection = nil }
            }
        }
        .overlay(alignment: .bottom) {
            problemOverlay
        }
        .tint(.macportAccent)
    }

    private var selectedConfig: VMConfiguration? {
        guard let id = ui.selection else { return nil }
        return store.machines.first { $0.id == id }
    }

    private var subtitle: String {
        if store.machines.isEmpty { return "No machines yet" }
        if ui.activeCount == 0 { return "No machines running" }
        return ui.activeCount == 1 ? "1 running" : "\(ui.activeCount) running"
    }

    @ViewBuilder
    private var detail: some View {
        if let config = selectedConfig {
            VMDetailView(config: config)
        } else if store.machines.isEmpty {
            EmptyStateView()
        } else {
            NoSelectionView()
        }
    }

    /// Failures are product surfaces, not alerts. The card carries the exact
    /// message the registry or engine produced and can be copied; it is never
    /// an "OK" dialog that teaches the user nothing.
    @ViewBuilder
    private var problemOverlay: some View {
        if let message = state.errorMessage {
            ProblemCard(
                title: "The last action did not finish",
                message: message,
                fix: "Fix the condition named above, then retry the action.",
                onDismiss: { state.dismissError() }
            )
            .frame(maxWidth: 640)
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// First-run and empty-library state. It has to explain the product and offer
/// both ways to get a machine, because a blank pane is not onboarding.
@MainActor
struct EmptyStateView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text("No virtual machines")
                .font(.title3.weight(.semibold))

            Text("Create one or import a disk image.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("New Virtual Machine…") {
                    state.isPresentingCreateSheet = true
                }
                .controlSize(.large)

                Button("Import a Disk Image…") {
                    ui.isPresentingImport = true
                }
                .controlSize(.large)
            }
            .padding(.top, 4)

            Text("Macport runs Arm64 Linux and Windows 11 on Arm on the same CPU as the host.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.macportWindow)
    }
}

/// Shown when the library has machines but none is selected.
@MainActor
struct NoSelectionView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No machine selected")
                .font(.title3.weight(.semibold))
            Text("Choose a machine in the sidebar to see its state, limits and controls.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.macportWindow)
    }
}
