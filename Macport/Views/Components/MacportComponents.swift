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
