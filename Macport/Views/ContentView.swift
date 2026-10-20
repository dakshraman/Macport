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
        Group {
            if ui.viewMode == .gallery {
                ControlCenterView()
            } else {
                NavigationSplitView {
                    VMLibraryView(selection: $ui.selection)
                        .navigationSplitViewColumnWidth(min: 232, ideal: 268)
                } detail: {
                    detail
                }
            }
        }
        .navigationTitle(ui.viewMode == .gallery ? "Control Center" : "Macport")
        .navigationSubtitle(subtitle)
        .background(Color.macportWindow)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $ui.viewMode) {
                    Label("Control Center", systemImage: "square.grid.2x2").tag(ControlCenterViewMode.gallery)
                    Label("Sidebar", systemImage: "sidebar.left").tag(ControlCenterViewMode.split)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .help("Switch between Control Center and Sidebar view")
            }

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
            VMCreateView(
                onCreate: { config in
                    state.create(config, in: store)
                    ui.selection = config.id
                },
                onCreateAndStart: { config in
                    state.create(config, in: store)
                    ui.selection = config.id
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        state.start(config, in: store)
                    }
                }
            )
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
        .onAppear {
            if let logo = NSImage(named: "AppLogo") {
                NSApp.applicationIconImage = logo
            }
        }
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
        VStack(spacing: 20) {
            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Color.black.opacity(0.35), radius: 12, y: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .accessibilityLabel("Macport App Logo")

            VStack(spacing: 6) {
                Text("Macport")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text("Native Apple Silicon Virtual Machine Manager")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                Text("No virtual machines yet")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Text("Create a new machine from an ISO or import an existing disk image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 4)

            HStack(spacing: 12) {
                Button {
                    state.isPresentingCreateSheet = true
                } label: {
                    Label("New Virtual Machine…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    ui.isPresentingImport = true
                } label: {
                    Label("Import Disk Image…", systemImage: "arrow.down.doc")
                }
                .controlSize(.large)
            }
            .padding(.top, 8)

            Text("Macport runs ARM64 Linux and Windows 11 on Arm at native speed via the macOS hypervisor.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.top, 6)
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
