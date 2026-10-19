import AppKit
import SwiftUI
import MacportKit

/// Application entry point.
///
/// Three long-lived objects are injected environment-wide rather than passed
/// around: the `VMStore` (what VMs exist on disk), `AppState` (what is running
/// right now), and `UIParityState` (selection and sheet presentation shared by
/// the window and the menu bar extra). Everything else is derived.
@main
struct MacportApp: App {
    @StateObject private var store = VMStore()
    @StateObject private var state: AppState
    @StateObject private var ui: UIParityState

    init() {
        // `UIParityState` mirrors the same registry `AppState` wraps, so the
        // menu bar extra and the window can never disagree about what is up.
        let state = AppState()
        _state = StateObject(wrappedValue: state)
        _ui = StateObject(wrappedValue: UIParityState(registry: state.registry))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(state)
                .environmentObject(ui)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    // Load once at launch. The store is the single source of
                    // truth for the library, so this is the only trigger needed.
                    store.load()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Machine…") {
                    state.isPresentingCreateSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("Import…") {
                    ui.isPresentingImport = true
                }
                .keyboardShortcut("i", modifiers: .command)
            }

            machineCommands
        }

        // Visible only while something is running. The insertion flag is
        // derived from the registry, so the setter is intentionally inert.
        MenuBarExtra(
            "Macport",
            systemImage: "desktopcomputer",
            isInserted: menuBarExtraInsertion
        ) {
            MenuBarContent()
                .environmentObject(store)
                .environmentObject(state)
                .environmentObject(ui)
        }
    }

    private var menuBarExtraInsertion: Binding<Bool> {
        Binding(
            get: { ui.isMenuBarExtraVisible },
            set: { _ in }
        )
    }

    // MARK: - Machine menu

    private var selectedConfiguration: VMConfiguration? {
        guard let id = ui.selection else { return nil }
        return store.machines.first { $0.id == id }
    }

    private var selectedState: VMState {
        guard let id = ui.selection else { return .stopped }
        return state.state(for: id)
    }

    private var selectedCapabilities: EngineCapabilities? {
        selectedConfiguration.map { state.capabilities(for: $0) }
    }

    private var selectedDeleteRefusal: String? {
        selectedConfiguration.flatMap { state.deleteRefusal(for: $0) }
    }

    /// The `Machine` menu. Every item is either actionable for the selected
    /// machine's current state or disabled — the menu never offers a control the
    /// registry would refuse.
    private var machineCommands: some Commands {
        CommandMenu("Machine") {
            Button("Start") {
                guard let config = selectedConfiguration else { return }
                state.start(config, in: store)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(selectedConfiguration == nil || selectedState.isActive)

            Button("Shut Down") {
                guard let id = ui.selection else { return }
                Task { await state.stop(id: id, graceful: true) }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(selectedConfiguration == nil || !selectedState.isActive)

            Button("Force Off") {
                guard let id = ui.selection else { return }
                Task { await state.stop(id: id, graceful: false) }
            }
            .keyboardShortcut(".", modifiers: [.command, .option])
            .disabled(selectedConfiguration == nil || !selectedState.isActive)

            Divider()

            if selectedState == .paused {
                Button("Resume") {
                    guard let id = ui.selection else { return }
                    Task { await state.resume(id: id) }
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(selectedCapabilities?.pauseResume != true)
            } else {
                Button("Pause") {
                    guard let id = ui.selection else { return }
                    Task { await state.pause(id: id) }
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(
                    selectedCapabilities?.pauseResume != true
                        || selectedState != .running
                )
            }

            Divider()

            Button("Show in Finder") {
                guard let config = selectedConfiguration else { return }
                NSWorkspace.shared.activateFileViewerSelecting([store.bundleURL(for: config)])
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(selectedConfiguration == nil)

            Divider()

            Button("Machine Settings…") {
                ui.isPresentingSettings = true
            }
            .disabled(selectedConfiguration == nil)

            Button("Snapshots…") {
                ui.isPresentingSnapshots = true
            }
            .disabled(selectedConfiguration == nil)

            Button("Clone…") {
                guard let config = selectedConfiguration else { return }
                ui.cloneTarget = config
            }
            .disabled(selectedConfiguration == nil || selectedState.isActive)
            .help(selectedConfiguration.flatMap { state.cloneRefusal(for: $0) }
                ?? "Make an instant copy of this machine.")

            Button("Delete…") {
                guard let config = selectedConfiguration else { return }
                ui.deleteTarget = config
            }
            .disabled(selectedConfiguration == nil || selectedDeleteRefusal != nil)
            .help(selectedDeleteRefusal ?? "Move this machine’s bundle to the Trash.")
        }
    }
}
