import AppKit
import SwiftUI
import MacportKit

/// The visual tokens from `docs/UI-SPEC.md` §3.1.
///
/// These are adaptive colours rather than asset-catalog entries because the
/// palette is a semantic set — the same token has two reference values — and a
/// single Swift declaration keeps the light and dark halves from drifting. Text
/// uses the system styles, which already match the spec's SF Pro scale.
extension Color {
    static let macportWindow = adaptive(light: 0xECEDF0, dark: 0x0F1216)
    static let macportCard = adaptive(light: 0xFFFFFF, dark: 0x171B21)
    static let macportInset = adaptive(light: 0xF3F4F7, dark: 0x11151A)

    static let macportBorderSubtle = adaptive(
        light: 0x000000, dark: 0xFFFFFF,
        lightAlpha: 0.07, darkAlpha: 0.08
    )
    static let macportBorderStrong = adaptive(
        light: 0x000000, dark: 0xFFFFFF,
        lightAlpha: 0.14, darkAlpha: 0.16
    )

    /// Harbour teal. Deliberately not system blue, and deliberately not one of
    /// the three status colours.
    static let macportAccent = adaptive(light: 0x0E7C86, dark: 0x35C0CC)
    static let macportAccentSubtle = adaptive(
        light: 0x0E7C86, dark: 0x35C0CC,
        lightAlpha: 0.12, darkAlpha: 0.16
    )

    static let macportRunning = adaptive(light: 0x1E9E52, dark: 0x3DDC84)
    static let macportPaused = adaptive(light: 0xB4690E, dark: 0xE8A33D)
    static let macportError = adaptive(light: 0xD32F2F, dark: 0xFF6B6B)
    static let macportOff = adaptive(light: 0x8A8F98, dark: 0x6E7681)
    static let macportDanger = adaptive(light: 0xD32F2F, dark: 0xE5484D)

    /// Guest identity hues. Used only in the avatar tile, never status.
    static let macportLinuxHue = adaptive(light: 0xB4690E, dark: 0xE8A33D)
    static let macportWindowsHue = adaptive(light: 0x1E5FA8, dark: 0x6FA8E8)
    static let macportMacOSHue = adaptive(light: 0x5B5F66, dark: 0xA4ABB6)

    // MARK: - CrossOver Dark UI Palette
    static let crossoverSidebar = Color(red: 0.12, green: 0.125, blue: 0.135)
    static let crossoverCanvas = Color(red: 0.165, green: 0.173, blue: 0.188)
    static let crossoverInspector = Color(red: 0.145, green: 0.153, blue: 0.165)
    static let crossoverBlue = Color(red: 0.04, green: 0.45, blue: 0.88)
    static let crossoverCard = Color(red: 0.20, green: 0.21, blue: 0.23)
    static let crossoverBorder = Color.white.opacity(0.08)

    private static func adaptive(
        light: UInt32,
        dark: UInt32,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor.macport(
                hex: isDark ? dark : light,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }
}

extension NSColor {
    fileprivate static func macport(hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - State vocabulary

extension VMState {
    /// The word every surface uses for this state (UI-SPEC §2.1). `stopped` is
    /// "Off" to a person; the internal name is an implementation detail.
    var label: String {
        switch self {
        case .stopped: return "Off"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .pausing: return "Pausing…"
        case .paused: return "Paused"
        case .stopping: return "Stopping…"
        case .error: return "Stopped with errors"
        }
    }

    var tint: Color {
        switch self {
        case .running: return .macportRunning
        case .pausing, .paused: return .macportPaused
        case .error: return .macportError
        case .stopped: return .macportOff
        case .starting, .stopping: return .macportAccent
        }
    }

    /// VoiceOver must speak a word, never just announce a coloured dot.
    var accessibilityWord: String {
        switch self {
        case .stopped: return "off"
        case .starting: return "starting"
        case .running: return "running"
        case .pausing, .paused: return "paused"
        case .stopping: return "stopping"
        case .error: return "failed"
        }
    }

    var isTransitioning: Bool {
        switch self {
        case .starting, .pausing, .stopping: return true
        default: return false
        }
    }
}
