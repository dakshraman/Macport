import Darwin
import Foundation

/// A POSIX unix-domain-socket client for the Macport control protocol.
///
/// Deliberately mirrors `QMPClient`'s shape. The socket is a plain byte stream
/// and the protocol is line-delimited JSON, so `socket`/`connect`/`poll` are the
/// smallest correct implementation and their timeouts are predictable.
///
/// **Concurrency.** The class is `@unchecked Sendable` because one serial queue
/// owns every blocking call; continuations carry results back to Swift
/// concurrency. No `read`, `write`, `poll` or `connect` ever runs on a Swift
/// executor. Each request opens and closes its own connection: the protocol is
/// one request and one response, and a short-lived connection cannot hand a
/// mismatched reply to the next command.
public final class VMControlClient: ControlChannel, @unchecked Sendable {
    public static let defaultConnectTimeout: TimeInterval = 5
    public static let defaultCommandTimeout: TimeInterval = 10

    public let socketPath: String
    private let connectTimeout: TimeInterval
    private let commandTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.dakshraman.macport.control.client")

    public init(
        socketPath: String,
        connectTimeout: TimeInterval = VMControlClient.defaultConnectTimeout,
        commandTimeout: TimeInterval = VMControlClient.defaultCommandTimeout
    ) {
        self.socketPath = socketPath
        self.connectTimeout = connectTimeout
        self.commandTimeout = commandTimeout
    }

    public func send(_ request: VMControlRequest) async throws -> VMControlResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try roundTripOnQueue(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - One request

    private func roundTripOnQueue(_ request: VMControlRequest) throws -> VMControlResponse {
        let fd = try connectOnQueue()
        defer {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }

        let deadline = Date().addingTimeInterval(commandTimeout)
        let line = try request.encodedLine()
        guard line.count <= VMControl.maxFrameBytes else {
            throw VMControlError.frameTooLarge(
                bytes: line.count,
                limit: VMControl.maxFrameBytes
            )
        }
        try Self.writeAll(fd: fd, data: line, deadline: deadline, command: request.command.name)

        let reply = try Self.readLine(
            fd: fd,
            deadline: deadline,
            command: request.command.name
        )
        let response = try VMControlResponse.decodeLine(reply)
        guard response.id == request.id else {
            throw VMControlError.mismatchedIdentifier(expected: request.id, received: response.id)
        }
        return response
    }

    private func connectOnQueue() throws -> Int32 {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let bytes = socketPath.utf8.count
        guard bytes < capacity else {
            throw VMControlError.socketPathTooLong(
                path: socketPath,
                bytes: bytes,
                limit: capacity
            )
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw VMControlError.socketCreationFailed(String(cString: strerror(errno)))
        }

        // A write to a socket the host closed must not raise SIGPIPE and take
        // the caller down; `write` then returns EPIPE as an ordinary error.
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

        let deadline = Date().addingTimeInterval(connectTimeout)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connected != 0 {
            let code = errno
            if code == ENOENT {
                close(fd)
                throw VMControlError.socketMissing(socketPath)
            }
            guard code == EINPROGRESS || code == EAGAIN else {
                close(fd)
                throw VMControlError.connectionRefused(
                    path: socketPath,
                    detail: String(cString: strerror(code))
                )
            }

            do {
                try Self.waitForIO(
                    fd: fd,
                    events: Int16(POLLOUT),
                    deadline: deadline,
                    onTimeout: .connectTimedOut(path: socketPath)
                )
            } catch {
                close(fd)
                throw error
            }

            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0 else {
                let detail = socketError == 0
                    ? "unknown error"
                    : String(cString: strerror(socketError))
                close(fd)
                if socketError == ECONNREFUSED {
                    throw VMControlError.connectionRefused(path: socketPath, detail: detail)
                }
                throw VMControlError.connectionClosed(detail)
            }
        }

        return fd
    }

    // MARK: - Queue-confined I/O primitives

    private static func writeAll(
        fd: Int32,
        data: Data,
        deadline: Date,
        command: String
    ) throws {
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
                    onTimeout: .timedOut(command: command)
                )
                continue
            }
            throw VMControlError.connectionClosed(
                String(cString: strerror(written < 0 ? errno : EIO))
            )
        }
    }

    private static func readLine(
        fd: Int32,
        deadline: Date,
        command: String
    ) throws -> Data {
        var buffer = Data()
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                var line = Data(buffer[buffer.startIndex..<index])
                buffer.removeSubrange(buffer.startIndex...index)
                while let last = line.last, last == 0x0D || last == 0x20 || last == 0x09 {
                    line.removeLast()
                }
                guard !line.isEmpty else {
                    throw VMControlError.malformedMessage("the reply was an empty line")
                }
                return line
            }

            if buffer.count > VMControl.maxFrameBytes {
                throw VMControlError.frameTooLarge(
                    bytes: buffer.count,
                    limit: VMControl.maxFrameBytes
                )
            }

            try waitForIO(
                fd: fd,
                events: Int16(POLLIN),
                deadline: deadline,
                onTimeout: .timedOut(command: command)
            )

            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                throw VMControlError.connectionClosed(
                    "the host closed the connection without sending a reply"
                )
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                continue
            } else {
                throw VMControlError.connectionClosed(String(cString: strerror(errno)))
            }
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
                    throw VMControlError.connectionClosed("the socket is no longer valid")
                }
                return
            }
            if polled == 0 { continue }
            if errno == EINTR { continue }
            throw VMControlError.connectionClosed(String(cString: strerror(errno)))
        }
    }
}
