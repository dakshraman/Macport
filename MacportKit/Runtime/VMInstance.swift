import Combine
import Foundation

/// One virtual machine that the runtime is holding, and everything the UI needs
/// to describe it without reaching back into the engine.
///
/// Deliberately a *snapshot of live state*, not another engine wrapper: the
/// registry polls the engine and writes the results here, so `VMInstance` is the
/// only object the UI observes for "is this VM up?". Two sources of truth for
/// that question is one too many, and the one that drifts is always the cache.
@MainActor
public final class VMInstance: ObservableObject, Identifiable {
    /// The VM's identifier. Equal to `config.id`, so the registry's dictionary
    /// and a persisted configuration cannot disagree about which machine is which.
    public let id: UUID
    public let config: VMConfiguration
    public let engine: any VMEngine
    public let engineName: String

    /// Engine state as of the last refresh.
    @Published public private(set) var state: VMState

    /// Why the machine last stopped abnormally, as of the last refresh.
    @Published public private(set) var lastError: String?

    /// When the registry handed this instance its engine.
    @Published public private(set) var startedAt: Date?

    /// Is the guest drawing itself into a window Macport does not own?
    ///
    /// True for QEMU, which opens its own Cocoa window. Surfaced per instance
    /// because with several VMs running, "the guest is somewhere else" is a fact
    /// about *this* machine, not about the app.
    ///
    /// Deriving it from the routed engine rather than from the concrete instance
    /// type is what keeps this honest for a `VMHostProxy`: the proxy is a
    /// different class, but the machine is still a QEMU guest in its own window.
    @Published public private(set) var runsInExternalWindow: Bool

    /// The background host that owns this machine, when there is one.
    ///
    /// Present for hosted QEMU machines so the UI and CLI can name the pid; nil
    /// for in-process engines, which have no separate process to describe.
    public let hostMetadata: VMHostMetadata?

    public init(
        config: VMConfiguration,
        engine: any VMEngine,
        engineName: String? = nil,
        startedAt: Date? = Date(),
        hostMetadata: VMHostMetadata? = nil
    ) {
        self.id = config.id
        self.config = config
        self.engine = engine
        self.engineName = engineName ?? type(of: engine).displayName
        self.state = engine.state
        self.lastError = engine.lastError
        self.startedAt = startedAt
        self.hostMetadata = hostMetadata
        let routed = EngineRegistry.engineType(for: config)
        self.runsInExternalWindow =
            ObjectIdentifier(routed) == ObjectIdentifier(QEMUEngine.self)
            || ObjectIdentifier(routed) == ObjectIdentifier(WineEngine.self)
    }

    /// Copy the engine's live state into this instance.
    ///
    /// Returns whether anything actually changed, so the registry can avoid
    /// waking SwiftUI four times a second for a machine that is sitting still.
    @discardableResult
    func update(state: VMState, lastError: String?) -> Bool {
        var changed = false
        if self.state != state {
            self.state = state
            changed = true
        }
        if self.lastError != lastError {
            self.lastError = lastError
            changed = true
        }
        return changed
    }
}
