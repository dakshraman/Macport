import XCTest
import MacportKit

/// A `ControlChannel` that answers from a closure and records what it was asked.
///
/// An actor because the proxy calls it from the main actor and the host would
/// call it from a socket queue; the recording must not be a data race.
private actor FakeControlChannel: ControlChannel {
    private var seen: [VMControlRequest] = []
    private let handler: @Sendable (VMControlRequest) async throws -> VMControlResponse

    init(
        handler: @escaping @Sendable (VMControlRequest) async throws -> VMControlResponse
            = { request in .success(id: request.id) }
    ) {
        self.handler = handler
    }

    func send(_ request: VMControlRequest) async throws -> VMControlResponse {
        seen.append(request)
        return try await handler(request)
    }

    func commands() -> [VMControlCommand] {
        seen.map(\.command)
    }

    func count() -> Int {
        seen.count
    }
}

/// The proxy's job is translation, measured here without a socket.
///
/// Every test drives `refreshNow()` or a lifecycle call and then asserts on
/// (a) the commands the proxy sent and (b) the cached state it exposes to the
/// registry and the UI. Polling is off: a test that raced a one-second poll
/// would be reporting the poll, not the call under test.
/// File-scope so the `@Sendable` fake-channel closures do not capture the
/// main-actor test class just to build a payload.
private func proxyStatus(
    state: VMState = .running,
    paused: Bool = false
) -> VMControlStatus {
    VMControlStatus(
        state: state,
        pid: getpid(),
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        engineIdentifier: QEMUEngine.identifier,
        paused: paused
    )
}

@MainActor
final class VMHostProxyTests: XCTestCase {

    private func metadata(pid: Int32 = getpid()) -> VMHostMetadata {
        VMHostMetadata(
            pid: pid,
            socketPath: "/tmp/macport-proxy-test.control",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            engineIdentifier: QEMUEngine.identifier
        )
    }

    private func makeProxy(
        channel: FakeControlChannel,
        pid: Int32 = getpid(),
        state: VMState = .running
    ) -> VMHostProxy {
        VMHostProxy(
            channel: channel,
            metadata: metadata(pid: pid),
            initialState: state,
            polling: false
        )
    }

    // MARK: - Status

    func testRefreshCopiesTheStatusIntoTheCachedState() async {
        let channel = FakeControlChannel { request in
            .success(id: request.id, payload: .status(proxyStatus(state: .paused, paused: true)))
        }
        let proxy = makeProxy(channel: channel, state: .starting)

        await proxy.refreshNow()

        XCTAssertEqual(proxy.state, .paused)
        XCTAssertNil(proxy.lastError)
        let commands = await channel.commands()
        XCTAssertEqual(commands, [.status])
    }

    func testRefreshPrefersThePausedFlagOverTheState() async {
        // A host mid-snapshot can report `state: .running` with `paused: true`;
        // the flag is the truth the UI must show.
        let channel = FakeControlChannel { request in
            .success(id: request.id, payload: .status(proxyStatus(state: .running, paused: true)))
        }
        let proxy = makeProxy(channel: channel)

        await proxy.refreshNow()

        XCTAssertEqual(proxy.state, .paused)
    }

    func testThreeConsecutiveFailuresBecomeTheErrorState() async {
        let channel = FakeControlChannel { _ in
            throw VMControlError.socketMissing("/tmp/gone.control")
        }
        let proxy = makeProxy(channel: channel)

        await proxy.refreshNow()
        XCTAssertEqual(proxy.state, .running, "One transient failure must not flip the UI")
        XCTAssertNotNil(proxy.lastError)

        await proxy.refreshNow()
        XCTAssertEqual(proxy.state, .running)

        await proxy.refreshNow()
        XCTAssertEqual(proxy.state, .error)
    }

    func testRefreshFailsFastWhenTheRecordedPidIsGone() async {
        // pid 0 can never be alive, so the first failure is the machine being
        // gone, not a busy host: no three-strike patience applies.
        let channel = FakeControlChannel { _ in
            throw VMControlError.socketMissing("/tmp/gone.control")
        }
        let proxy = makeProxy(channel: channel, pid: 0)

        await proxy.refreshNow()

        XCTAssertEqual(proxy.state, .stopped)
    }

    func testASuccessfulRefreshClearsAPreviousError() async {
        let failing = FakeControlChannel { _ in
            throw VMControlError.socketMissing("/tmp/gone.control")
        }
        let proxy = makeProxy(channel: failing)
        await proxy.refreshNow()
        XCTAssertNotNil(proxy.lastError)

        // A second proxy shares the same idea; the first proves the failure was
        // visible, this proves success clears it.
        let healthy = FakeControlChannel { request in
            .success(id: request.id, payload: .status(proxyStatus()))
        }
        let good = makeProxy(channel: healthy)
        await good.refreshNow()
        XCTAssertNil(good.lastError)
        XCTAssertEqual(good.state, .running)
    }

    // MARK: - Lifecycle

    func testPauseAndResumeSendTheirCommandsAndUpdateState() async throws {
        let channel = FakeControlChannel()
        let proxy = makeProxy(channel: channel)

        try await proxy.pause()
        XCTAssertEqual(proxy.state, .paused)

        try await proxy.resume()
        XCTAssertEqual(proxy.state, .running)

        let commands = await channel.commands()
        XCTAssertEqual(commands, [.pause, .resume])
    }

