import Foundation

// MARK: - Metadata

/// What a running host publishes about itself in `<bundle>/runtime.json`.
///
/// This is the discovery record, not a second source of truth for machine state:
/// a client that can reach the socket asks `status`. It exists so a fresh app or
/// CLI process can find the socket and decide whether the recorded pid is still
/// the process that owns it.
public struct VMHostMetadata: Codable, Hashable, Sendable {
    public var pid: Int32
    public var socketPath: String
    public var startedAt: Date
    public var engineIdentifier: String

    public init(
        pid: Int32,
        socketPath: String,
        startedAt: Date,
        engineIdentifier: String
    ) {
        self.pid = pid
        self.socketPath = socketPath
        self.startedAt = startedAt
        self.engineIdentifier = engineIdentifier
    }
}

// MARK: - Runtime files

public enum VMHostRuntime {
    public static let runtimeFileName = "runtime.json"
    public static let lockFileName = ".lock"
    public static let hostLogFileName = "host.log"

    /// The kernel's `sun_path` limit, including the terminating NUL.
    public static let sunPathLimit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    public static func runtimeFileURL(in bundle: URL) -> URL {
        bundle.appendingPathComponent(runtimeFileName, isDirectory: false)
    }

    public static func lockFileURL(in bundle: URL) -> URL {
        bundle.appendingPathComponent(lockFileName, isDirectory: false)
    }

    public static func hostLogURL(in bundle: URL) -> URL {
        bundle.appendingPathComponent(hostLogFileName, isDirectory: false)
    }

    /// Write the record atomically, so a reader never sees half a JSON object.
    public static func writeMetadata(_ metadata: VMHostMetadata, in bundle: URL) throws {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let encoder = VMControl.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: runtimeFileURL(in: bundle), options: .atomic)
    }

    /// The record, or `nil` when the host has removed it or it is unreadable.
    /// A corrupt record is treated as absent: no pid and no socket is safer than
    /// trusting half of one.
    public static func readMetadata(in bundle: URL) -> VMHostMetadata? {
        guard let data = try? Data(contentsOf: runtimeFileURL(in: bundle)) else { return nil }
        return try? VMControl.makeDecoder().decode(VMHostMetadata.self, from: data)
    }

    public static func removeMetadata(in bundle: URL) {
        try? FileManager.default.removeItem(at: runtimeFileURL(in: bundle))
    }

    /// `kill(pid, 0)` is the portable liveness probe: it sends nothing and
    /// reports ESRCH for a process that no longer exists. EPERM means the pid is
    /// alive but owned by someone else, which for a user-owned VM still counts as
    /// alive.
    ///
    /// `pid <= 0` is rejected before the call because `kill(0, 0)` targets the
    /// caller's process group and would report a dead VM as alive.
    public static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// The default control socket for a bundle.
    ///
    /// The bundle path is the obvious home and the first choice, but a bundle
    /// under Application Support routinely exceeds the kernel's 104-byte
    /// `sun_path` limit. When it does, a short per-user temporary path keeps the
    /// host usable; either way the actual path is recorded in `runtime.json`, so
    /// clients never have to guess.
    public static func socketPath(for bundle: URL, vmID: UUID) -> String {
        let inBundle = bundle.appendingPathComponent("control.sock", isDirectory: false).path
        if inBundle.utf8.count < sunPathLimit { return inBundle }

        let name = "macport-\(vmID.uuidString.prefix(8)).control"
        let candidates = [
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: "/tmp", isDirectory: true),
        ]
        for directory in candidates {
            let path = directory.appendingPathComponent(name, isDirectory: false).path
            if path.utf8.count < sunPathLimit { return path }
        }
        return "/tmp/\(name)"
    }
}

// MARK: - Launcher errors

public enum VMHostLaunchError: Error, LocalizedError, Sendable, Equatable {
    case notFound(tried: [String])
    case environmentOverrideInvalid(path: String)
    case alreadyRunning(pid: Int32)
    case hostExited(status: Int32, logTail: String)
    case notReady(timeout: TimeInterval, logTail: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let tried):
            return "MacportVMHost was not found. Looked for, in order:\n"
                + tried.map { "  \($0)" }.joined(separator: "\n")
                + "\nBuild the MacportVMHost scheme, or set MACPORT_HOST_BIN to "
                + "an existing executable."
        case .environmentOverrideInvalid(let path):
            return "MACPORT_HOST_BIN is set to \(path), but that is not an "
                + "executable file. Fix the variable or unset it to use the "
                + "normal search order."
        case .alreadyRunning(let pid):
            return "This virtual machine is already running (pid \(pid))."
        case .hostExited(let status, let logTail):
            let tail = logTail.isEmpty ? "host.log is empty." : logTail
            return "MacportVMHost exited with status \(status) before it was "
                + "ready. Last lines of host.log:\n\(tail)"
        case .notReady(let timeout, let logTail):
            let tail = logTail.isEmpty ? "host.log is empty." : logTail
            return "MacportVMHost did not become ready within \(Int(timeout)) "
                + "seconds. Last lines of host.log:\n\(tail)"
        }
    }
}

