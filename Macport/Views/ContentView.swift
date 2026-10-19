import SwiftUI
import MacportKit

struct ContentView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @State private var selection: VMConfiguration.ID?

    var body: some View {
        NavigationSplitView {
            VMLibraryView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let id = selection,
               let config = store.machines.first(where: { $0.id == id }) {
                VMDetailView(config: config)
            } else {
                EmptyStateView()
            }
        }
        .sheet(isPresented: $state.isPresentingCreateSheet) {
            VMCreateView { config in
                state.create(config, in: store)
                selection = config.id
            }
        }
        .alert(
            "Macport",
            isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.dismissError() } }
            ),
            actions: { Button("OK") { state.dismissError() } },
            message: { Text(state.errorMessage ?? "") }
        )
    }
}

/// Shown when nothing is selected. Doubles as the first-run screen, so it has to
/// explain the product without a tutorial.
struct EmptyStateView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)

            Text("No virtual machine selected")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Macport runs ARM64 Linux and Windows 11 on Arm at native CPU speed.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Button("New Virtual Machine…") {
                state.isPresentingCreateSheet = true
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
