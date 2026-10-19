import Foundation
import XCTest
@testable import MacportKit

// MARK: - Fake server

/// A one-shot QMP server speaking the real wire protocol over a unix socket.
///
/// Tests run against bytes rather than a protocol mock: the greeting, the
/// handshake and the command framing are all checked exactly as QEMU would
/// exchange them, which is what makes the timeout and framing tests meaningful.
final class FakeQMPServer: @unchecked Sendable {
    let path: String

    private let listenDescriptor: Int32
    private let work = DispatchQueue(label: "com.dakshraman.macport.tests.fake-qmp")
    private let lock = NSLock()
    private var recorded: [String] = []

    /// Every line the client sent, in order.
    var receivedLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Start a server that accepts one connection and hands it to `script`.
    init(script: @escaping @Sendable (FakeQMPConnection) -> Void) throws {
        let name = "macport-qmp-\(UUID().uuidString.prefix(8)).sock"
        let socketPath = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        path = socketPath
        precondition(socketPath.utf8.count < 104, "test socket path must fit the kernel's sun_path limit")

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }

        unlink(socketPath)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = socketPath.withCString { strncpy(destination, $0, capacity - 1) }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            let code = errno
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil)
        }
        listenDescriptor = descriptor

        work.async { [self] in
            let client = accept(listenDescriptor, nil, nil)
            guard client >= 0 else { return }
            let connection = FakeQMPConnection(descriptor: client) { [weak self] line in
                guard let self else { return }
                lock.lock()
                recorded.append(line)
                lock.unlock()
            }
            script(connection)
            close(client)
            unlink(path)
        }
    }
}

/// The accepted end of a `FakeQMPServer`, with line framing like QMP's.
final class FakeQMPConnection: @unchecked Sendable {
    private let descriptor: Int32
    private var buffer = Data()
    private let record: @Sendable (String) -> Void

    init(descriptor: Int32, record: @escaping @Sendable (String) -> Void) {
        self.descriptor = descriptor
        self.record = record
    }

    /// Send one newline-terminated JSON line.
    func send(_ line: String) {
        var bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(descriptor, base.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    /// One line from the client, recorded for later assertions.
    ///
    /// Returns `nil` on timeout or when the peer closes, so a misbehaving
    /// client fails the test instead of hanging it.
    @discardableResult
    func readLine(timeout: TimeInterval = 5) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<index])
                buffer.removeSubrange(buffer.startIndex...index)
                let text = String(decoding: line, as: UTF8.self)
                record(text)
                return text
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }

            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min(max(remaining * 1000, 1), Double(Int32.max)).rounded(.up))
            let polled = poll(&entry, 1, milliseconds)
            if polled == 0 { return nil }
            if polled < 0 {
                if errno == EINTR { continue }
                return nil
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                return nil
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                return nil
            }
        }
    }
}

// MARK: - Tests

final class QMPClientTests: XCTestCase {
    private static let greeting =
        #"{"QMP": {"version": {"qemu": {"major": 9, "minor": 2, "micro": 0}}, "capabilities": []}}"#

    // MARK: Handshake and framing

