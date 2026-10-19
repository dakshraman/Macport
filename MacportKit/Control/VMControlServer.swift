import Darwin
import Foundation

/// A listener for the Macport control protocol on a unix-domain socket.
///
/// One connection carries one request and one response, then closes. The accept
/// loop runs on a serial dispatch queue and every blocking read or write happens
/// on a utility queue behind a continuation, so neither the host's main run loop
/// nor a Swift executor is ever parked on a client.
///
/// Shutdown is explicit: `stop()` closes the listener and unlinks the socket
/// file. It is synchronous so a process that is about to exit can be sure the
/// path is gone rather than racing an asynchronous cleanup.
public final class VMControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (VMControlRequest) async -> VMControlResponse

    /// Called after a reply has been written to a connection. The host uses it
    /// to shut down only once the `shutdownHost` reply has actually left the
    /// process; stopping from inside the handler would race the write.
    public typealias ResponseObserver = @Sendable (VMControlRequest) -> Void

    public let socketPath: String

    private let handler: Handler
    private let onResponseSent: ResponseObserver?
    private let queue = DispatchQueue(label: "com.dakshraman.macport.control.server")

    /// Queue-confined state.
    ///
    /// `stopped` starts true so a server whose `start()` failed — most
    /// importantly the losing side of an `addressInUse` race — does not unlink
    /// the live host's socket when it is deallocated. `bindOnQueue()` is what
    /// flips it to false, once the listener actually owns the path.
    private var listener: Int32 = -1
    private var stopped = true

    public init(
        socketPath: String,
        handler: @escaping Handler,
        onResponseSent: ResponseObserver? = nil
    ) {
        self.socketPath = socketPath
        self.handler = handler
        self.onResponseSent = onResponseSent
    }

    deinit {
        if listener >= 0 {
            close(listener)
        }
        if !stopped {
            unlink(socketPath)
        }
    }

    // MARK: - Lifecycle

    /// Bind, listen and start accepting. Throws before the socket is usable if
    /// the path is too long, occupied by a live listener, or cannot be bound.
    public func start() throws {
        try queue.sync {
            guard listener < 0 else { return }
            try bindOnQueue()
        }
        queue.async { [self] in
            acceptLoop()
        }
    }

    /// Close the listener and remove the socket file. Idempotent.
    public func stop() {
        queue.sync {
            stopOnQueue()
        }
    }

    // MARK: - Accept loop (server queue)

    private func bindOnQueue() throws {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let bytes = socketPath.utf8.count
        guard bytes < capacity else {
            throw VMControlError.socketPathTooLong(
                path: socketPath,
                bytes: bytes,
                limit: capacity
            )
        }

        try removeStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw VMControlError.socketCreationFailed(String(cString: strerror(errno)))
        }

        var one: Int32 = 1
        _ = withUnsafePointer(to: &one) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = socketPath.withCString { strncpy(destination, $0, capacity - 1) }
            }
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw VMControlError.socketCreationFailed(
                "Could not bind \(socketPath): \(detail)"
            )
        }

        guard listen(fd, 8) == 0 else {
            let detail = String(cString: strerror(errno))
            close(fd)
            unlink(socketPath)
            throw VMControlError.socketCreationFailed(
                "Could not listen on \(socketPath): \(detail)"
            )
        }

        // The control plane exposes pause, stop and snapshot, not a shell. Keep
        // the socket private to the account that created the host.
        chmod(socketPath, 0o600)
        listener = fd
        stopped = false
    }

    /// Remove a socket file only when nothing is listening on it.
    ///
    /// The connect test is the whole safety rule: a live host must never have its
    /// endpoint unlinked by a second host starting up.
    private func removeStaleSocket() throws {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        if Self.isListenerAlive(at: socketPath) {
            throw VMControlError.addressInUse(path: socketPath)
        }
        if unlink(socketPath) != 0 && errno != ENOENT {
            throw VMControlError.socketCreationFailed(
                "Could not remove the stale socket at \(socketPath): "
                    + String(cString: strerror(errno))
            )
        }
    }

    private static func isListenerAlive(at path: String) -> Bool {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < capacity else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = path.withCString { strncpy(destination, $0, capacity - 1) }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    /// Accept one pending connection, then reschedule.
    ///
    /// The loop deliberately does not stay on the queue: `stop()` is
    /// synchronous and runs on this same serial queue to close the listener and
    /// unlink the path. A `while` loop here would keep the queue forever and
    /// deadlock that `stop()`. Each iteration occupies the queue for at most one
    /// 250 ms poll, then yields so lifecycle work can interleave.
    private func acceptLoop() {
        guard !stopped else { return }

        var entry = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let polled = poll(&entry, 1, 250)
        if stopped { return }
        if polled < 0 {
            if errno != EINTR { return }
        } else if polled > 0 {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    return
                }
            } else {
                var one: Int32 = 1
                _ = withUnsafePointer(to: &one) {
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
                }
                let flags = fcntl(client, F_GETFL, 0)
                if flags >= 0 {
                    _ = fcntl(client, F_SETFL, flags | O_NONBLOCK)
                }

                Task { [self] in
                    await serveConnection(client)
                }
            }
        }

        queue.async { [self] in
            acceptLoop()
        }
    }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        if listener >= 0 {
            shutdown(listener, SHUT_RDWR)
            close(listener)
            listener = -1
        }
        unlink(socketPath)
    }

    // MARK: - One connection

    private func serveConnection(_ fd: Int32) async {
        defer { close(fd) }

        let deadline = Date().addingTimeInterval(VMControlClient.defaultCommandTimeout)
        let line: Data
        do {
            line = try await Self.readLine(fd: fd, deadline: deadline)
        } catch {
            return
        }

        let request: VMControlRequest
        do {
            request = try VMControlRequest.decodeLine(line)
        } catch {
            // A client that sent unreadable JSON still gets a structured
            // refusal if its envelope yields an id; otherwise there is nobody
            // to correlate a reply with.
            try? await writeFailure(
                id: Self.identifier(in: line) ?? UUID(),
                message: error.localizedDescription,
                fd: fd
            )
            return
        }

        var response = await handler(request)
        // The id is a correlation token, not something a handler should be able
        // to get wrong.
        response.id = request.id
        do {
            try await Self.writeAll(
                fd: fd,
                data: try response.encodedLine(),
                deadline: Date().addingTimeInterval(VMControlClient.defaultCommandTimeout)
            )
            onResponseSent?(request)
        } catch {
            // The client timed out or vanished. There is nowhere to report the
            // failure, and keeping the host alive is the right outcome.
        }
    }

    private static func identifier(in line: Data) -> UUID? {
        struct Envelope: Decodable { let id: UUID }
        return (try? VMControl.makeDecoder().decode(Envelope.self, from: line))?.id
    }

    private func writeFailure(id: UUID, message: String, fd: Int32) async throws {
        let response = VMControlResponse.failure(id: id, error: message)
        try await Self.writeAll(fd: fd, data: try response.encodedLine(), deadline: Date().addingTimeInterval(5))
    }

    // MARK: - Blocking I/O, bridged

    private static func readLine(fd: Int32, deadline: Date) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try readLineBlocking(fd: fd, deadline: deadline)
                })
            }
        }
    }

    private static func writeAll(fd: Int32, data: Data, deadline: Date) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try writeAllBlocking(fd: fd, data: data, deadline: deadline)
                })
            }
        }
    }

    private static func readLineBlocking(fd: Int32, deadline: Date) throws -> Data {
        var buffer = Data()
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                var line = Data(buffer[buffer.startIndex..<index])
                buffer.removeSubrange(buffer.startIndex...index)
                while let last = line.last, last == 0x0D || last == 0x20 || last == 0x09 {
                    line.removeLast()
                }
                guard !line.isEmpty else {
                    throw VMControlError.malformedMessage("the request was an empty line")
                }
                return line
            }
            if buffer.count > VMControl.maxFrameBytes {
                throw VMControlError.frameTooLarge(
                    bytes: buffer.count,
                    limit: VMControl.maxFrameBytes
                )
            }
            try waitForIO(fd: fd, events: Int16(POLLIN), deadline: deadline, onTimeout: .timedOut(command: "request"))
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                throw VMControlError.connectionClosed("the client closed before sending a request")
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                continue
            } else {
                throw VMControlError.connectionClosed(String(cString: strerror(errno)))
            }
        }
    }

    private static func writeAllBlocking(fd: Int32, data: Data, deadline: Date) throws {
        let bytes = Array(data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                try waitForIO(
                    fd: fd,
                    events: Int16(POLLOUT),
                    deadline: deadline,
                    onTimeout: .timedOut(command: "reply")
                )
                continue
            }
            throw VMControlError.connectionClosed(
                String(cString: strerror(written < 0 ? errno : EIO))
            )
        }
    }

    private static func waitForIO(
        fd: Int32,
        events: Int16,
        deadline: Date,
        onTimeout: VMControlError
    ) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw onTimeout }

            var entry = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min(remaining * 1000.0, Double(Int32.max)).rounded(.up))
            let polled = poll(&entry, 1, max(1, milliseconds))
            if polled > 0 {
                if entry.revents & Int16(POLLNVAL) != 0 {
                    throw VMControlError.connectionClosed("the connection is no longer valid")
                }
                return
            }
            if polled == 0 { continue }
            if errno == EINTR { continue }
            throw VMControlError.connectionClosed(String(cString: strerror(errno)))
        }
    }
}
