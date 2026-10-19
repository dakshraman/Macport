import Foundation

// MARK: - JSON value

/// A JSON value with exactly the cases QMP produces.
///
/// QMP is JSON, and Foundation's `Any` is not `Sendable` — so the client
/// communicates in this small value type instead. It is `Codable` in both
/// directions, which is what lets the client decode a response with a
/// `JSONDecoder` and encode a command with a `JSONEncoder` while staying inside
/// Swift 6's concurrency rules.
public enum QMPValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([QMPValue])
    case object([String: QMPValue])

    /// The value as an object, if it is one.
    public var objectValue: [String: QMPValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The value as a string, if it is one.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The value as an integer, accepting a whole number where one is expected.
    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value: return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    /// The value as a boolean, if it is one.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The value as an array, if it is one.
    public var arrayValue: [QMPValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Member access for objects; `nil` for anything else.
    public subscript(key: String) -> QMPValue? {
        objectValue?[key]
    }
}

extension QMPValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([QMPValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: QMPValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable in QMP's JSON subset."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Errors

/// Everything that can go wrong talking to QEMU's monitor.
///
/// Separate from `EngineError` on purpose: this layer knows about sockets and
/// JSON, not about virtual machines. The engine translates these into
/// user-facing errors where it has the context to word them well.
public enum QMPError: Error, LocalizedError, Sendable, Equatable {
    /// `socket(2)` itself failed — no descriptors or no unix support.
    case socketCreationFailed(String)
    /// `connect(2)` failed or was refused.
    case connectFailed(path: String, detail: String)
    /// The socket exists but never became connectable inside the budget.
    case connectTimedOut(path: String)
    /// `execute` was called before a successful `connect()`.
    case notConnected
    /// QEMU closed the connection, or the kernel reported an error on it.
    case connectionClosed(String)
    /// The command was sent, but no matching reply arrived in time.
    case timedOut(command: String)
    /// A line arrived that is not a JSON object QMP could have sent.
    case malformedResponse(String)
    /// Outbound encoding failed. A bug, not a runtime condition.
    case encodingFailed(String)
    /// QEMU answered with `{"error": {"class": ..., "desc": ...}}`.
    case commandFailed(command: String, errorClass: String, description: String)

    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let detail):
            return "Could not create a unix socket: \(detail)"
        case .connectFailed(let path, let detail):
            return "Could not connect to the QEMU monitor at \(path): \(detail)"
        case .connectTimedOut(let path):
            return "Timed out connecting to the QEMU monitor at \(path)."
        case .notConnected:
            return "The QEMU monitor connection is not open."
        case .connectionClosed(let detail):
            return "The QEMU monitor connection closed: \(detail)"
        case .timedOut(let command):
            return "The QEMU monitor did not answer \(command) in time."
        case .malformedResponse(let line):
            return "The QEMU monitor sent something that is not a QMP message: \(line)"
        case .encodingFailed(let detail):
            return "Could not encode a QMP command: \(detail)"
        case .commandFailed(let command, let errorClass, let description):
            let detail = description.isEmpty ? "no detail given" : description
            return "QEMU rejected \(command) (\(errorClass)): \(detail)"
        }
    }
}

// MARK: - Client

/// A QEMU Machine Protocol client over a unix domain socket.
///
/// Deliberately POSIX rather than Network.framework: QEMU's monitor is a plain
/// stream socket, the same one the human monitor already uses, and the whole
/// protocol is line-delimited JSON. `socket`/`connect`/`poll`/`read`/`write` are
/// the smallest correct implementation and behave predictably under timeouts.
///
/// **Concurrency.** The client is a `final class` with one serial dispatch queue
/// that owns every byte of mutable state (the descriptor, the read buffer). The
/// blocking POSIX calls therefore never run on a Swift concurrency executor —
/// they run on a plain GCD queue — and the `async` API bridges in and out of
/// that queue with continuations. `@unchecked Sendable` is the price of
/// confinement by convention; the queue is what actually makes it safe.
///
/// Every socket is `O_NONBLOCK` and every wait is a `poll` bounded by a
/// deadline, so no thread can sit on a wedged hypervisor. A timeout tears the
/// connection down: the stream is no longer trustworthy once a reply has been
/// dropped, and pretending otherwise would hand a mismatched reply to the next
/// command.
public final class QMPClient: @unchecked Sendable {
    /// How long `connect()` may spend reaching QEMU's socket.
    public static let defaultConnectTimeout: TimeInterval = 5
    /// How long one command may take from send to matching reply.
    public static let defaultCommandTimeout: TimeInterval = 10

    public let path: String
    private let connectTimeout: TimeInterval
    private let commandTimeout: TimeInterval