    func testHandshakeAndCommandFraming() async throws {
        let server = try FakeQMPServer { connection in
            connection.send(Self.greeting)
            guard connection.readLine() != nil else { return }
            connection.send(#"{"return": {}}"#)
            guard connection.readLine() != nil else { return }
            connection.send(#"{"return": {}}"#)
            guard connection.readLine() != nil else { return }
            connection.send(#"{"return": "There is no snapshot available.\n"}"#)
        }

        let client = QMPClient(path: server.path, connectTimeout: 2, commandTimeout: 2)
        try await client.connect()

        let stop = try await client.execute("stop")
        XCTAssertEqual(stop, .object([:]))

        let listed = try await client.execute(
            "human-monitor-command",
            arguments: ["command-line": .string("info snapshots")]
        )
        XCTAssertEqual(listed.stringValue, "There is no snapshot available.\n")

        let lines = await waitForLines(server, count: 3)
        XCTAssertEqual(lines.count, 3, "exactly the handshake and two commands should be sent")

        let handshake = try json(lines[0])
        XCTAssertEqual(handshake["execute"] as? String, "qmp_capabilities")
        XCTAssertNil(handshake["arguments"])

        let stopCommand = try json(lines[1])
        XCTAssertEqual(stopCommand["execute"] as? String, "stop")
        XCTAssertNil(stopCommand["arguments"], "no arguments key belongs on a command that has none")

        let monitor = try json(lines[2])
        XCTAssertEqual(monitor["execute"] as? String, "human-monitor-command")
        let arguments = try XCTUnwrap(monitor["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["command-line"] as? String, "info snapshots")

        client.disconnect()
    }

    // MARK: Error and event handling

    func testErrorResponseBecomesCommandFailure() async throws {
        let server = try FakeQMPServer { connection in
            connection.send(Self.greeting)
            guard connection.readLine() != nil else { return }
            connection.send(#"{"return": {}}"#)
            guard connection.readLine() != nil else { return }
            connection.send(#"{"error": {"class": "GenericError", "desc": "no snapshot with tag 'clean'"}}"#)
        }

        let client = QMPClient(path: server.path, connectTimeout: 2, commandTimeout: 2)
        try await client.connect()

        do {
            _ = try await client.execute("human-monitor-command", arguments: ["command-line": .string("loadvm clean")])
            XCTFail("a QMP error response must throw")
        } catch let error as QMPError {
            guard case .commandFailed(let command, let errorClass, let description) = error else {
                return XCTFail("unexpected QMP error: \(error)")
            }
            XCTAssertEqual(command, "human-monitor-command")
            XCTAssertEqual(errorClass, "GenericError")
            XCTAssertEqual(description, "no snapshot with tag 'clean'")
        }

        client.disconnect()
    }

    func testAsynchronousEventsAreIgnoredWhileWaitingForAReturn() async throws {
        let server = try FakeQMPServer { connection in
            connection.send(Self.greeting)
            guard connection.readLine() != nil else { return }
            connection.send(#"{"return": {}}"#)
            guard connection.readLine() != nil else { return }
            connection.send(#"{"event": "RESUME", "timestamp": {"seconds": 1, "microseconds": 0}}"#)
            connection.send(#"{"event": "STOP", "timestamp": {"seconds": 2, "microseconds": 0}}"#)
            connection.send(#"{"return": {"status": "paused", "running": false}}"#)
        }

        let client = QMPClient(path: server.path, connectTimeout: 2, commandTimeout: 2)
        try await client.connect()

        let status = try await client.execute("query-status")
        XCTAssertEqual(status["status"]?.stringValue, "paused")
        XCTAssertEqual(status["running"]?.boolValue, false)

        client.disconnect()
    }

    // MARK: Failure paths

    func testCommandTimeoutTearsDownTheConnection() async throws {
        let server = try FakeQMPServer { connection in
            connection.send(Self.greeting)
            guard connection.readLine() != nil else { return }
            connection.send(#"{"return": {}}"#)
            guard connection.readLine() != nil else { return }
            // Never answer the next command; wait for the client to hang up.
            _ = connection.readLine(timeout: 5)
        }

        let client = QMPClient(path: server.path, connectTimeout: 2, commandTimeout: 0.25)
        try await client.connect()

        do {
            _ = try await client.execute("query-status")
            XCTFail("a command that is never answered must time out")
        } catch let error as QMPError {
            guard case .timedOut(let command) = error else {
                return XCTFail("unexpected QMP error: \(error)")
            }
            XCTAssertEqual(command, "query-status")
        }

        // A timed-out stream is out of step, so the client refuses to reuse it
        // rather than handing the next command someone else's reply.
        do {
            _ = try await client.execute("query-status")
            XCTFail("a torn-down connection must refuse further commands")
        } catch let error as QMPError {
            guard case .notConnected = error else {
                return XCTFail("unexpected QMP error: \(error)")
            }
        }

        client.disconnect()
    }

    func testServerClosingMidCommandSurfacesDisconnection() async throws {
        let server = try FakeQMPServer { connection in
            connection.send(Self.greeting)
            guard connection.readLine() != nil else { return }
            connection.send(#"{"return": {}}"#)
            guard connection.readLine() != nil else { return }
            // The script ends here: the server hangs up without replying.
        }

        let client = QMPClient(path: server.path, connectTimeout: 2, commandTimeout: 2)
        try await client.connect()

        do {
            _ = try await client.execute("query-status")
            XCTFail("a closed connection must throw")
        } catch let error as QMPError {
            guard case .connectionClosed = error else {
                return XCTFail("unexpected QMP error: \(error)")
            }
        }

        client.disconnect()
    }

    func testConnectToMissingSocketFailsCleanly() async {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("macport-missing-\(UUID().uuidString.prefix(8)).sock").path
        let client = QMPClient(path: path, connectTimeout: 1, commandTimeout: 1)

        do {
            try await client.connect()
            XCTFail("connecting to a socket nobody listens on must fail")
        } catch let error as QMPError {
            guard case .connectFailed = error else {
                return XCTFail("unexpected QMP error: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }

        client.disconnect()
    }

    func testExecuteBeforeConnectIsRefused() async {
        let client = QMPClient(
            path: "/tmp/macport-never-\(UUID().uuidString.prefix(8)).sock",
            connectTimeout: 1,
            commandTimeout: 1
        )

        do {
            _ = try await client.execute("stop")
            XCTFail("execute before connect must be refused")
        } catch let error as QMPError {
            guard case .notConnected = error else {
                return XCTFail("unexpected QMP error: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: Helpers

    /// Wait for the server to have recorded `count` lines, so assertions never
    /// race the server's own thread.
    private func waitForLines(
        _ server: FakeQMPServer,
        count: Int,
        timeout: TimeInterval = 2
    ) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = server.receivedLines
            if lines.count >= count { return lines }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return server.receivedLines
    }

    private func json(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            "expected a JSON object, got: \(line)"
        )
    }
}
