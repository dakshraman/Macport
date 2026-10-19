import SwiftUI
import MacportKit

/// Clone a stopped machine. The clone service refuses a bundle it cannot
/// snapshot-copy, and its message is shown verbatim — this sheet never invents a
/// friendlier failure than the one the filesystem produced.
@MainActor
struct CloneSheet: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let config: VMConfiguration
    let onCloned: (VMConfiguration) -> Void

    @State private var name: String
    @State private var failure: String?
    @State private var isCloning = false

    init(config: VMConfiguration, onCloned: @escaping (VMConfiguration) -> Void) {
        self.config = config
        self.onCloned = onCloned
        _name = State(initialValue: "\(config.name) Copy")
    }

    private var refusal: String? { state.cloneRefusal(for: config) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clone Machine")
                    .font(.title3.weight(.semibold))
                Text(config.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let refusal {
                ProblemCard(
                    title: "This machine cannot be cloned while it is up",
                    message: refusal,
                    fix: "Stop \(config.name), wait for it to reach Off, then clone it."
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.system(size: 12, weight: .medium))
                TextField("Clone name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("The clone gets a new identifier and its own bundle. On APFS it is an instant "
                     + "copy-on-write clone, not a multi-gigabyte copy.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                ProblemCard(
                    title: "Clone failed",
                    message: failure,
                    fix: "Resolve the condition above, then try again. The original machine was not changed.",
                    onDismiss: { self.failure = nil }
                )
            }

            Spacer()

            HStack {
                if isCloning {
                    ProgressView().controlSize(.small)
                    Text("Cloning…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCloning)
                Button("Clone") { clone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCloning || refusal != nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
    }

    /// `VMCloner` is main-actor because it saves through `VMStore`. It uses
    /// `clonefile(2)`, so the work is filesystem metadata rather than a byte
    /// copy; the honest place to keep it is the actor that owns the store.
    private func clone() {
        isCloning = true
        Task {
            do {
                let clone = try VMCloner.clone(config, in: store, named: name)
                isCloning = false
                onCloned(clone)
                dismiss()
            } catch {
                isCloning = false
                failure = error.localizedDescription
            }
        }
    }
}
