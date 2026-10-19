import Combine
import Foundation

/// Owns every running virtual machine, and the admission decision that lets one
/// start at all.
///
/// This is the single place a VM is born and dies. The UI, the CLI and any future
/// control plane all call through it, which is what makes resource accounting and
/// double-start refusal properties of the runtime rather than of one screen. The
/// app no longer holds an engine; it holds a reference to this.
@MainActor
public final class VMRuntimeRegistry: ObservableObject {
    /// Every machine the runtime is currently holding, keyed by configuration id.
    ///
    /// An instance stays here after a guest shuts itself down (so its last error
    /// is still visible) and is removed by an explicit `stop`. `state(of:)` is the
    /// honest way to ask "is it up?".
    @Published public private(set) var instances: [UUID: VMInstance] = [:]

    /// How often live engine state is copied into each `VMInstance`.
    ///
    /// Polling is deliberate: it is engine-agnostic, needs no second source of
    /// truth and no per-engine event plumbing, and 250 ms is imperceptible for a
    /// power state. A future hosted-engine proxy can replace it for QEMU without
    /// changing anything above this line.
    public let refreshInterval: Duration

    /// Host resources every start is checked against.
    ///
    /// `nil` means "probe the real host for every start", which is what the app
    /// uses: free disk space changes while Macport is open, and an admission
    /// decision based on launch-time numbers would eventually be a lie. Tests
    /// inject a fixed value so their numbers are the scenario's, not the Mac's.
    private let capacityOverride: HostCapacity?

    /// The capacity used by the next start.
    public var capacity: HostCapacity { capacityOverride ?? .current }

    /// Builds the engine for a configuration. Injectable so tests can run against
    /// a mock instead of a hypervisor.
    public typealias EngineFactory = @MainActor (VMConfiguration) -> any VMEngine

    /// Reports whether the engine that would host a configuration can run here.
    /// Injectable for the same reason as `engineFactory`.
    public typealias AvailabilityCheck = @MainActor (VMConfiguration) -> Result<Void, EngineError>

    private let engineFactory: EngineFactory
    private let availabilityCheck: AvailabilityCheck
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]

    /// Ids with a start in flight. `start` suspends across `engine.create` and
    /// `engine.start`, and `@MainActor` alone does not stop a second call from
    /// observing an empty `instances` mid-await. This reservation is what makes
    /// "double-start is refused" true even for two gestures in the same frame.
    private var startingIDs: Set<UUID> = []

    public init(
        capacity: HostCapacity? = nil,
        refreshInterval: Duration = .milliseconds(250),
        engineFactory: @escaping EngineFactory = { EngineRegistry.makeEngine(for: $0) },
        availabilityCheck: @escaping AvailabilityCheck = {
            EngineRegistry.engineType(for: $0).availability()
        }
    ) {
        self.capacityOverride = capacity
        self.refreshInterval = refreshInterval
        self.engineFactory = engineFactory
        self.availabilityCheck = availabilityCheck
    }

    // MARK: - Queries

    public func instance(_ id: UUID) -> VMInstance? { instances[id] }

    /// The state of a VM this registry knows about; `.stopped` for anything else.
    public func state(of id: UUID) -> VMState { instances[id]?.state ?? .stopped }

    // MARK: - Lifecycle

    /// Admit, create and boot `config`.
    ///
    /// Admission control runs here, before an engine is even instantiated, so a
    /// refused start leaves nothing half-built behind.
    public func start(_ config: VMConfiguration, in store: VMStore) async throws {
        let id = config.id

        // A start already in flight is a refusal, not a queue: the second caller
        // asked for a machine that is already coming up.
        if startingIDs.contains(id) {
            throw EngineError.operationFailed(
                "\(config.name) is already starting. Wait for it to finish or stop it first."
            )
        }
        if let existing = instances[id], existing.state.isActive {
            throw EngineError.operationFailed(
                "\(config.name) is already running on \(existing.engineName). "
                    + "Stop it before starting it again."
            )
        }

        if case .failure(let error) = availabilityCheck(config) {
            throw error
        }

        // Everything already up except this VM — a stale, stopped instance of the
        // same id must not count against its own restart.
        let running = instances.values
            .filter { $0.id != id && $0.state.isActive }
            .map(\.config)

        switch HostCapacity.check(config, running: running, capacity: capacity) {
        case .success:
            break
        case .failure(let error):
            throw error
        }

        startingIDs.insert(id)
        defer { startingIDs.remove(id) }

        let engine = engineFactory(config)
        let bundle = store.bundleURL(for: config)
        try await engine.create(config, in: bundle)
        try await engine.start(config, in: bundle)

        // A previous, naturally-shut-down run may have left a stopped instance
        // behind; this run replaces it. An *active* instance was refused above.
        let instance = VMInstance(config: config, engine: engine)
        instances[id] = instance
        startRefreshTask(for: id)
    }

    /// Power a VM off.
    ///
    /// The instance is removed only after the engine confirms the stop, so a
    /// failed graceful request keeps the UI's stop button pointed at a machine
    /// that is still up.
    public func stop(_ id: UUID, graceful: Bool) async throws {
        if startingIDs.contains(id) {
            throw EngineError.operationFailed(
                "This virtual machine is still starting. Wait for it to come up, then stop it."
            )
        }
        guard let instance = instances[id] else { return }

        if graceful {
            try await instance.engine.stop()
        } else {
            try await instance.engine.forceStop()
        }

        cancelRefreshTask(for: id)
        instances.removeValue(forKey: id)
    }

    public func pause(_ id: UUID) async throws {
        guard let instance = instances[id] else {
            throw EngineError.operationFailed("There is no running virtual machine to pause.")
        }
        // No capability pre-check here on purpose: an engine that does not
        // implement pause inherits the protocol's default implementation, which
        // throws `.unsupportedFeature` with the feature name. Duplicating the
        // policy here would let the two answers drift.
        try await instance.engine.pause()
        refreshInstance(id)
    }

    public func resume(_ id: UUID) async throws {
        guard let instance = instances[id] else {
            throw EngineError.operationFailed("There is no virtual machine to resume.")
        }
        try await instance.engine.resume()
        refreshInstance(id)
    }

    // MARK: - State refresh

    /// Copy every engine's live state into its instance.
    ///
    /// Public so a test (or a future control-plane update) can force a sync
    /// without waiting for the poll.
    public func refresh() {
        for id in Array(instances.keys) {
            refreshInstance(id)
        }
    }

    private func refreshInstance(_ id: UUID) {
        guard let instance = instances[id] else {
            cancelRefreshTask(for: id)
            return
        }

        let changed = instance.update(
            state: instance.engine.state,
            lastError: instance.engine.lastError
        )
        if changed {
            // The instance's own `objectWillChange` covers direct observers; this
            // covers observers of the registry itself (the app's facade, a future
            // sidebar). Only sent on a real change, so an idle host is not woken
            // four times a second.
            objectWillChange.send()
        }

        if !instance.engine.state.isActive {
            cancelRefreshTask(for: id)
        }
    }

    private func startRefreshTask(for id: UUID) {
        cancelRefreshTask(for: id)
        refreshTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.refreshInterval)
                guard !Task.isCancelled else { return }
                self.refreshInstance(id)
                if self.instances[id] == nil { return }
            }
        }
    }

    private func cancelRefreshTask(for id: UUID) {
        refreshTasks[id]?.cancel()
        refreshTasks[id] = nil
    }
}
