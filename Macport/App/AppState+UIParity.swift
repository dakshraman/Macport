import AppKit
import Combine
import Foundation
import MacportKit

/// Selection and sheet state for the UI-parity surfaces.
///
/// This is deliberately not part of `AppState`: `AppState` is the runtime seam,
/// and another workstream owns it. Everything here is presentation state that
/// the menu commands, the sidebar and the detail pane must agree on, so it lives
/// in one observable object instead of being duplicated as `@State` in each
/// view.
@MainActor
final class UIParityState: ObservableObject {
    /// The machine selected in the library. Kept here because the `Machine` menu
    /// commands act on the same selection as the sidebar.
    @Published var selection: VMConfiguration.ID?

    @Published var isPresentingImport = false
    @Published var isPresentingSettings = false
    @Published var isPresentingSnapshots = false
    @Published var cloneTarget: VMConfiguration?
    @Published var deleteTarget: VMConfiguration?

    /// Drives the window-title badge and the menu bar extra's visibility.
    @Published private(set) var activeCount = 0
    @Published private(set) var isMenuBarExtraVisible = false

    private let registry: VMRuntimeRegistry
    private var observation: AnyCancellable?

    init(registry: VMRuntimeRegistry) {
        self.registry = registry

        // Same pattern as `AppState`: the registry announces changes before the
        // mutation, so the hop back to the main actor reads the settled state.
        observation = registry.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refresh()
    }

    private func refresh() {
        let count = registry.instances.values.filter { $0.state.isActive }.count
        if activeCount != count { activeCount = count }

        let shouldShowMenuBar = count > 0
        if isMenuBarExtraVisible != shouldShowMenuBar {
            isMenuBarExtraVisible = shouldShowMenuBar
        }
    }
}

// MARK: - AppState conveniences

/// Read-only projections over the registry. `AppState` already exposes the
/// lifecycle calls; these exist so the views do not each re-derive capacity or
/// restate the registry's refusal wording differently.
extension AppState {
    var activeInstances: [VMInstance] {
        registry.instances.values
            .filter { $0.state.isActive }
            .sorted { $0.config.name.localizedStandardCompare($1.config.name) == .orderedAscending }
    }

    /// Configurations of every active machine except `excluding`. Used by the
    /// settings sheet so a running machine is not counted against its own edit.
    func runningConfigurations(excluding excluded: UUID? = nil) -> [VMConfiguration] {
        activeInstances
            .filter { $0.id != excluded }
            .map(\.config)
    }

    func startedAt(for id: UUID) -> Date? {
        registry.instance(id)?.startedAt
    }

    func lastError(for id: UUID) -> String? {
        registry.instance(id)?.lastError
    }

    func engineIdentifier(for config: VMConfiguration) -> String {
        hostingEngine(for: config).identifier
    }

    func allocatedMemoryBytes() -> UInt64 {
        activeInstances.reduce(0) { total, instance in
            let (sum, overflow) = total.addingReportingOverflow(instance.config.memoryBytes)
            return overflow ? UInt64.max : sum
        }
    }

    func allocatedProcessors() -> Int {
        activeInstances.reduce(0) { $0 + max(1, $1.config.cpuCount) }
    }

    /// Why the registry would refuse a delete, in its own vocabulary.
    ///
    /// The registry has no delete call, but it does own the truth about whether
    /// a machine is active. The wording mirrors the refusals it does produce so
    /// the user reads one voice, not two.
    func deleteRefusal(for config: VMConfiguration) -> String? {
        guard let instance = registry.instance(config.id), instance.state.isActive else {
            return nil
        }
        switch instance.state {
        case .starting, .pausing:
            return "This virtual machine is still starting. Wait for it to come up, then stop it."
        case .stopping:
            return "This virtual machine is still stopping. Wait for it to stop, then delete it."
        default:
            return "\(config.name) is already running on \(instance.engineName). "
                + "Stop it before deleting it."
        }
    }

    /// Cloning a live guest would copy a disk mid-write. The registry is the
    /// authority on "live"; this is its answer in one sentence.
    func cloneRefusal(for config: VMConfiguration) -> String? {
        guard registry.instance(config.id)?.state.isActive == true else { return nil }
        return "Stop \(config.name) first — cloning a running guest can corrupt the disk."
    }
}

// MARK: - Formatting

enum MacportFormat {
    /// A file size with the unit a person recognises. Byte counts from
    /// `qemu-img` can be small (metadata) or tens of gigabytes.
    static func fileSize(_ bytes: UInt64?) -> String {
        guard let bytes else { return "Unavailable" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    /// Uptime as `m:ss` under an hour, `h:mm:ss` above it.
    static func uptime(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    static func snapshotDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
