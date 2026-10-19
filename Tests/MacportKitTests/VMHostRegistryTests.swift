import XCTest
import MacportKit

/// Registry integration with the per-VM host.
///
/// The transport is real here (a `VMControlServer` on a short `/tmp` socket),
/// but the "host process" is either the test process or a `sleep` child whose
/// pid stands in for it. That is enough to exercise routing, adoption and the
/// wait-for-exit loop without building or launching MacportVMHost.
@MainActor
final class VMHostRegistryTests: XCTestCase {

    private func makeStore() throws -> (VMStore, URL) {
        let root = try makeTemporaryDirectory()
        let store = VMStore(root: root)
        store.load()
        return (store, root)
    }

    private func makeConfig(engine: String? = QEMUEngine.identifier) -> VMConfiguration {
        VMConfiguration(name: "Hosted", guest: .linuxARM, engineIdentifier: engine)
    }

    private func shortSocketPath() -> String {
        "/tmp/macport-registry-" + UUID().uuidString.prefix(8) + ".control"
    }

    private func statusServer(
        at path: String,
        state: VMState = .running,
        paused: Bool = false,
        onShutdown: (@Sendable () -> Void)? = nil
    ) throws -> VMControlServer {
        let server = VMControlServer(
            socketPath: path,
            handler: { request in
                switch request.command {
                case .status:
                    return .success(
                        id: request.id,
                        payload: .status(
                            VMControlStatus(
                                state: state,
                                pid: getpid(),
                                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                engineIdentifier: QEMUEngine.identifier,
                                paused: paused
                            )
                        )
                    )
                default:
                    return .success(id: request.id)
                }
            },
            onResponseSent: { request in
                if case .shutdownHost = request.command {
                    onShutdown?()
                }
            }
        )
        try server.start()
        return server
    }

    // MARK: - Start routing

    func testQEMUFallsBackToTheInProcessEngineWhenTheHostIsMissing() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = VMRuntimeRegistry(
            engineFactory: { _ in MockEngine() },
            hostAvailability: { false },
            hostStarter: { _, _ in
                throw EngineError.operationFailed("hostStarter must not be called")
            }
        )
        let config = makeConfig()

        try await registry.start(config, in: store)

