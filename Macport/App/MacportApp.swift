import SwiftUI
import MacportKit

/// Application entry point.
///
/// Two long-lived objects are injected environment-wide rather than passed
/// around: the `VMStore` (what VMs exist on disk) and `AppState` (what is
/// running right now). Everything else is derived.
@main
struct MacportApp: App {
    @StateObject private var store = VMStore()
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(state)
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
        }
    }
}
