import Darwin
import XCTest
import MacportKit

/// The host's discovery record and the launcher's closed search order.
///
/// These never start a guest: `runtime.json` is a file, `isProcessAlive` is a
/// syscall on ordinary processes, and `VMHostLauncher.resolve` takes its
/// environment and executable path as parameters precisely so the search order
/// can be asserted without a build of MacportVMHost in the right place.
final class VMHostRuntimeTests: XCTestCase {

    // MARK: - runtime.json

    func testMetadataRoundTripsThroughTheRuntimeFile() throws {
        let bundle = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundle) }

        let metadata = VMHostMetadata(
            pid: 4321,
            socketPath: "/tmp/macport-test.control",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            engineIdentifier: QEMUEngine.identifier
        )
        try VMHostRuntime.writeMetadata(metadata, in: bundle)

        let loaded = try XCTUnwrap(VMHostRuntime.readMetadata(in: bundle))
        XCTAssertEqual(loaded.pid, 4321)
        XCTAssertEqual(loaded.socketPath, "/tmp/macport-test.control")
        XCTAssertEqual(loaded.engineIdentifier, QEMUEngine.identifier)
        XCTAssertEqual(
            loaded.startedAt.timeIntervalSince1970,
            metadata.startedAt.timeIntervalSince1970,
            accuracy: 1
        )

        // The atomic write leaves exactly one file: no half-written sibling.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: bundle.path),
            [VMHostRuntime.runtimeFileName]
        )
    }

    func testMissingAndCorruptRecordsBothReadAsAbsent() throws {
        let bundle = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundle) }

        XCTAssertNil(VMHostRuntime.readMetadata(in: bundle))

        try write("runtime.json", "{ not json at all", in: bundle)
        XCTAssertNil(
            VMHostRuntime.readMetadata(in: bundle),
            "A corrupt record must not be half-trusted"
        )
    }

    func testRemoveMetadataDeletesOnlyTheRecord() throws {
        let bundle = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundle) }

        try VMHostRuntime.writeMetadata(
            VMHostMetadata(pid: 1, socketPath: "s", startedAt: Date(), engineIdentifier: "qemu"),
            in: bundle
        )
        try write("disk.qcow2", "pretend payload", in: bundle)

        VMHostRuntime.removeMetadata(in: bundle)
        XCTAssertFalse(exists(VMHostRuntime.runtimeFileURL(in: bundle)))
        XCTAssertTrue(exists(bundle.appendingPathComponent("disk.qcow2")))
        XCTAssertNil(VMHostRuntime.readMetadata(in: bundle))
    }

    // MARK: - Liveness

    func testThisProcessIsAlive() {
        XCTAssertTrue(VMHostRuntime.isProcessAlive(pid: getpid()))
    }

    func testNonPositivePidsAreNeverAlive() {
        // `kill(0, 0)` targets the caller's process group, so treating it as
        // "the VM is alive" would keep a dead machine on screen forever.
        XCTAssertFalse(VMHostRuntime.isProcessAlive(pid: 0))
        XCTAssertFalse(VMHostRuntime.isProcessAlive(pid: -1))
    }

    func testAReapedChildIsReportedDead() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        XCTAssertFalse(VMHostRuntime.isProcessAlive(pid: process.processIdentifier))
    }

    // MARK: - Socket path

    func testShortBundlePathsKeepTheSocketInsideTheBundle() throws {
        // Deliberately under /tmp: `makeTemporaryDirectory()` is already close
        // to the sun_path limit, which would exercise the fallback branch.
        let bundle = URL(
            fileURLWithPath: "/tmp/macport-short-" + UUID().uuidString.prefix(8)
        )
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let path = VMHostRuntime.socketPath(for: bundle, vmID: UUID())
        XCTAssertEqual(path, bundle.appendingPathComponent("control.sock").path)
    }

    func testOverlongBundlePathsFallBackToAShortTemporarySocket() throws {
        // Longer than the 104-byte sun_path limit on its own.
        let bundle = URL(fileURLWithPath: "/tmp/macport-tests-\(String(repeating: "x", count: 200))")
        let vmID = UUID()

        let path = VMHostRuntime.socketPath(for: bundle, vmID: vmID)
        XCTAssertLessThan(
            path.utf8.count,
            VMHostRuntime.sunPathLimit,
            "A fallback path must fit sun_path: \(path)"
        )
        XCTAssertTrue(path.contains("macport-\(vmID.uuidString.prefix(8))"), path)
    }

    // MARK: - Launcher search order

    /// A shell script that exists and is executable, standing in for the host.
    @discardableResult
    private func makeExecutable(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    func testEnvironmentOverrideWinsOverEveryCandidate() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let override = try makeExecutable(at: root.appendingPathComponent("custom/MacportVMHost"))
        let sibling = try makeExecutable(at: root.appendingPathComponent("bin/MacportVMHost"))

        let resolved = try VMHostLauncher.resolve(
            environment: [VMHostLauncher.environmentKey: override.path],
            executableURL: root.appendingPathComponent("bin/Macport")
        )
        XCTAssertEqual(resolved, override)
        XCTAssertNotEqual(resolved, sibling)
    }

    func testAnInvalidEnvironmentOverrideIsAnErrorNotAFallthrough() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // A real host sits next to the executable; the override still must not
        // be skipped, because "run the build I named" is the whole contract.
        try makeExecutable(at: root.appendingPathComponent("bin/MacportVMHost"))
        let notExecutable = root.appendingPathComponent("bin/notes.txt")
        try Data("not a binary".utf8).write(to: notExecutable)

        XCTAssertThrowsError(
            try VMHostLauncher.resolve(
                environment: [VMHostLauncher.environmentKey: notExecutable.path],
                executableURL: root.appendingPathComponent("bin/Macport")
            )
        ) { error in
            XCTAssertEqual(
                error as? VMHostLaunchError,
                .environmentOverrideInvalid(path: notExecutable.path)
            )
        }

        // A directory named by the override is equally invalid.
        XCTAssertThrowsError(
            try VMHostLauncher.resolve(
                environment: [VMHostLauncher.environmentKey: root.appendingPathComponent("bin").path],
                executableURL: root.appendingPathComponent("bin/Macport")
            )
        ) { error in
            guard case .environmentOverrideInvalid? = error as? VMHostLaunchError else {
                return XCTFail("Expected environmentOverrideInvalid, got \(error)")
            }
        }
    }

    func testTheHostBesideTheExecutableIsPreferred() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let binDir = root.appendingPathComponent("bin")
        let host = try makeExecutable(at: binDir.appendingPathComponent("MacportVMHost"))
        // A second candidate the search must not prefer over a sibling.
        try makeExecutable(
            at: binDir.appendingPathComponent("Macport.app/Contents/MacOS/MacportVMHost")
        )

        XCTAssertEqual(
            try VMHostLauncher.resolve(
                environment: [:],
                executableURL: binDir.appendingPathComponent("Macport")
            ),
            host
        )
    }

    func testNotFoundNamesEveryPathThatWasTried() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binDir = root.appendingPathComponent("bin")

        XCTAssertThrowsError(
            try VMHostLauncher.resolve(
                environment: [:],
                executableURL: binDir.appendingPathComponent("Macport")
            )
        ) { error in
            guard let launchError = error as? VMHostLaunchError,
                  case .notFound(let tried) = launchError else {
                return XCTFail("Expected notFound, got \(error)")
            }
            XCTAssertEqual(tried.count, 3)
            XCTAssertEqual(tried[0], binDir.appendingPathComponent("MacportVMHost").path)
            XCTAssertEqual(
                tried[1],
                binDir.appendingPathComponent("Macport.app/Contents/MacOS/MacportVMHost").path
            )
            XCTAssertEqual(tried[2], "/Applications/Macport.app/Contents/MacOS/MacportVMHost")

            // The message is the fix: every candidate plus the two ways out.
            let message = launchError.localizedDescription
            for path in tried {
                XCTAssertTrue(message.contains(path), "Missing \(path) in:\n\(message)")
            }
            XCTAssertTrue(message.contains(VMHostLauncher.environmentKey), message)
        }
    }

    func testDerivedDataAndPathAreNeverConsulted() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // `PATH` holds an executable named like the host. A resolve with no
        // override and no sibling must still fail, not find it.
        let pathDir = root.appendingPathComponent("path-bin")
        try makeExecutable(at: pathDir.appendingPathComponent("MacportVMHost"))
        let previousPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", pathDir.path, 1)
        defer {
            if let previousPath {
                setenv("PATH", previousPath, 1)
            } else {
                unsetenv("PATH")
            }
        }

        let binDir = root.appendingPathComponent("bin")
        XCTAssertThrowsError(
            try VMHostLauncher.resolve(
                environment: [:],
                executableURL: binDir.appendingPathComponent("Macport")
            )
        ) { error in
            guard case .some(.notFound) = error as? VMHostLaunchError else {
                return XCTFail("Expected notFound, got \(error)")
            }
        }
    }
}
