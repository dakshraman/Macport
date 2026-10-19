import AppKit
import SwiftUI
import MacportKit

/// The menu bar extra's contents.
///
/// This is a full view over the same `AppState` the window uses: the running
/// count, every live machine's controls, and the machines that could be
/// started. It never keeps its own copy of runtime state, so a machine stopped
/// from the window disappears here at the same moment.
@MainActor
struct MenuBarContent: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState
    @Environment(\.openWindow) private var openWindow

    private var activeInstances: [VMInstance] { state.activeInstances }

    var body: some View {
        Text(countLabel)

        if activeInstances.isEmpty {
            Text("No machines are running")
        } else {
            Divider()
            ForEach(activeInstances) { instance in
                Menu("\(instance.config.name) — \(instance.state.label)") {
                    machineActions(for: instance)
                }
            }
        }

        let stopped = store.machines.filter { !state.isRunning($0.id) }
        if !stopped.isEmpty {
            Divider()
            Menu("Start Machine") {
                ForEach(stopped) { config in
                    Button(config.name) {
                        state.start(config, in: store)
                    }
                }
            }
        }

        Divider()
        Button("Open Macport") { showMainWindow() }
    }

    @ViewBuilder
    private func machineActions(for instance: VMInstance) -> some View {
        Button("Show in Macport") {
            ui.selection = instance.id
            showMainWindow()
        }

        Divider()

        if instance.state == .running {
            Button("Pause") {
                Task { await state.pause(id: instance.id) }
            }
            .disabled(!state.capabilities(for: instance.config).pauseResume)
        } else if instance.state == .paused {
            Button("Resume") {
                Task { await state.resume(id: instance.id) }
            }
            .disabled(!state.capabilities(for: instance.config).pauseResume)
        }

        Button("Shut Down") {
            Task { await state.stop(id: instance.id, graceful: true) }
        }

        Button("Force Off") {
            Task { await state.stop(id: instance.id, graceful: false) }
        }
    }

    private var countLabel: String {
        activeInstances.count == 1
            ? "1 machine running"
            : "\(activeInstances.count) machines running"
    }

    /// Bring the library window forward, reopening it if the user closed it.
    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        openWindow(id: "main")
    }
}