// MARK: - Launcher

/// Finds and starts the per-VM host executable.
///
/// The search order is deliberately closed. `PATH` is never consulted: a
/// `MacportVMHost` planted earlier in a user's `PATH` would be arbitrary code
/// execution with the VM's identity. DerivedData is never searched either, so a
/// shipped Macport cannot accidentally run a developer's stale build.
public enum VMHostLauncher {
    public static let executableName = "MacportVMHost"
    public static let environmentKey = "MACPORT_HOST_BIN"

    /// Resolve the host executable.
    ///
    /// - Parameters:
    ///   - environment: Injected so the search order is testable.
    ///   - executableURL: The currently running executable. Defaults to
    ///     `Bundle.main.executableURL`.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let override = environment[environmentKey], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: false)
            guard isExecutable(url, fileManager: fileManager) else {
                throw VMHostLaunchError.environmentOverrideInvalid(path: override)
            }
            return url
        }

        let current = executableURL
            ?? Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let directory = current.deletingLastPathComponent()

        let candidates = [
            directory.appendingPathComponent(executableName, isDirectory: false),
            directory
                .appendingPathComponent("Macport.app", isDirectory: true)
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent(executableName, isDirectory: false),
            URL(fileURLWithPath: "/Applications/Macport.app/Contents/MacOS/\(executableName)"),
        ]

        for candidate in candidates where isExecutable(candidate, fileManager: fileManager) {
            return candidate
        }
        throw VMHostLaunchError.notFound(tried: candidates.map(\.path))
    }

    public static var isAvailable: Bool {
        (try? resolve()) != nil
    }

    private static func isExecutable(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: url.path)
    }

    // MARK: - Starting

    /// Start a detached host and wait until it publishes `runtime.json` and
    /// answers `status`.
    ///
    /// The returned metadata names the socket a proxy should use. On any failure
    /// the child is terminated rather than left as an orphan holding `.lock`.
    public static func launchDetached(
        _ config: VMConfiguration,
        bundle: URL,
        socketPath: String,
        logURL: URL,
        readinessTimeout: TimeInterval = 15
    ) async throws -> VMHostMetadata {
        let executable = try resolve()

        if let existing = VMHostRuntime.readMetadata(in: bundle),
           VMHostRuntime.isProcessAlive(pid: existing.pid) {
            throw VMHostLaunchError.alreadyRunning(pid: existing.pid)
        }
        VMHostRuntime.removeMetadata(in: bundle)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--vm", config.id.uuidString, "--socket", socketPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw VMHostLaunchError.hostExited(
                status: -1,
                logTail: "Could not launch \(executable.path): \(error.localizedDescription)"
            )
        }
        try? logHandle.close()

        let deadline = Date().addingTimeInterval(readinessTimeout)
        let client = VMControlClient(
            socketPath: socketPath,
            connectTimeout: 1,
            commandTimeout: 2
        )

        while Date() < deadline {
            if !process.isRunning {
                throw VMHostLaunchError.hostExited(
                    status: process.terminationStatus,
                    logTail: logTail(at: logURL)
                )
            }
            if let metadata = VMHostRuntime.readMetadata(in: bundle),
               metadata.pid == process.processIdentifier,
               VMHostRuntime.isProcessAlive(pid: metadata.pid) {
                let request = VMControlRequest(command: .status)
                if let response = try? await client.send(request), response.ok {
                    return metadata
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        process.terminate()
        throw VMHostLaunchError.notReady(
            timeout: readinessTimeout,
            logTail: logTail(at: logURL)
        )
    }

    /// Run the host in the foreground, attached to this terminal.
    ///
    /// Used by `macportctl start --foreground`, where the user wants the host's
    /// own diagnostics and a Ctrl-C that reaches it directly.
    public static func runForeground(
        _ config: VMConfiguration,
        bundle: URL,
        socketPath: String
    ) throws -> Int32 {
        let executable = try resolve()
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--vm", config.id.uuidString, "--socket", socketPath]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// The last few kilobytes of the host's log, for an actionable failure.
    private static func logTail(at url: URL, limit: Int = 4096) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        return text
            .split(whereSeparator: \.isNewline)
            .suffix(20)
            .joined(separator: "\n")
    }
}
