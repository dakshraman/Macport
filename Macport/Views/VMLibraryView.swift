import SwiftUI
import MacportKit

/// Sidebar list of every VM on disk, plus the create action.
struct VMLibraryView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @Binding var selection: VMConfiguration.ID?

    var body: some View {
        List(selection: $selection) {
            if store.machines.isEmpty {
                Text("No virtual machines")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.machines) { config in
                    VMRow(config: config)
                        .tag(config.id)
                        .contextMenu {
                            Button("Delete…", role: .destructive) {
                                delete(config)
                            }
                            .disabled(state.runningVMID == config.id)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.isPresentingCreateSheet = true
                } label: {
                    Label("New Virtual Machine", systemImage: "plus")
                }
                .help("Create a new virtual machine")
            }
        }
    }

    private func delete(_ config: VMConfiguration) {
        do {
            try store.delete(config)
            if selection == config.id { selection = nil }
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }
}

private struct VMRow: View {
    @EnvironmentObject private var state: AppState
    let config: VMConfiguration

    private var isRunning: Bool { state.runningVMID == config.id }

    var body: some View {
        HStack(spacing: 10) {
            // A dot, not an icon: running state should be readable at a glance
            // without parsing iconography.
            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(config.name)
                    .lineLimit(1)
                Text(config.guest.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isRunning {
                Text("Running")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }
}
