import XCTest
import MacportKit

// MARK: - Mock engine

/// A `VMEngine` with no hypervisor behind it.
///
/// Used to test the registry's own rules — multi-VM state, pause/resume routing,
/// stop semantics — without starting anything. It deliberately implements only
/// the original lifecycle methods, so `pause`/`resume`/snapshot calls go through
/// the protocol's default implementations exactly as a real engine without the
/// feature would.
@MainActor
final class MockEngine: VMEngine {
    nonisolated static let identifier = "mock"
    nonisolated static let displayName = "Mock Engine"

    nonisolated static func capabilities(for guest: GuestKind) -> EngineCapabilities {
        EngineCapabilities(pauseResume: true)
    }

    private(set) var state: VMState = .stopped
    private(set) var lastError: String?

    private(set) var createCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var forceStopCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var createdBundle: URL?

    var startError: Error?

    init() {}

    func create(_ config: VMConfiguration, in bundle: URL) async throws {
        createCount += 1
        createdBundle = bundle
    }

    func start(_ config: VMConfiguration, in bundle: URL) async throws {
        if let startError {
            lastError = startError.localizedDescription
            state = .error
            throw startError
        }
        startCount += 1
        state = .running
    }

    func stop() async throws {
        stopCount += 1
        state = .stopped
    }

    func forceStop() async throws {
        forceStopCount += 1
        state = .stopped
    }

    func pause() async throws {
        pauseCount += 1
        state = .paused
    }

    func resume() async throws {
        resumeCount += 1
        state = .running
    }

    // MARK: Test-only simulation

    /// The guest powered itself off without anyone calling `stop`.
    func simulateGuestStop() {
        state = .stopped
    }

    func simulateFailure(_ message: String) {
        lastError = message
        state = .error
    }
}

/// A mock that does not implement pause/resume/snapshots at all, so the calls
/// land on the protocol's default implementations.
@MainActor
final class LifecycleOnlyMockEngine: VMEngine {
    nonisolated static let identifier = "lifecycle-only-mock"
    nonisolated static let displayName = "Lifecycle-only Mock"

    nonisolated static func capabilities(for guest: GuestKind) -> EngineCapabilities {
        EngineCapabilities()
    }

    private(set) var state: VMState = .stopped
    private(set) var lastError: String?

    init() {}

    func create(_ config: VMConfiguration, in bundle: URL) async throws {}
    func start(_ config: VMConfiguration, in bundle: URL) async throws { state = .running }
    func stop() async throws { state = .stopped }
    func forceStop() async throws { state = .stopped }
}

// MARK: - Tests