        let instance = try XCTUnwrap(registry.instance(config.id))
        XCTAssertTrue(instance.engine is MockEngine)
        XCTAssertNil(instance.hostMetadata)
        try await registry.stop(config.id, graceful: true)
    }

    func testQEMUStartsInTheHostAndStopWaitsForTheProcessToExit() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = shortSocketPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // A process to stand in for the host. The control server kills it when
        // it has written the `shutdownHost` reply, which is exactly when a real
        // host begins its own shutdown.
        let host = Process()
        host.executableURL = URL(fileURLWithPath: "/bin/sleep")
        host.arguments = ["30"]
        try host.run()
        defer {
            if host.isRunning { host.terminate() }
            host.waitUntilExit()
        }
        let hostPid = host.processIdentifier

        let server = try statusServer(at: path, onShutdown: {
            kill(hostPid, SIGTERM)
        })
        defer { server.stop() }

        let config = makeConfig()
        let metadata = VMHostMetadata(
            pid: hostPid,
            socketPath: path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            engineIdentifier: QEMUEngine.identifier
        )
        let registry = VMRuntimeRegistry(
            engineFactory: { _ in MockEngine() },
            hostAvailability: { true },
            hostStarter: { config, store in
                // The real host publishes this after the guest is up; doing it
                // here also gives the stop path a record to remove.
                try VMHostRuntime.writeMetadata(metadata, in: store.bundleURL(for: config))
                return metadata
            }
        )

        try await registry.start(config, in: store)

        let instance = try XCTUnwrap(registry.instance(config.id))
        XCTAssertTrue(instance.engine is VMHostProxy)
        XCTAssertEqual(instance.hostMetadata?.pid, hostPid)
        XCTAssertEqual(instance.state, .running)
        XCTAssertTrue(instance.runsInExternalWindow)
        XCTAssertTrue(VMHostRuntime.isProcessAlive(pid: hostPid))

        try await registry.stop(config.id, graceful: true)

        XCTAssertNil(registry.instance(config.id))
        XCTAssertFalse(
            VMHostRuntime.isProcessAlive(pid: hostPid),
            "stop must not return while the host process is still running"
        )
        XCTAssertNil(VMHostRuntime.readMetadata(in: store.bundleURL(for: config)))
    }

    func testAPinnedVZMachineNeverUsesTheHostEvenWhenItIsAvailable() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = VMRuntimeRegistry(
            engineFactory: { _ in MockEngine() },
            hostAvailability: { true },
            hostStarter: { _, _ in
                throw EngineError.operationFailed("a VZ machine must not start a host")
            }
        )
        let config = makeConfig(engine: VZEngine.identifier)

        try await registry.start(config, in: store)

        let instance = try XCTUnwrap(registry.instance(config.id))
        XCTAssertTrue(instance.engine is MockEngine)
        try await registry.stop(config.id, graceful: true)
    }

    // MARK: - Adoption

    func testAdoptPublishesAProxyForALiveHost() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = shortSocketPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let config = makeConfig()
        try store.save(config)
        let bundle = store.bundleURL(for: config)
        try VMHostRuntime.writeMetadata(
            VMHostMetadata(
                pid: getpid(),
                socketPath: path,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                engineIdentifier: QEMUEngine.identifier
            ),
            in: bundle
        )

        let server = try statusServer(at: path, state: .paused, paused: true)
        defer { server.stop() }

        let registry = VMRuntimeRegistry(engineFactory: { _ in MockEngine() })
        await registry.adoptRunningHosts(in: root)

        let instance = try XCTUnwrap(registry.instance(config.id))
        XCTAssertTrue(instance.engine is VMHostProxy)
        XCTAssertEqual(instance.state, .paused)
        XCTAssertEqual(instance.hostMetadata?.pid, getpid())
        XCTAssertTrue(instance.runsInExternalWindow)
        XCTAssertEqual(instance.config.name, config.name)
    }

    func testAdoptDiscardsARecordWhosePidIsDead() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig()
        try store.save(config)
        let bundle = store.bundleURL(for: config)
        try VMHostRuntime.writeMetadata(
            VMHostMetadata(
                pid: 0,
                socketPath: shortSocketPath(),
                startedAt: Date(),
                engineIdentifier: QEMUEngine.identifier
            ),
            in: bundle
        )

        let registry = VMRuntimeRegistry(engineFactory: { _ in MockEngine() })
        await registry.adoptRunningHosts(in: root)

        XCTAssertNil(registry.instance(config.id))
        XCTAssertNil(VMHostRuntime.readMetadata(in: bundle))
    }

    func testAdoptDiscardsARecordWhoseSocketDoesNotAnswer() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig()
        try store.save(config)
        let bundle = store.bundleURL(for: config)
        try VMHostRuntime.writeMetadata(
            VMHostMetadata(
                pid: getpid(),
                socketPath: shortSocketPath(),
                startedAt: Date(),
                engineIdentifier: QEMUEngine.identifier
            ),
            in: bundle
        )

        let registry = VMRuntimeRegistry(engineFactory: { _ in MockEngine() })
        await registry.adoptRunningHosts(in: root)

        XCTAssertNil(registry.instance(config.id))
        XCTAssertNil(
            VMHostRuntime.readMetadata(in: bundle),
            "A record whose socket is silent describes no usable machine"
        )
    }

    func testAdoptDiscardsAQEMURecordInABundleThatNowRoutesToVZ() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(engine: VZEngine.identifier)
        try store.save(config)
        let bundle = store.bundleURL(for: config)
        try VMHostRuntime.writeMetadata(
            VMHostMetadata(
                pid: getpid(),
                socketPath: shortSocketPath(),
                startedAt: Date(),
                engineIdentifier: QEMUEngine.identifier
            ),
            in: bundle
        )

        let registry = VMRuntimeRegistry(engineFactory: { _ in MockEngine() })
        await registry.adoptRunningHosts(in: root)

        XCTAssertNil(registry.instance(config.id))
        XCTAssertNil(VMHostRuntime.readMetadata(in: bundle))
    }
}