    private let queue = DispatchQueue(label: "com.dakshraman.macport.qmp")
    /// Mutable state, owned by `queue` alone.
    private var descriptor: Int32 = -1
    private var buffer = Data()

    /// - Parameters:
    ///   - path: The unix socket path QEMU created for `-qmp`.
    ///   - connectTimeout: Total budget to connect and complete the handshake.
    ///   - commandTimeout: Budget for each individual command exchange.
    public init(
        path: String,
        connectTimeout: TimeInterval = QMPClient.defaultConnectTimeout,
        commandTimeout: TimeInterval = QMPClient.defaultCommandTimeout
    ) {
        self.path = path
        self.connectTimeout = connectTimeout
        self.commandTimeout = commandTimeout
    }

    deinit {
        // No other references can exist if this is running, so touching the
        // descriptor directly is safe.
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }

    // MARK: - Public API

    /// Connect and negotiate `qmp_capabilities`.
    ///
    /// Reading QEMU's greeting, sending the capabilities command and awaiting
    /// its `{"return": {}}` are one step on purpose: until the handshake
    /// completes, nothing else is legal to send.
    public func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try connectOnQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run one QMP command and return its `return` payload.
    ///
    /// Asynchronous `event` messages that arrive while waiting are ignored, as
    /// the protocol requires: only the reply matching this command ends the
    /// wait. A command QEMU rejects throws `.commandFailed`, carrying QEMU's
    /// own error class and description.
    public func execute(
        _ command: String,
        arguments: [String: QMPValue]? = nil
    ) async throws -> QMPValue {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(
                        returning: try executeOnQueue(command, arguments: arguments)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Shut the connection down. Safe to call more than once.
    ///
    /// Asynchronous because it is queued behind any in-flight I/O; the socket
    /// is closed even if a command is waiting on it, because `shutdown` makes
    /// the pending `poll` return immediately.
    public func disconnect() {
        queue.async { [self] in
            closeOnQueue()
        }
    }

    // MARK: - Wire protocol

    /// One decoded QMP message. A message is exactly one of: a greeting (only
    /// once, at connect), an event, an error, or a return.
    private struct QMPMessage: Decodable {
        var greeting: QMPValue?
        var event: String?
        var error: QMPErrorPayload?
        var returnValue: QMPValue?

        enum CodingKeys: String, CodingKey {
            case greeting = "QMP"
            case event
            case error
            case returnValue = "return"
        }
    }

    private struct QMPErrorPayload: Decodable {
        var errorClass: String
        var description: String?

        enum CodingKeys: String, CodingKey {
            case errorClass = "class"
            case description = "desc"
        }
    }

    /// One outbound command. `arguments` is omitted when nil, as QMP expects.
    private struct QMPRequest: Encodable {
        let execute: String
        let arguments: [String: QMPValue]?
    }

    private func requestLine(_ command: String, arguments: [String: QMPValue]?) throws -> String {
        do {
            let data = try JSONEncoder().encode(QMPRequest(execute: command, arguments: arguments))
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw QMPError.encodingFailed("\(command): \(error.localizedDescription)")
        }
    }

    // MARK: - Queue-confined implementation

    private func connectOnQueue() throws {
        guard descriptor < 0 else { return }

        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < capacity else {
            throw QMPError.connectFailed(
                path: path,
                detail: "the path is longer than the kernel's \(capacity - 1)-byte limit"
            )
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw QMPError.socketCreationFailed(String(cString: strerror(errno)))
        }

        // A write to a socket the peer closed must not raise SIGPIPE and take
        // the host process down with it.
        var one: Int32 = 1
        _ = withUnsafePointer(to: &one) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        // Non-blocking so every wait is a bounded `poll`, not an unbounded
        // blocking call.
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

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
        if connected != 0 {
            let code = errno
            guard code == EINPROGRESS || code == EAGAIN else {
                close(fd)
                throw QMPError.connectFailed(path: path, detail: String(cString: strerror(code)))
            }
            let deadline = Date().addingTimeInterval(connectTimeout)
            do {
                try waitForIO(
                    fd: fd,
                    events: Int16(POLLOUT),
                    deadline: deadline,
                    onTimeout: QMPError.connectTimedOut(path: path)
                )
            } catch {
                close(fd)
                throw error
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0 else {
                let detail = socketError == 0 ? "unknown error" : String(cString: strerror(socketError))
                close(fd)
                throw QMPError.connectFailed(path: path, detail: detail)
            }
        }

        descriptor = fd
        buffer.removeAll(keepingCapacity: false)

        // 1. The greeting. QEMU sends it unprompted; anything else means the
        //    server is not QMP.
        let greetingDeadline = Date().addingTimeInterval(connectTimeout)
        do {
            let line = try readLineOnQueue(
                deadline: greetingDeadline,
                onTimeout: QMPError.connectTimedOut(path: path)
            )
            guard let message = try? JSONDecoder().decode(QMPMessage.self, from: line),
                  message.greeting != nil else {
                closeOnQueue()
                throw QMPError.malformedResponse(String(decoding: line, as: UTF8.self))
            }
        } catch {
            closeOnQueue()
            throw error
        }

        // 2. Capabilities. Nothing else may be sent first.
        do {
            _ = try roundTripOnQueue(command: "qmp_capabilities", arguments: nil)
        } catch {
            closeOnQueue()
            throw error
        }
    }

    private func executeOnQueue(_ command: String, arguments: [String: QMPValue]?) throws -> QMPValue {
        guard descriptor >= 0 else { throw QMPError.notConnected }
        do {
            return try roundTripOnQueue(command: command, arguments: arguments)
        } catch let error as QMPError {
            // Once a reply is lost, every later reply is one message out of
            // step. The connection is torn down rather than reused.
            switch error {
            case .timedOut, .malformedResponse, .connectionClosed, .notConnected:
                closeOnQueue()
            default:
                break
            }
            throw error
        }
    }

    private func roundTripOnQueue(command: String, arguments: [String: QMPValue]?) throws -> QMPValue {
        let deadline = Date().addingTimeInterval(commandTimeout)
        let line = try requestLine(command, arguments: arguments)
        try sendOnQueue(line, deadline: deadline, command: command)
        return try awaitReturnOnQueue(command: command, deadline: deadline)
    }

    private func sendOnQueue(_ line: String, deadline: Date, command: String) throws {
        guard descriptor >= 0 else { throw QMPError.notConnected }
        var bytes = Array(line.utf8)
        bytes.append(0x0A)

        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(descriptor, base.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                try waitForIO(
                    fd: descriptor,
                    events: Int16(POLLOUT),
                    deadline: deadline,
                    onTimeout: QMPError.timedOut(command: command)
                )
                continue
            }
            throw QMPError.connectionClosed(String(cString: strerror(written < 0 ? errno : EIO)))
        }
    }

    /// Read until the reply to `command` arrives, dropping events.
    private func awaitReturnOnQueue(command: String, deadline: Date) throws -> QMPValue {
        while true {
            let line = try readLineOnQueue(
                deadline: deadline,
                onTimeout: QMPError.timedOut(command: command)
            )
            guard let message = try? JSONDecoder().decode(QMPMessage.self, from: line) else {
                throw QMPError.malformedResponse(String(decoding: line, as: UTF8.self))
            }
            // Events are asynchronous and unrelated to this command.
            if message.event != nil { continue }
            if let error = message.error {
                throw QMPError.commandFailed(
                    command: command,
                    errorClass: error.errorClass,
                    description: error.description ?? ""
                )
            }
            if let value = message.returnValue { return value }
            // Anything else (a late greeting, an unknown key) is not the reply.
            continue
        }
    }

    /// One newline-delimited, non-empty line from the socket.
    private func readLineOnQueue(deadline: Date, onTimeout: QMPError) throws -> Data {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                var line = Data(buffer[buffer.startIndex..<index])
                buffer.removeSubrange(buffer.startIndex...index)
                while let last = line.last, last == 0x0D || last == 0x20 || last == 0x09 {
                    line.removeLast()
                }
                if line.isEmpty { continue }
                return line
            }

            try waitForIO(fd: descriptor, events: Int16(POLLIN), deadline: deadline, onTimeout: onTimeout)

            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                throw QMPError.connectionClosed("QEMU closed the monitor socket")
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                continue
            } else {
                throw QMPError.connectionClosed(String(cString: strerror(errno)))
            }
        }
    }

    /// Wait for one of `events` on `fd`, giving up at `deadline`.
    private func waitForIO(fd: Int32, events: Int16, deadline: Date, onTimeout: QMPError) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw onTimeout }

            var entry = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min(remaining * 1000.0, Double(Int32.max)).rounded(.up))
            let polled = poll(&entry, 1, max(1, milliseconds))
            if polled > 0 {
                if entry.revents & Int16(POLLNVAL) != 0 {
                    throw QMPError.connectionClosed("the socket is no longer valid")
                }
                return
            }
            if polled == 0 { continue } // loop once more; the deadline check throws
            if errno == EINTR { continue }
            throw QMPError.connectionClosed(String(cString: strerror(errno)))
        }
    }

    /// Close and forget the connection. Idempotent.
    private func closeOnQueue() {
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
            descriptor = -1
        }
        buffer.removeAll(keepingCapacity: false)
    }
}
