import Foundation

/// The wire protocol shared by `MacportVMHost`, the CLI and the app.
///
/// One JSON object per line in each direction, one request and one response per
/// connection. The version field is not decoration: a host built by a newer
/// Macport has to be able to refuse an older client's request with a message a
/// person can act on, rather than silently misreading its fields.
public enum VMControl {
    public static let version = 1

    /// A single line must fit in 64 KiB. The protocol carries status and snapshot
    /// metadata, not disk contents; anything larger is a broken peer.
    public static let maxFrameBytes = 64 * 1024

    /// Dates travel as ISO 8601 so a socket trace is readable without a decoder.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Errors

/// Everything that can go wrong before a control request reaches its handler.
///
/// Separate from `EngineError` on purpose: this layer knows about sockets, JSON
/// and protocol versions, not virtual machines. The proxy translates these into
/// engine errors where it has the context to word them well.
public enum VMControlError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedVersion(Int)
    case malformedMessage(String)
    case frameTooLarge(bytes: Int, limit: Int)
    case socketPathTooLong(path: String, bytes: Int, limit: Int)
    case socketMissing(String)
    case connectionRefused(path: String, detail: String)
    case connectTimedOut(path: String)
    case timedOut(command: String)
    case connectionClosed(String)
    case encodingFailed(String)
    case socketCreationFailed(String)
    case addressInUse(path: String)
    case mismatchedIdentifier(expected: UUID, received: UUID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This Macport control message uses protocol version \(version), "
                + "but this build speaks version \(VMControl.version). "
                + "Update Macport so the app, CLI and host are the same build."
        case .malformedMessage(let detail):
            return "The background host sent a reply that is not valid Macport "
                + "control JSON: \(detail)"
        case .frameTooLarge(let bytes, let limit):
            return "A control message was \(bytes) bytes, which exceeds the "
                + "\(limit)-byte limit. The peer is not speaking the Macport protocol."
        case .socketPathTooLong(let path, let bytes, let limit):
            return "The control socket path is \(bytes) bytes, but macOS allows "
                + "at most \(limit - 1) bytes in `sun_path`: \(path). "
                + "Pass `--socket` with a shorter path, for example "
                + "/tmp/macport-<uuid8>.control."
        case .socketMissing(let path):
            return "There is no control socket at \(path). The machine is not "
                + "running, or its background host has exited and left a stale "
                + "runtime.json."
        case .connectionRefused(let path, let detail):
            return "The background host is not accepting connections at \(path) "
                + "(\(detail)). It may be shutting down."
        case .connectTimedOut(let path):
            return "Timed out connecting to the background host at \(path)."
        case .timedOut(let command):
            return "The background host did not answer `\(command)` in time. "
                + "The guest may be busy, or the host may be stuck; check "
                + "`macportctl status` and the VM's host.log."
        case .connectionClosed(let detail):
            return "The background host closed the control connection: \(detail)"
        case .encodingFailed(let detail):
            return "Could not encode a control message: \(detail)"
        case .socketCreationFailed(let detail):
            return "Could not create a unix socket: \(detail)"
        case .addressInUse(let path):
            return "A live control socket already exists at \(path). Another "
                + "MacportVMHost is running for this machine."
        case .mismatchedIdentifier(let expected, let received):
            return "The background host answered request \(expected) with a reply "
                + "for \(received). The connection is out of step; refusing the reply."
        }
    }
}

// MARK: - Commands

/// One operation a background host can perform.
///
/// `unknown` is a decoded value rather than a decoding failure so the host can
/// answer an unrecognised command with a structured error instead of dropping
/// the connection without an explanation.
public enum VMControlCommand: Sendable, Equatable {
    case status
    case pause
    case resume
    case stop(graceful: Bool)
    case snapshots
    case takeSnapshot(name: String)
    /// `id` is the engine's snapshot tag. On the wire it travels as
    /// `snapshotID`, because the envelope's `id` is the request identifier.
    case restoreSnapshot(id: String)
    case deleteSnapshot(id: String)
    case shutdownHost
    case unknown(String)

    public var name: String {
        switch self {
        case .status: return "status"
        case .pause: return "pause"
        case .resume: return "resume"
        case .stop: return "stop"
        case .snapshots: return "snapshots"
        case .takeSnapshot: return "takeSnapshot"
        case .restoreSnapshot: return "restoreSnapshot"
        case .deleteSnapshot: return "deleteSnapshot"
        case .shutdownHost: return "shutdownHost"
        case .unknown(let name): return name
        }
    }
}

// MARK: - Request

/// One control request.
///
/// Arguments live beside the command rather than in a nested object, matching
/// the documented wire shape: `{"v":1,"id":"…","command":"stop","graceful":true}`.
public struct VMControlRequest: Codable, Sendable, Equatable {
    public var v: Int
    public var id: UUID
    public var command: VMControlCommand

