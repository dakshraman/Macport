import AppKit
import SwiftUI
import MacportKit

/// Application entry point.
///
/// Parallels Desktop signature architecture:
/// 1. "Control Center" (`⌘0`): The central gallery window managing all VMs.
/// 2. "Virtual Machine Window": Standalone edge-to-edge dedicated windows for each running VM.
@main
struct MacportApp: App {
    @StateObject private var store = VMStore()
    @StateObject private var state: AppState
    @StateObject private var ui: UIParityState

    init() {
        let state = AppState()
        _state = StateObject(wrappedValue: state)
        _ui = StateObject(wrappedValue: UIParityState(registry: state.registry))
    }

    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup("Macport", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(state)
                .environmentObject(ui)
                .frame(minWidth: 920, minHeight: 600)
                .task {
                    store.load()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
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

            CommandGroup(after: .windowArrangement) {
                Button("Control Center") {
                    if let window = NSApp.windows.first(where: {
                        $0.identifier?.rawValue.contains("main") == true ||
                        $0.title.contains("Control Center") ||
                        $0.title == "Macport"
                    }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandGroup(after: .windowSize) {
                Button("Snap Window to Guest") {
                    NotificationCenter.default.post(name: NSNotification.Name("MacportSnapWindow"), object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)
            }

            CommandMenu("View") {
                Button("Toggle Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])

                Divider()

                Button("Snap Window to Guest (1:1)") {
                    NotificationCenter.default.post(name: NSNotification.Name("MacportSnapWindow"), object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Fit Aspect Ratio") {
                    NotificationCenter.default.post(name: NSNotification.Name("MacportSetScalingMode"), object: DisplayScalingMode.aspectFit)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Stretch to Fill") {
                    NotificationCenter.default.post(name: NSNotification.Name("MacportSetScalingMode"), object: DisplayScalingMode.fill)
                }
                .keyboardShortcut("3", modifiers: .command)
            }

            machineCommands
        }

        // MARK: - Scene 2: Dedicated Virtual Machine Windows
        WindowGroup("Virtual Machine", for: UUID.self) { $vmId in
            if let id = vmId, let config = store.machines.first(where: { $0.id == id }) {
                DedicatedVMWindowView(config: config)
                    .environmentObject(store)
                    .environmentObject(state)
                    .environmentObject(ui)
                    .navigationTitle(config.name)
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 800, height: 600)

        // MARK: - Menu Bar Extra
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

    // MARK: - Machine & Actions menu

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

    /// The `Actions` & `Machine` menu: full parity with Parallels Desktop Actions menu.
    private var machineCommands: some Commands {
        CommandMenu("Actions") {
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

            Button("Send Ctrl+Alt+Del") {
                NotificationCenter.default.post(name: NSNotification.Name("MacportSendCtrlAltDel"), object: nil)
            }
            .disabled(selectedConfiguration == nil || !selectedState.isActive)

            Button("Send Shift+F10 (Command Prompt)") {
                NotificationCenter.default.post(name: NSNotification.Name("MacportSendShiftF10"), object: nil)
            }
            .disabled(selectedConfiguration == nil || !selectedState.isActive)

            Button("Paste from Mac Clipboard") {
                NotificationCenter.default.post(name: NSNotification.Name("MacportPasteClipboard"), object: nil)
            }
            .disabled(selectedConfiguration == nil || !selectedState.isActive)

            Divider()

            Button("Show in Finder") {
                guard let config = selectedConfiguration else { return }
                NSWorkspace.shared.activateFileViewerSelecting([store.bundleURL(for: config)])
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(selectedConfiguration == nil)

            Divider()

            Button("Configure…") {
                ui.isPresentingSettings = true
            }
            .keyboardShortcut(",", modifiers: .command)
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
