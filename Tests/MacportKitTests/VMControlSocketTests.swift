import XCTest
import MacportKit

/// A real listener and a real client on a real unix socket.
///
/// The protocol round-trips are tested as values elsewhere; these tests prove
/// the transport: two commands in sequence on separate connections, a reply
/// whose id the handler got wrong being corrected, `stop()` unlinking the path,
/// a live listener refusing a second bind, and a slow handler timing the client
/// out instead of hanging it.
final class VMControlSocketTests: XCTestCase {

    /// Deliberately short: `sun_path` is 104 bytes and the tests run under a
    /// deep temporary directory.
    private func shortSocketPath() -> String {
        "/tmp/macport-test-" + UUID().uuidString.prefix(8) + ".control"
    }

    private func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Round trips

    func testTwoSequentialCommandsRoundTripOnSeparateConnections() async throws {
        let path = shortSocketPath()
        defer { remove(path) }

        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let server = VMControlServer(socketPath: path) { request in
            switch request.command {
            case .status:
                return VMControlResponse.success(
                    // A deliberately wrong id: the server must stamp the
                    // request's id on the reply regardless of the handler.
                    id: UUID(),
                    payload: .status(
                        VMControlStatus(
                            state: .paused,
                            pid: 999,
                            startedAt: started,
                            engineIdentifier: QEMUEngine.identifier,
                            paused: true
                        )
                    )
                )
            case .takeSnapshot(let name):
                return VMControlResponse.success(
                    id: request.id,
                    payload: .snapshot(VMSnapshot(id: "snap-1", name: name, includesMemory: true))
                )
            default:
                return .failure(id: request.id, error: "unexpected \(request.command.name)")
            }
        }
        try server.start()
        defer { server.stop() }

        let client = VMControlClient(socketPath: path, connectTimeout: 2, commandTimeout: 5)

        let statusRequest = VMControlRequest(command: .status)
        let statusResponse = try await client.send(statusRequest)
        XCTAssertTrue(statusResponse.ok, statusResponse.error ?? "")
        XCTAssertEqual(statusResponse.id, statusRequest.id)
        guard case .status(let status)? = statusResponse.payload else {
            return XCTFail("Expected a status payload")
        }
        XCTAssertEqual(status.pid, 999)
        XCTAssertEqual(status.state, .paused)
        XCTAssertTrue(status.paused)

        let snapshotRequest = VMControlRequest(command: .takeSnapshot(name: "Before update"))
        let snapshotResponse = try await client.send(snapshotRequest)
        XCTAssertEqual(snapshotResponse.id, snapshotRequest.id)
        guard case .snapshot(let snapshot)? = snapshotResponse.payload else {
            return XCTFail("Expected a snapshot payload")
        }
        XCTAssertEqual(snapshot.name, "Before update")
        XCTAssertEqual(snapshot.id, "snap-1")
    }

    func testTheSocketFileIsPrivateToTheUser() throws {
        let path = shortSocketPath()
        defer { remove(path) }

        let server = VMControlServer(socketPath: path) { request in
            .success(id: request.id)
        }
        try server.start()
        defer { server.stop() }

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - Lifecycle

    func testStopUnlinksTheSocketAndFurtherConnectionsFail() async throws {
        let path = shortSocketPath()
        defer { remove(path) }

        let server = VMControlServer(socketPath: path) { request in
            .success(id: request.id)
        }
        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        server.stop()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path),
            "stop() must remove the path before returning"
        )

        let client = VMControlClient(socketPath: path, connectTimeout: 1, commandTimeout: 1)
        do {
            _ = try await client.send(VMControlRequest(command: .status))
            XCTFail("Expected the removed socket to refuse the connection")
        } catch let error as VMControlError {
            guard case .socketMissing = error else {
                return XCTFail("Expected socketMissing, got \(error)")
            }
        }
    }

    func testASecondServerRefusesAndLeavesTheFirstSocketAlone() async throws {
        let path = shortSocketPath()
        defer { remove(path) }

        let first = VMControlServer(socketPath: path) { request in
            .success(id: request.id)
        }
        try first.start()
        defer { first.stop() }

        let second = VMControlServer(socketPath: path) { request in
            .success(id: request.id)
        }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? VMControlError, .addressInUse(path: path))
        }

        // The loser must not have unlinked the winner's endpoint on the way out.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let client = VMControlClient(socketPath: path, connectTimeout: 1, commandTimeout: 2)
        let response = try await client.send(VMControlRequest(command: .status))
        XCTAssertTrue(response.ok)
    }

    func testAStaleSocketFileIsReplaced() throws {
        let path = shortSocketPath()
        defer { remove(path) }

        // A socket file with no listener behind it: exactly what a crashed host
        // leaves. `start()` must reclaim it rather than refuse.
        try Data().write(to: URL(fileURLWithPath: path))
        let server = VMControlServer(socketPath: path) { request in
            .success(id: request.id)
        }
        try server.start()
        server.stop()
    }

    // MARK: - Timeouts

    func testAHandlerSlowerThanTheCommandTimeoutTimesTheClientOut() async throws {
        let path = shortSocketPath()
        defer { remove(path) }

        let server = VMControlServer(socketPath: path) { request in
            try? await Task.sleep(for: .seconds(1))
            return .success(id: request.id)
        }
        try server.start()
        defer { server.stop() }

        let client = VMControlClient(socketPath: path, connectTimeout: 1, commandTimeout: 0.25)
        do {
            _ = try await client.send(VMControlRequest(command: .status))
            XCTFail("Expected the slow handler to time out")
        } catch let error as VMControlError {
            XCTAssertEqual(error, .timedOut(command: "status"))
        }
    }

    func testConnectingToAMissingSocketNamesThePath() async {
        let path = shortSocketPath()
        let client = VMControlClient(socketPath: path, connectTimeout: 1, commandTimeout: 1)
        do {
            _ = try await client.send(VMControlRequest(command: .status))
            XCTFail("Expected a missing socket to fail")
        } catch let error as VMControlError {
            guard case .socketMissing(let reported) = error else {
                return XCTFail("Expected socketMissing, got \(error)")
            }
            XCTAssertEqual(reported, path)
        } catch {
            XCTFail("Expected a VMControlError, got \(error)")
        }
    }
}
