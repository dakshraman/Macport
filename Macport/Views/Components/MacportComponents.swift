import AppKit
import SwiftUI
import MacportKit

// MARK: - Guest avatar

/// Guest identity tile. Uses a low-saturation guest hue at 14 % behind an SF
/// Symbol; never a vendor logo and never an emoji.
@MainActor
struct GuestAvatar: View {
    let guest: GuestKind
    var size: CGFloat = 28

    private var hue: Color {
        switch guest {
        case .linuxARM: return .macportLinuxHue
        case .windowsARM, .windowsApp: return .macportWindowsHue
        case .macOSGuest: return .macportMacOSHue
        }
    }

    private var symbol: String {
        switch guest {
        case .linuxARM: return "terminal"
        case .windowsARM: return "square.grid.2x2"
        case .windowsApp: return "macwindow"
        case .macOSGuest: return "apple.logo"
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(hue.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(hue)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - State indicators

/// A status dot with a spoken label. Status is never colour alone: every row
/// that uses this also carries the state word or an accessible value.
@MainActor
struct StateDot: View {
    let state: VMState
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: size, height: size)
            .accessibilityLabel("State: \(state.accessibilityWord)")
    }
}

/// Capsule with a word, tinted by state. The word is the load-bearing part.
@MainActor
struct StatusPill: View {
    let state: VMState

    var body: some View {
        Text(state.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(state.tint.opacity(0.12)))
            .accessibilityLabel("State: \(state.accessibilityWord)")
    }
}

// MARK: - Engine chip

@MainActor
struct EngineChip: View {
    let identifier: String
    let fullName: String
    var reason: String?

    init(config: VMConfiguration) {
        let type = EngineRegistry.engineType(for: config)
        identifier = type.identifier
        fullName = type.displayName
        reason = EngineRegistry.rationale(for: config)
    }

    init(identifier: String, fullName: String, reason: String? = nil) {
        self.identifier = identifier
        self.fullName = fullName
        self.reason = reason
    }

    /// The engine's own short name. QEMU and VZ are the two identifiers the
    /// engines ship with; anything else falls back to its identifier so a new
    /// engine cannot silently become a blank chip.
    private var shortName: String {
        if identifier == QEMUEngine.identifier { return "HVF" }
        if identifier == VZEngine.identifier { return "VZ" }
        return identifier.uppercased()
    }

    var body: some View {
        Text(shortName)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.macportInset))
            .overlay(Capsule().stroke(Color.macportBorderSubtle, lineWidth: 1))
            .help(helpText)
            .accessibilityLabel("Engine \(fullName)")
    }

    private var helpText: String {
        if let reason, !reason.isEmpty { return "\(fullName) — \(reason)" }
        return fullName
    }
}

// MARK: - Capacity

/// One labelled host-capacity bar. The label says what is counted, because
/// "48 %" without a denominator is decoration, not instrumentation.
@MainActor
struct CapacityBar: View {
    let caption: String
    let valueText: String
    let fraction: Double
    var tint: Color?
    var detail: String?

    private var clamped: Double { min(1, max(0, fraction)) }

    private var fill: Color {
        if let tint { return tint }
        if clamped > 0.95 { return .macportError }
        if clamped > 0.80 { return .macportPaused }
        return .macportAccent
    }

    private var percentText: String {
        "\(Int((clamped * 100).rounded())) percent"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(valueText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.macportInset)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fill)
                        .frame(width: max(2, geometry.size.width * clamped))
                }
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel(caption)
            .accessibilityValue("\(valueText), \(percentText)")

            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Capability row

/// One engine capability, with the consequence and next step on unsupported
/// rows. A verdict of "Not available" alone is not an answer.
@MainActor
struct CapabilityRow: View {
    let name: String
    let supported: Bool
    let verdict: String
    var reason: String?
    var nextStep: String?

    private var symbol: String {
        supported ? "checkmark.circle.fill" : "slash.circle.fill"
    }