@MainActor
final class RuntimeRegistryTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024

    // MARK: - Fixtures

    private func makeStore() throws -> VMStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macport-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return VMStore(root: root)
    }

    private func config(name: String, memoryGB: UInt64 = 4, cpus: Int = 2) -> VMConfiguration {
        VMConfiguration(
            name: name,
            guest: .linuxARM,
            cpuCount: cpus,
            memoryBytes: memoryGB * gib,
            diskBytes: 64 * gib
        )
    }

    /// A host big enough that admission never interferes with a lifecycle test.
    private var roomyCapacity: HostCapacity {
        HostCapacity(
            physicalMemory: 256 * gib,
            processorCount: 32,
            freeDiskBytes: 1024 * gib
        )
    }

    private func makeRegistry(
        capacity: HostCapacity? = nil,
        engineFactory: @escaping VMRuntimeRegistry.EngineFactory = { _ in MockEngine() }
    ) -> VMRuntimeRegistry {
        VMRuntimeRegistry(
            capacity: capacity ?? roomyCapacity,
            refreshInterval: .milliseconds(20),
            engineFactory: engineFactory,
            availabilityCheck: { _ in .success(()) }
        )
    }

    private func engine(of id: UUID, in registry: VMRuntimeRegistry) throws -> MockEngine {
        try XCTUnwrap(registry.instance(id)?.engine as? MockEngine)
    }

    // MARK: - Multi-VM lifecycle

    func testTwoVMsStartAndReportIndependentState() async throws {
        let store = try makeStore()
        let registry = makeRegistry()
        let a = config(name: "A")
        let b = config(name: "B")

        try await registry.start(a, in: store)
        try await registry.start(b, in: store)

        XCTAssertEqual(registry.instances.count, 2)
        XCTAssertEqual(registry.state(of: a.id), .running)
        XCTAssertEqual(registry.state(of: b.id), .running)

        let engineA = try engine(of: a.id, in: registry)
        let engineB = try engine(of: b.id, in: registry)
        XCTAssertEqual(engineA.startCount, 1)
        XCTAssertEqual(engineB.startCount, 1)
        XCTAssertEqual(engineA.createdBundle, store.bundleURL(for: a))
        XCTAssertNotEqual(engineA.createdBundle, engineB.createdBundle)

        // A mock engine is in-process: it never opens its own window.
        XCTAssertFalse(registry.instance(a.id)?.runsInExternalWindow ?? true)
        XCTAssertEqual(registry.instance(a.id)?.engineName, MockEngine.displayName)

        try await registry.stop(a.id, graceful: true)
        try await registry.stop(b.id, graceful: true)
    }

    func testStopRemovesOnlyItsOwnInstance() async throws {
        let store = try makeStore()
        let registry = makeRegistry()
        let a = config(name: "A")
        let b = config(name: "B")

        try await registry.start(a, in: store)
        try await registry.start(b, in: store)
        let engineA = try engine(of: a.id, in: registry)
        let engineB = try engine(of: b.id, in: registry)

        try await registry.stop(a.id, graceful: true)

        XCTAssertEqual(engineA.stopCount, 1)
        XCTAssertEqual(engineB.stopCount, 0)
        XCTAssertNil(registry.instance(a.id))
        XCTAssertEqual(registry.state(of: a.id), .stopped)
        XCTAssertEqual(registry.state(of: b.id), .running)

        try await registry.stop(b.id, graceful: false)
        XCTAssertNil(registry.instance(b.id))
    }

    func testForceStopUsesTheEngineForcePath() async throws {
        let store = try makeStore()
        let registry = makeRegistry()
        let a = config(name: "A")

        try await registry.start(a, in: store)
        let engine = try engine(of: a.id, in: registry)

        try await registry.stop(a.id, graceful: false)
        XCTAssertEqual(engine.forceStopCount, 1)
        XCTAssertEqual(engine.stopCount, 0)
    }

    func testDoubleStartIsRefused() async throws {
        let store = try makeStore()
        let registry = makeRegistry()
        let a = config(name: "A")

        try await registry.start(a, in: store)

        do {
            try await registry.start(a, in: store)
            XCTFail("A second start of the same VM must be refused")
        } catch let error as EngineError {
            guard case .operationFailed(let detail) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("already running"), detail)
        }

        XCTAssertEqual(registry.instances.count, 1)
        try await registry.stop(a.id, graceful: true)
    }

    // MARK: - Pause and resume

    func testPauseAndResumeAffectOnlyTheTargetVM() async throws {
        let store = try makeStore()
        let registry = makeRegistry()
        let a = config(name: "A")
        let b = config(name: "B")

        try await registry.start(a, in: store)
        try await registry.start(b, in: store)

        try await registry.pause(a.id)
        XCTAssertEqual(registry.state(of: a.id), .paused)
        XCTAssertEqual(registry.state(of: b.id), .running)
        XCTAssertEqual(try engine(of: a.id, in: registry).pauseCount, 1)
        XCTAssertEqual(try engine(of: b.id, in: registry).pauseCount, 0)

        try await registry.resume(a.id)
        XCTAssertEqual(registry.state(of: a.id), .running)
        XCTAssertEqual(try engine(of: a.id, in: registry).resumeCount, 1)

        try await registry.stop(a.id, graceful: true)
        try await registry.stop(b.id, graceful: true)
    }

    func testPauseOnAnUnknownVMIsRefused() async {
        let registry = makeRegistry()
        do {
            try await registry.pause(UUID())
            XCTFail("Pausing a VM that is not running must fail")
        } catch let error as EngineError {
            guard case .operationFailed = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }
        } catch {
            XCTFail("Expected an EngineError, got \(error)")
        }
    }

    func testUnsupportedPauseFallsThroughToTheProtocolDefault() async throws {
        let store = try makeStore()
        let registry = makeRegistry(engineFactory: { _ in LifecycleOnlyMockEngine() })
        let a = config(name: "A")

        try await registry.start(a, in: store)
        do {
            try await registry.pause(a.id)
            XCTFail("An engine without pause must throw")
        } catch let error as EngineError {
            guard case .unsupportedFeature(let feature) = error else {
                return XCTFail("Expected unsupportedFeature, got \(error)")
            }
            XCTAssertTrue(feature.contains("pause"), feature)
        }

        do {
            _ = try await registry.instance(a.id)?.engine.listSnapshots()
            XCTFail("An engine without snapshots must throw")
        } catch let error as EngineError {
            guard case .unsupportedFeature = error else {
                return XCTFail("Expected unsupportedFeature, got \(error)")
            }
        }

        try await registry.stop(a.id, graceful: true)
    }

    // MARK: - Refresh

    func testRefreshCopiesEngineStateAndErrorIntoTheInstance() async throws {
        let store = try makeStore()
        let registry = makeRegistry()
        let a = config(name: "A")

        try await registry.start(a, in: store)
        let engine = try engine(of: a.id, in: registry)

        engine.simulateFailure("guest triple-faulted")
        registry.refresh()

        XCTAssertEqual(registry.state(of: a.id), .error)
        XCTAssertEqual(registry.instance(a.id)?.lastError, "guest triple-faulted")

        // The polling task stops for a machine that is no longer active, but the
        // instance stays so the error is visible.
        XCTAssertNotNil(registry.instance(a.id))
        try await registry.stop(a.id, graceful: true)
    }

    func testANaturallyStoppedVMCanBeStartedAgain() async throws {
        let store = try makeStore()
        let registry = makeRegistry()
        let a = config(name: "A")

        try await registry.start(a, in: store)
        let first = try engine(of: a.id, in: registry)

        first.simulateGuestStop()
        registry.refresh()
        XCTAssertEqual(registry.state(of: a.id), .stopped)

        // An inactive instance must not count as a double start.
        try await registry.start(a, in: store)
        XCTAssertEqual(registry.state(of: a.id), .running)
        XCTAssertEqual(try engine(of: a.id, in: registry).startCount, 1)

        try await registry.stop(a.id, graceful: true)
    }

    func testPollingRefreshesStateWithoutAManualCall() async throws {
        let store = try makeStore()
        let registry = makeRegistry()
        let a = config(name: "A")

        try await registry.start(a, in: store)
        let engine = try engine(of: a.id, in: registry)
        engine.simulateFailure("died on its own")

        // The registry polls every 20 ms in tests; 200 ms is ample.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(registry.state(of: a.id), .error)
        XCTAssertEqual(registry.instance(a.id)?.lastError, "died on its own")

        try await registry.stop(a.id, graceful: true)
    }

    // MARK: - Admission

    func testAdmissionDenialPreventsTheEngineFromBeingCreated() async throws {
        let store = try makeStore()
        let counter = CallCounter()
        let registry = makeRegistry(
            capacity: HostCapacity(
                physicalMemory: 8 * gib,
                processorCount: 8,
                freeDiskBytes: 512 * gib
            ),
            engineFactory: { _ in
                counter.increment()
                return MockEngine()
            }
        )
        // 8 GB host: 2 GB reserved, 6 GB usable; an 8 GB guest cannot start.
        let a = config(name: "Too big", memoryGB: 8)

        do {
            try await registry.start(a, in: store)
            XCTFail("An overcommitted start must be refused")
        } catch let error as EngineError {
            guard case .hostResourceUnavailable(let detail) = error else {
                return XCTFail("Expected hostResourceUnavailable, got \(error)")
            }
            XCTAssertTrue(detail.contains("6 GB"), detail)
        }

        XCTAssertTrue(registry.instances.isEmpty)
        XCTAssertEqual(counter.count, 0, "No engine may be built for a refused start")
    }

    func testAdmissionCountsRunningVMsButNotTheStoppedInstanceBeingRestarted() async throws {
        let store = try makeStore()
        // 16 GB host: 2 GB reserved, 14 GB usable.
        let registry = makeRegistry(
            capacity: HostCapacity(
                physicalMemory: 16 * gib,
                processorCount: 8,
                freeDiskBytes: 512 * gib
            )
        )
        let a = config(name: "A", memoryGB: 7)
        let b = config(name: "B", memoryGB: 7)

        try await registry.start(a, in: store)

        // B's 7 GB on top of A's 7 GB is exactly the 14 GB usable, so it fits...
        try await registry.start(b, in: store)
        XCTAssertEqual(registry.instances.count, 2)
        // ...and a third would not.
        do {
            try await registry.start(config(name: "C", memoryGB: 1), in: store)
            XCTFail("A third VM must be refused")
        } catch let error as EngineError {
            guard case .hostResourceUnavailable = error else {
                return XCTFail("Expected hostResourceUnavailable, got \(error)")
            }
        }

        try await registry.stop(a.id, graceful: true)
        try await registry.stop(b.id, graceful: true)
    }

    func testStartFailureLeavesNoInstanceBehind() async throws {
        let store = try makeStore()
        let registry = makeRegistry()
        let a = config(name: "A")

        let engine = MockEngine()
        engine.startError = EngineError.operationFailed("firmware rejected the disk")
        let failing = makeRegistry(engineFactory: { _ in engine })

        do {
            try await failing.start(a, in: store)
            XCTFail("A failed start must throw")
        } catch let error as EngineError {
            guard case .operationFailed = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }
        }
        XCTAssertNil(failing.instance(a.id))
        XCTAssertTrue(failing.instances.isEmpty)

        // The same id can be retried after a failure.
        try await registry.start(a, in: store)
        XCTAssertEqual(registry.state(of: a.id), .running)
        try await registry.stop(a.id, graceful: true)
    }
}

/// Counts factory invocations across closure boundaries without exchanging
/// non-Sendable state.
@MainActor
private final class CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