    func testStopSendsShutdownHost() async throws {
        let channel = FakeControlChannel()
        let proxy = makeProxy(channel: channel)

        try await proxy.stop()

        XCTAssertEqual(proxy.state, .stopped)
        let commands = await channel.commands()
        XCTAssertEqual(commands, [.shutdownHost])
    }

    func testStopSucceedsWhenTheHostIsAlreadyGone() async throws {
        // The socket is gone and the pid is dead: the stop achieved everything
        // a stop can, so it must not throw.
        let channel = FakeControlChannel { _ in
            throw VMControlError.socketMissing("/tmp/gone.control")
        }
        let proxy = makeProxy(channel: channel, pid: 0)

        try await proxy.stop()

        XCTAssertEqual(proxy.state, .stopped)
    }

    func testForceStopStopsThenShutsDownTheHost() async throws {
        let channel = FakeControlChannel()
        let proxy = makeProxy(channel: channel)

        try await proxy.forceStop()

        XCTAssertEqual(proxy.state, .stopped)
        let commands = await channel.commands()
        XCTAssertEqual(commands, [.stop(graceful: false), .shutdownHost])
    }

    func testAFailedShutdownWhileTheHostIsAlivePropagates() async {
        let channel = FakeControlChannel { request in
            if case .shutdownHost = request.command {
                throw VMControlError.connectionRefused(path: "/tmp/x", detail: "busy")
            }
            return .success(id: request.id)
        }
        let proxy = makeProxy(channel: channel)

        do {
            try await proxy.stop()
            XCTFail("Expected the refused shutdown to throw")
        } catch {
            XCTAssertEqual(proxy.state, .running)
            XCTAssertNotNil(proxy.lastError)
        }
    }

    // MARK: - Snapshots

    func testSnapshotCommandsCarryTheirArgumentsAndDecodeTheirPayloads() async throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let channel = FakeControlChannel { request in
            switch request.command {
            case .snapshots:
                return .success(
                    id: request.id,
                    payload: .snapshots([
                        VMSnapshot(id: "clean", name: "clean", createdAt: created),
                        VMSnapshot(id: "before-update", name: "Before update", createdAt: created, includesMemory: true),
                    ])
                )
            case .takeSnapshot(let name):
                return .success(
                    id: request.id,
                    payload: .snapshot(VMSnapshot(id: name, name: name, createdAt: created, includesMemory: true))
                )
            default:
                return .success(id: request.id)
            }
        }
        let proxy = makeProxy(channel: channel)

        let listed = try await proxy.listSnapshots()
        XCTAssertEqual(listed.map(\.id), ["clean", "before-update"])
        XCTAssertEqual(listed.map(\.includesMemory), [false, true])

        let taken = try await proxy.takeSnapshot(named: "Before update")
        XCTAssertEqual(taken.id, "Before update")
        XCTAssertTrue(taken.includesMemory)

        try await proxy.restoreSnapshot(id: "before-update")
        try await proxy.deleteSnapshot(id: "before-update")

        let commands = await channel.commands()
        XCTAssertEqual(commands, [
            .snapshots,
            .takeSnapshot(name: "Before update"),
            .restoreSnapshot(id: "before-update"),
            .deleteSnapshot(id: "before-update"),
        ])
    }

    func testAPayloadOfTheWrongShapeIsAnActionableError() async {
        // A host from a different build answering with the wrong shape must not
        // crash the app; the message says to align the builds.
        let channel = FakeControlChannel { request in
            .success(id: request.id, payload: .snapshot(VMSnapshot(id: "x", name: "x")))
        }
        let proxy = makeProxy(channel: channel)

        do {
            _ = try await proxy.listSnapshots()
            XCTFail("Expected a wrong-shaped payload to throw")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("no snapshot list"),
                error.localizedDescription
            )
        }
    }

    // MARK: - Refused operations

    func testCreateAndStartAreRefusedBecauseTheHostOwnsThem() async throws {
        let channel = FakeControlChannel()
        let proxy = makeProxy(channel: channel)
        let config = VMConfiguration(name: "Test", guest: .macOSGuest)
        let bundle = URL(fileURLWithPath: "/tmp/does-not-matter.macport")

        for operation in [
            { try await proxy.create(config, in: bundle) },
            { try await proxy.start(config, in: bundle) },
        ] {
            do {
                try await operation()
                XCTFail("Expected the proxy to refuse")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains("already running in the background host"),
                    error.localizedDescription
                )
            }
        }

        let sent = await channel.count()
        XCTAssertEqual(sent, 0, "A refusal must not reach the socket")
    }

    func testTheParameterlessInitialiserExplainsItself() async {
        let proxy = VMHostProxy()

        do {
            _ = try await proxy.fetchStatus()
            XCTFail("Expected the unavailable channel to fail")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("must be created with a control channel"),
                error.localizedDescription
            )
        }
    }

    // MARK: - Identity

    func testTheProxyPresentsItselfAsTheQEMUEngine() {
        XCTAssertEqual(VMHostProxy.identifier, QEMUEngine.identifier)
        XCTAssertEqual(VMHostProxy.displayName, QEMUEngine.displayName)
        XCTAssertEqual(
            VMHostProxy.capabilities(for: .macOSGuest).snapshots,
            QEMUEngine.capabilities(for: .macOSGuest).snapshots
        )
    }
}
