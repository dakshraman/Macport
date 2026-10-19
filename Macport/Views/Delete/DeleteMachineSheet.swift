import SwiftUI
import MacportKit

/// Delete confirmation. Moving to Trash is the default because it is
/// recoverable; the registry's own refusal wording is shown, not a paraphrase.
@MainActor
struct DeleteMachineSheet: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let config: VMConfiguration
    let onDeleted: () -> Void

    @State private var failure: String?

    private var refusal: String? { state.deleteRefusal(for: config) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Delete “\(config.name)”?")
                    .font(.title3.weight(.semibold))
                Text("The bundle and its disk move to the Trash.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let refusal {
                ProblemCard(
                    title: "This machine cannot be deleted while it is active",
                    message: refusal,
                    fix: "Stop \(config.name), wait for Off, then delete it. Deleting a live bundle would corrupt its disk."
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                KeyValueRow(label: "Bundle", value: store.bundleURL(for: config).lastPathComponent, mono: true)
                KeyValueRow(label: "Disk ceiling", value: config.diskBytes.gbString)
                KeyValueRow(label: "Guest", value: config.guest.displayName)
            }

            Text("Moving to the Trash is recoverable until you empty it. "
                 + "The machine disappears from Macport immediately.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let failure {
                ProblemCard(
                    title: "Delete failed",
                    message: failure,
                    fix: "Check that the Trash is writable and the bundle is not in use, then try again.",
                    onDismiss: { self.failure = nil }
                )
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) { delete() }
                    .disabled(refusal != nil)
            }
        }
        .padding(20)
        .frame(width: 540, height: 420)
    }

    private func delete() {
        do {
            try store.delete(config)
            onDeleted()
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
