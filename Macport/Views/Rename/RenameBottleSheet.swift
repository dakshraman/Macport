import SwiftUI
import MacportKit

/// Sheet to rename a Wine bottle or virtual machine.
@MainActor
struct RenameBottleSheet: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss

    let config: VMConfiguration
    var onRenamed: ((VMConfiguration) -> Void)?

    @State private var newName: String
    @State private var errorText: String?
    @FocusState private var isFieldFocused: Bool

    init(config: VMConfiguration, onRenamed: ((VMConfiguration) -> Void)? = nil) {
        self.config = config
        self.onRenamed = onRenamed
        _newName = State(initialValue: config.name)
    }

    private var isBottle: Bool { config.guest == .windowsApp }
    private var isTrimmedEmpty: Bool { newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isUnchanged: Bool { newName.trimmingCharacters(in: .whitespacesAndNewlines) == config.name }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.crossoverBlue.opacity(0.18))
                        .frame(width: 40, height: 40)
                    Image(systemName: isBottle ? "shippingbox.fill" : "desktopcomputer")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.crossoverBlue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(isBottle ? "Rename Bottle" : "Rename Virtual Machine")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Enter a new name for '\(config.name)'.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.crossoverTextSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Color.crossoverBorder)

            // Content Form
            VStack(alignment: .leading, spacing: 14) {
                if let err = errorText {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.crossoverDangerText)
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.crossoverDangerText)
                        Spacer()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.crossoverDangerBg))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(isBottle ? "Bottle Name" : "Machine Name")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))

                    TextField(isBottle ? "Bottle Name" : "Machine Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .focused($isFieldFocused)
                        .onSubmit {
                            performRename()
                        }

                    Text(isBottle
                         ? "Renaming updates the bottle across Macport and keeps linked CrossOver metadata aligned."
                         : "Renaming updates the display name of this virtual machine.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.5))
                }

                Spacer()

                // Buttons
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("Rename") {
                        performRename()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.crossoverBlue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isTrimmedEmpty || isUnchanged)
                }
            }
            .padding(20)
        }
        .frame(width: 440, height: 230)
        .background(Color.crossoverInspector)
        .onAppear {
            isFieldFocused = true
        }
    }

    private func performRename() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != config.name else { return }

        do {
            let updated = try store.rename(config, to: trimmed)
            onRenamed?(updated)
            dismiss()
        } catch {
            errorText = "Failed to rename: \(error.localizedDescription)"
        }
    }
}
