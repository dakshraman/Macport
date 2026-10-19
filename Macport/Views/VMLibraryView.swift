import AppKit
import SwiftUI
import MacportKit

/// Sidebar library: every machine on disk, its live state, and the power
/// actions that are honest for that state.
@MainActor
struct VMLibraryView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState

    @Binding var selection: VMConfiguration.ID?
    @State private var query = ""

    /// Search is a tool for a library, not for three rows: it appears only once
    /// scanning the whole list stops being faster than typing.
    private var showsSearch: Bool { store.machines.count > 5 }

    private var visibleMachines: [VMConfiguration] {
        guard showsSearch, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return store.machines
        }
        let needle = query.lowercased()
        return store.machines.filter {
            $0.name.lowercased().contains(needle)
                || $0.guest.displayName.lowercased().contains(needle)
        }
    }

    var body: some View {
        List(selection: $selection) {
            if showsSearch {
                searchRow
            }

            if store.machines.isEmpty {
                Text("No virtual machines")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else if visibleMachines.isEmpty {
                Text("No machines match “\(query)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(visibleMachines) { config in
                    VMRow(config: config)
                        .tag(config.id)
                        .contextMenu { contextMenu(for: config) }
                }
            }

            Section {
                Button {
                    state.isPresentingCreateSheet = true
                } label: {
                    Label("New Virtual Machine…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.macportAccent)

                Button {
                    ui.isPresentingImport = true
                } label: {
                    Label("Import Disk Image…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.macportAccent)
            }
        }
        .listStyle(.sidebar)
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Filter machines", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.macportInset)
        )
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
    }

    @ViewBuilder
    private func contextMenu(for config: VMConfiguration) -> some View {
        let vmState = state.state(for: config.id)
        let capabilities = state.capabilities(for: config)
        let refusal = state.deleteRefusal(for: config)

        Button("Start") {
            state.start(config, in: store)
        }
        .disabled(vmState.isActive)
        .help(vmState.isActive ? "This machine is already up." : "Start this machine.")

        Button("Shut Down") {
            Task { await state.stop(id: config.id, graceful: true) }
        }
        .disabled(!vmState.isActive)
        .help(vmState.isActive ? "Ask the guest to shut down." : "This machine is not running.")

        Button("Force Off") {
            Task { await state.stop(id: config.id, graceful: false) }
        }
        .disabled(!vmState.isActive)
        .help(vmState.isActive ? "Power off without a guest shutdown." : "This machine is not running.")

        Divider()

        Button(vmState == .paused ? "Resume" : "Pause") {
            Task {
                if vmState == .paused {
                    await state.resume(id: config.id)
                } else {
                    await state.pause(id: config.id)
                }
            }
        }
        .disabled(
            !capabilities.pauseResume
                || !(vmState == .running || vmState == .paused)
        )
        .help(pauseHelp(state: vmState, capabilities: capabilities))

        Divider()

        Button("Clone…") {
            ui.cloneTarget = config
        }
        .disabled(vmState.isActive)
        .help(state.cloneRefusal(for: config) ?? "Make an instant copy of this machine.")

        Button("Delete…") {
            ui.deleteTarget = config
        }
        .disabled(refusal != nil)
        .help(refusal ?? "Move this machine’s bundle to the Trash.")

        Button("Show in Finder") {
            reveal(config)
        }
    }

    private func pauseHelp(state: VMState, capabilities: EngineCapabilities) -> String {
        if !capabilities.pauseResume { return "This engine does not support pause and resume." }
        switch state {
        case .running: return "Suspend the guest in host memory."
        case .paused: return "Continue the paused guest."
        default: return "Only a running machine can be paused."
        }
    }

    private func reveal(_ config: VMConfiguration) {
        let bundle = store.bundleURL(for: config)
        NSWorkspace.shared.activateFileViewerSelecting([bundle])
    }
}

// MARK: - Row

@MainActor
private struct VMRow: View {
    @EnvironmentObject private var state: AppState

    let config: VMConfiguration

    private var vmState: VMState { state.state(for: config.id) }

    var body: some View {
        HStack(spacing: 8) {
            StateDot(state: vmState)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(config.name)
                        .font(.system(size: 13))
                        .lineLimit(1)

                    if let error = state.lastError(for: config.id) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.macportError)
                            .help(error)
                            .accessibilityLabel("Last error")
                    }
                }

                if let error = state.lastError(for: config.id), vmState == .error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.macportError)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                } else {
                    HStack(spacing: 4) {
                        Text(config.guest.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        EngineChip(config: config)
                    }
                }
            }

            Spacer(minLength: 4)

            if vmState.isTransitioning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("State: \(vmState.accessibilityWord)")
            } else if vmState == .running || vmState == .paused {
                Text(vmState.label)
                    .font(.system(size: 11))
                    .foregroundStyle(vmState.tint)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(config.name), \(config.guest.displayName), \(vmState.accessibilityWord)"
        )
    }
}
