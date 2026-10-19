import Foundation

/// A `VMEngine` whose machine lives in a separate `MacportVMHost` process.
///
/// The proxy is what lets the app and the registry treat a hosted QEMU guest
/// like any other engine: state is cached from a one-second status poll, and
/// lifecycle calls are control commands. It deliberately refuses `create` and
/// `start`: the host process owns those, and a second creator would race the
/// engine that is already running.
@MainActor
public final class VMHostProxy: VMEngine {
    nonisolated public static let identifier = QEMUEngine.identifier
    nonisolated public static let displayName = QEMUEngine.displayName

    nonisolated public static func capabilities(for guest: GuestKind) -> EngineCapabilities {
        QEMUEngine.capabilities(for: guest)
    }

    nonisolated public static func availability() -> Result<Void, EngineError> {
        QEMUEngine.availability()
    }

    /// Why this instance is not a normal in-process engine, in words the UI can
    /// show next to the machine.
    public let reason = "This machine's engine runs in a separate MacportVMHost "
        + "process, so it keeps running when Macport quits. The host owns start "
        + "and stop; this app is a control client."

    public let metadata: VMHostMetadata
    public private(set) var state: VMState
    public private(set) var lastError: String?

    private let channel: any ControlChannel
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    /// Protocol-required initialiser. A proxy with no channel cannot do
    /// anything useful, so every command explains the correct construction
    /// rather than failing later with a socket error.
    public convenience init() {
        self.init(
            channel: UnavailableControlChannel(),
            metadata: VMHostMetadata(
                pid: 0,
                socketPath: "",
                startedAt: Date(),
                engineIdentifier: QEMUEngine.identifier
            ),
            polling: false
        )
    }

    /// - Parameters:
    ///   - channel: The transport. Injected so tests can answer without a socket.
    ///   - metadata: The host's published record, including its pid.
    ///   - initialState: The state already learned from a readiness or adoption
    ///     `status` call, so the first poll is not a visible flicker.
    ///   - polling: Set `false` in tests that drive `refreshNow()` themselves.
    public init(
        channel: any ControlChannel,
        metadata: VMHostMetadata,
        initialState: VMState = .running,
        pollInterval: Duration = .seconds(1),
        polling: Bool = true
    ) {
        self.channel = channel
        self.metadata = metadata
        self.state = initialState
        self.pollInterval = pollInterval

        if polling {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    try? await Task.sleep(for: self.pollInterval)
                    guard !Task.isCancelled else { return }
                    await self.refreshNow()
                }
            }
        }
    }

    // MARK: - Ownership

    public func create(_ config: VMConfiguration, in bundle: URL) async throws {
        throw EngineError.operationFailed(
            "\(config.name) is already running in the background host. "
                + "A hosted machine's bundle is created and opened by its host process."
        )
    }

    public func start(_ config: VMConfiguration, in bundle: URL) async throws {
        throw EngineError.operationFailed(
            "\(config.name) is already running in the background host. "
                + "Stop the host before starting it again."
        )
    }

    public func stop() async throws {
        state = .stopping
        do {
            _ = try await perform(.shutdownHost)
            state = .stopped
        } catch {
            // If the host exited while answering, the stop succeeded in the only
            // way that matters; a missing socket is not a failed shutdown.
            if !VMHostRuntime.isProcessAlive(pid: metadata.pid) {
                state = .stopped
                return
            }
            state = .running
            lastError = error.localizedDescription
            throw error
        }
    }

    public func forceStop() async throws {
        state = .stopping
        _ = try? await perform(.stop(graceful: false))
        do {
            _ = try await perform(.shutdownHost)
            state = .stopped
        } catch {
            if VMHostRuntime.isProcessAlive(pid: metadata.pid) {
                state = .error
                lastError = error.localizedDescription
                throw error
            }
            state = .stopped
        }
    }

    // MARK: - Machine control

    public func pause() async throws {
        _ = try await perform(.pause)
        state = .paused
        lastError = nil
    }

    public func resume() async throws {
        _ = try await perform(.resume)
        state = .running
        lastError = nil
    }

    public func listSnapshots() async throws -> [VMSnapshot] {
        let response = try await perform(.snapshots)
        guard case .snapshots(let snapshots)? = response.payload else {
            throw EngineError.operationFailed(
                "The background host returned no snapshot list. Update Macport "
                    + "so the host and app are the same build."
            )
        }
        return snapshots
    }

    public func takeSnapshot(named name: String) async throws -> VMSnapshot {
        let response = try await perform(.takeSnapshot(name: name))
        guard case .snapshot(let snapshot)? = response.payload else {
            throw EngineError.operationFailed(
                "The background host did not return the snapshot it created."
            )
        }
        return snapshot
    }

    public func restoreSnapshot(id: String) async throws {
        _ = try await perform(.restoreSnapshot(id: id))
    }

    public func deleteSnapshot(id: String) async throws {
        _ = try await perform(.deleteSnapshot(id: id))
    }

    // MARK: - Status

    /// Ask the host for status and copy it into the cached properties.
    ///
    /// Errors are recorded rather than thrown: this is called by a poll, and a
    /// transient refusal must not turn into a modal error. A dead pid is
    /// distinguished from a busy host so the registry can stop polling a machine
    /// that is genuinely gone.
    public func refreshNow() async {
        do {
            let status = try await fetchStatus()
            state = status.paused ? .paused : status.state
            lastError = nil
            consecutiveFailures = 0
        } catch {
            lastError = error.localizedDescription
            consecutiveFailures += 1
            if !VMHostRuntime.isProcessAlive(pid: metadata.pid) {
                state = .stopped
            } else if consecutiveFailures >= 3 {
                state = .error
            }
        }
    }

    public func fetchStatus() async throws -> VMControlStatus {
        let response = try await channel.send(VMControlRequest(command: .status))
        guard response.ok else {
            throw EngineError.operationFailed(
                response.error ?? "The background host refused a status request."
            )
        }
        guard case .status(let status)? = response.payload else {
            throw EngineError.operationFailed(
                "The background host returned a status reply without a status payload."
            )
        }
        return status
    }

    // MARK: - Plumbing

    private func perform(_ command: VMControlCommand) async throws -> VMControlResponse {
        let response: VMControlResponse
        do {
            response = try await channel.send(VMControlRequest(command: command))
        } catch {
            throw EngineError.operationFailed(error.localizedDescription)
        }
        guard response.ok else {
            throw EngineError.operationFailed(
                response.error ?? "The background host refused `\(command.name)`."
            )
        }
        return response
    }
}

/// The channel behind `init()`, which the `VMEngine` protocol requires but no
/// caller should use. Every request fails with the construction rule.
private final class UnavailableControlChannel: ControlChannel, @unchecked Sendable {
    func send(_ request: VMControlRequest) async throws -> VMControlResponse {
        throw EngineError.operationFailed(
            "VMHostProxy must be created with a control channel; the parameterless "
                + "initialiser exists only because the VMEngine protocol requires it."
        )
    }
}