    public init(
        v: Int = VMControl.version,
        id: UUID = UUID(),
        command: VMControlCommand
    ) {
        self.v = v
        self.id = id
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case id
        case command
        case graceful
        case name
        case snapshotID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decodeIfPresent(Int.self, forKey: .v) ?? VMControl.version
        guard v == VMControl.version else {
            throw VMControlError.unsupportedVersion(v)
        }
        id = try container.decode(UUID.self, forKey: .id)
        let raw = try container.decode(String.self, forKey: .command)

        switch raw {
        case "status":
            command = .status
        case "pause":
            command = .pause
        case "resume":
            command = .resume
        case "stop":
            // The safe default for a missing flag is the one the user expects
            // from a power button: ask the guest first.
            command = .stop(graceful: try container.decodeIfPresent(Bool.self, forKey: .graceful) ?? true)
        case "snapshots":
            command = .snapshots
        case "takeSnapshot", "snapshot":
            command = .takeSnapshot(name: try container.decode(String.self, forKey: .name))
        case "restoreSnapshot", "restore":
            command = .restoreSnapshot(id: try container.decode(String.self, forKey: .snapshotID))
        case "deleteSnapshot":
            command = .deleteSnapshot(id: try container.decode(String.self, forKey: .snapshotID))
        case "shutdownHost":
            command = .shutdownHost
        default:
            command = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encode(command.name, forKey: .command)

        switch command {
        case .stop(let graceful):
            try container.encode(graceful, forKey: .graceful)
        case .takeSnapshot(let name):
            try container.encode(name, forKey: .name)
        case .restoreSnapshot(let id), .deleteSnapshot(let id):
            try container.encode(id, forKey: .snapshotID)
        case .status, .pause, .resume, .snapshots, .shutdownHost, .unknown:
            break
        }
    }

    /// One newline-terminated JSON line, ready for a stream socket.
    public func encodedLine() throws -> Data {
        do {
            var data = try VMControl.makeEncoder().encode(self)
            data.append(0x0A)
            return data
        } catch let error as VMControlError {
            throw error
        } catch {
            throw VMControlError.encodingFailed("\(command.name): \(error.localizedDescription)")
        }
    }

    public static func decodeLine(_ line: Data) throws -> VMControlRequest {
        do {
            return try VMControl.makeDecoder().decode(VMControlRequest.self, from: line)
        } catch let error as VMControlError {
            throw error
        } catch {
            throw VMControlError.malformedMessage(String(decoding: line, as: UTF8.self))
        }
    }
}

// MARK: - Payloads

/// Live status, mirrored into `runtime.json` for discovery when no client is
/// connected.
public struct VMControlStatus: Codable, Sendable, Equatable {
    public var state: VMState
    public var pid: Int32
    public var startedAt: Date
    public var engineIdentifier: String
    public var paused: Bool

    public init(
        state: VMState,
        pid: Int32,
        startedAt: Date,
        engineIdentifier: String,
        paused: Bool
    ) {
        self.state = state
        self.pid = pid
        self.startedAt = startedAt
        self.engineIdentifier = engineIdentifier
        self.paused = paused
    }
}

/// The snapshot list travels in a wrapper so it cannot be mistaken for a single
/// snapshot during payload decoding.
public struct VMControlSnapshotList: Codable, Sendable, Equatable {
    public var snapshots: [VMSnapshot]

    public init(snapshots: [VMSnapshot]) {
        self.snapshots = snapshots
    }
}

/// A typed response payload. The three shapes are distinguishable by their
/// fields, so no discriminator is needed on the wire.
public enum VMControlPayload: Codable, Sendable, Equatable {
    case status(VMControlStatus)
    case snapshots([VMSnapshot])
    case snapshot(VMSnapshot)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let status = try? container.decode(VMControlStatus.self) {
            self = .status(status)
        } else if let list = try? container.decode(VMControlSnapshotList.self) {
            self = .snapshots(list.snapshots)
        } else if let snapshot = try? container.decode(VMSnapshot.self) {
            self = .snapshot(snapshot)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Payload is not status, a snapshot list, or a snapshot."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .status(let status):
            try container.encode(status)
        case .snapshots(let snapshots):
            try container.encode(VMControlSnapshotList(snapshots: snapshots))
        case .snapshot(let snapshot):
            try container.encode(snapshot)
        }
    }
}

// MARK: - Response

public struct VMControlResponse: Codable, Sendable, Equatable {
    public var v: Int
    public var id: UUID
    public var ok: Bool
    public var error: String?
    public var payload: VMControlPayload?

    public init(
        v: Int = VMControl.version,
        id: UUID,
        ok: Bool,
        error: String? = nil,
        payload: VMControlPayload? = nil
    ) {
        self.v = v
        self.id = id
        self.ok = ok
        self.error = error
        self.payload = payload
    }

    public static func success(id: UUID, payload: VMControlPayload? = nil) -> VMControlResponse {
        VMControlResponse(id: id, ok: true, payload: payload)
    }

    public static func failure(id: UUID, error: String) -> VMControlResponse {
        VMControlResponse(id: id, ok: false, error: error)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decodeIfPresent(Int.self, forKey: .v) ?? VMControl.version
        guard v == VMControl.version else {
            throw VMControlError.unsupportedVersion(v)
        }
        id = try container.decode(UUID.self, forKey: .id)
        ok = try container.decode(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        payload = try container.decodeIfPresent(VMControlPayload.self, forKey: .payload)
    }

    public func encodedLine() throws -> Data {
        do {
            var data = try VMControl.makeEncoder().encode(self)
            data.append(0x0A)
            return data
        } catch let error as VMControlError {
            throw error
        } catch {
            throw VMControlError.encodingFailed("response \(id): \(error.localizedDescription)")
        }
    }

    public static func decodeLine(_ line: Data) throws -> VMControlResponse {
        do {
            return try VMControl.makeDecoder().decode(VMControlResponse.self, from: line)
        } catch let error as VMControlError {
            throw error
        } catch {
            throw VMControlError.malformedMessage(String(decoding: line, as: UTF8.self))
        }
    }
}