    private var symbolColor: Color {
        supported ? .macportRunning : .macportOff
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(symbolColor)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 8)
                    Text(verdict)
                        .font(.system(size: 12))
                        .foregroundStyle(supported ? .secondary : .tertiary)
                }

                if let reason {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let nextStep {
                    Text(nextStep)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(verdict)")
    }
}

// MARK: - Cards

@MainActor
struct InfoCard<Content: View>: View {
    let title: String
    var subtitle: String?
    var badge: String?
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                if let badge { RestartBadge(text: badge) }
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.macportCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.macportBorderSubtle, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// "Takes effect after restart" — the badge UI-SPEC §D asks for on sections
/// whose values the running engine has already consumed.
@MainActor
struct RestartBadge: View {
    var text: String = "Takes effect after restart"

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.macportPaused)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.macportPaused.opacity(0.12)))
            .fixedSize()
            .accessibilityLabel(text)
    }
}

/// Operational failure with an action. Never a modal alert with an OK button:
/// the message is copyable, the fix is stated, and the card stays until the
/// condition is resolved or explicitly cleared.
@MainActor
struct ProblemCard: View {
    let title: String
    let message: String
    var detail: String?
    var fix: String?
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.macportError)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss problem")
                    .help("Dismiss this problem")
                }
            }

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let fix {
                Label(fix, systemImage: "wrench.and.screwdriver")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Copy details") { copyDetails() }
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.macportError.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.macportError.opacity(0.30), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Problem: \(title)")
    }

    private func copyDetails() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString([title, message, detail, fix].compactMap { $0 }.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Key/value rows

@MainActor
struct KeyValueRow: View {
    let label: String
    let value: String
    var mono: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Macport App Logo

/// The signature Macport Pro emblem: Apple Pro titanium squircle with
/// metallic chamfer, rotating gateway diamond, and electric cyan/blue bolt.
@MainActor
public struct MacportAppLogoView: View {
    public let size: CGFloat
    public var hasShadow: Bool

    public init(size: CGFloat = 38, hasShadow: Bool = true) {
        self.size = size
        self.hasShadow = hasShadow
    }

    public var body: some View {
        let cornerRadius = size * (10.0 / 38.0)
        let strokeWidth = max(1.0, size * (1.0 / 38.0))
        let diamondSize = size * (20.0 / 38.0)
        let diamondCorner = diamondSize * (6.0 / 20.0)
        let diamondStroke = max(1.5, size * (1.8 / 38.0))
        let boltFontSize = size * (13.0 / 38.0)

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.25), Color(white: 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: strokeWidth
                        )
                )
                .shadow(
                    color: hasShadow ? .black.opacity(0.4) : .clear,
                    radius: hasShadow ? max(2, size * 0.1) : 0,
                    y: hasShadow ? max(1, size * 0.05) : 0
                )

            ZStack {
                RoundedRectangle(cornerRadius: diamondCorner, style: .continuous)
                    .stroke(Color.crossoverBlue, lineWidth: diamondStroke)
                    .frame(width: diamondSize, height: diamondSize)
                    .rotationEffect(.degrees(45))

                Image(systemName: "bolt.fill")
                    .font(.system(size: boltFontSize, weight: .bold))
                    .foregroundStyle(Color.crossoverBlue)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Rename Bottle / VM Sheet

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

// MARK: - Uninstall Bottle Applications Sheet

/// Sheet listing applications installed in a Wine bottle with direct 1-click uninstallation.
@MainActor
struct UninstallBottleAppsSheet: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let config: VMConfiguration

    @State private var installedApps: [WineInstalledApp] = []
    @State private var searchQuery: String = ""
    @State private var targetToUninstall: WineInstalledApp?
    @State private var isConfirmingUninstall = false
    @State private var statusMessage: String?
    @State private var isLoading = true

    private var bundleURL: URL { store.bundleURL(for: config) }

    private var filteredApps: [WineInstalledApp] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return installedApps }
        return installedApps.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.key.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.crossoverDangerBg)
                        .frame(width: 40, height: 40)
                    Image(systemName: "xmark.bin.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.crossoverDangerText)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall Applications")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Bottle: \(config.name)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.crossoverTextSecondary)
                }

                Spacer()

                // Search field
                if installedApps.count > 3 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.5))

                        TextField("Filter apps…", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.white)

                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(white: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.2)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .frame(width: 170)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Color.crossoverBorder)

            // Status message banner
            if let msg = statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.crossoverBlue)
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                    Spacer()
                    Button { statusMessage = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.crossoverCard)
            }

            // App List
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning bottle for installed applications…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.crossoverTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredApps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundStyle(Color(white: 0.35))
                    Text(installedApps.isEmpty ? "No removable applications detected" : "No applications matching '\(searchQuery)'")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Text("You can still open Windows Add/Remove Programs below to manage system components.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.crossoverTextSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredApps) { app in
                            appRow(app)
                        }
                    }
                    .padding(16)
                }
            }

            Divider().background(Color.crossoverBorder)

            // Bottom Actions Bar
            HStack {
                Button {
                    launchAddRemovePrograms()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11))
                        Text("Open Windows Add/Remove Programs…")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.crossoverBlue)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 420)
        .background(Color.crossoverInspector)
        .onAppear {
            refreshApps()
        }
        .confirmationDialog(
            "Uninstall \(targetToUninstall?.displayName ?? "Application")?",
            isPresented: $isConfirmingUninstall,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                if let app = targetToUninstall {
                    performUninstall(app)
                }
            }
            Button("Cancel", role: .cancel) {
                targetToUninstall = nil
            }
        } message: {
            Text("This will launch the application's Windows uninstaller in '\(config.name)' to remove its program files. Also clean up any exported Mac application wrappers in Applications and Desktop.")
        }
    }

    private func appRow(_ app: WineInstalledApp) -> some View {
        HStack(spacing: 12) {
            // Icon
            if let iconURL = app.iconURL, let img = NSImage(contentsOf: iconURL) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(white: 0.22))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: app.isSystemTool ? "gearshape.fill" : "app.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.crossoverBlue)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)

                    if app.isSystemTool {
                        Text("SYSTEM")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(white: 0.6))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                }

                if let loc = app.installLocation, !loc.isEmpty {
                    Text(loc)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Button {
                targetToUninstall = app
                isConfirmingUninstall = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                    Text("Uninstall")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.crossoverDangerText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.crossoverDangerBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.crossoverDangerText.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.crossoverCard)
        )
    }

    private func refreshApps() {
        isLoading = true
        Task {
            let apps = WineBottleManager.scanInstalledApplications(in: bundleURL)
            await MainActor.run {
                self.installedApps = apps
                self.isLoading = false
            }
        }
    }

    private func performUninstall(_ app: WineInstalledApp) {
        Task {
            do {
                let parsed: (executable: String, arguments: [String])
                if let uninstStr = app.uninstallString, !uninstStr.isEmpty {
                    parsed = WineBottleManager.parseCommandAndArguments(uninstStr)
                } else {
                    parsed = ("uninstaller.exe", [])
                }

                let engine = (state.instance(for: config.id)?.engine as? WineEngine) ?? WineEngine()
                try await engine.launchExecutable(parsed.executable, arguments: parsed.arguments, in: bundleURL, metal: true)

                // Clean up any exported Mac wrapper apps
                WineBottleManager.removeLauncherApps(appName: app.displayName)

                statusMessage = "Launched uninstaller for '\(app.displayName)'. Follow on-screen instructions to complete uninstallation."

                try? await Task.sleep(nanoseconds: 1_500_000_000)
                refreshApps()
            } catch {
                statusMessage = "Failed to launch uninstaller: \(error.localizedDescription)"
            }
        }
    }

    private func launchAddRemovePrograms() {
        Task {
            do {
                let engine = (state.instance(for: config.id)?.engine as? WineEngine) ?? WineEngine()
                try await engine.launchExecutable("uninstaller.exe", arguments: [], in: bundleURL, metal: true)
                statusMessage = "Opened Windows Add/Remove Programs panel."
            } catch {
                statusMessage = "Failed to open Add/Remove Programs: \(error.localizedDescription)"
            }
        }
    }
}
