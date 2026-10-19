import Darwin
import Foundation
import MacportKit

// MARK: - Options

/// A failure that already knows the exit code the host must use.
private struct HostExit: Error {
    var code: Int32
    var message: String
}

private struct HostOptions: Sendable {
    var vmID: UUID
    var socketPath: String?
    var help: Bool

    static func parse(_ arguments: [String]) throws -> HostOptions {
        var vmID: UUID?
        var socketPath: String?
        var help = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                help = true
                index += 1

            case "--vm":
                guard index + 1 < arguments.count else {
                    throw HostExit(code: 2, message: "--vm needs a virtual machine UUID.")
                }
                let raw = arguments[index + 1]
                guard let parsed = UUID(uuidString: raw) else {
                    throw HostExit(code: 2, message: "--vm expects a UUID, not '\(raw)'.")
                }
                vmID = parsed
                index += 2

            case "--socket":
                guard index + 1 < arguments.count else {
                    throw HostExit(code: 2, message: "--socket needs a path.")
                }
                socketPath = arguments[index + 1]
                index += 2

            default:
                throw HostExit(code: 2, message: "Unknown option '\(argument)'. Try --help.")
            }
        }

        if !help, vmID == nil {
            throw HostExit(code: 2, message: "--vm <uuid> is required. Try --help.")
        }
        return HostOptions(vmID: vmID ?? UUID(), socketPath: socketPath, help: help)
    }
}

// MARK: - Entry point

@MainActor
enum MacportVMHostMain {
    static func run(arguments: [String]) async -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)

        let options: HostOptions
        do {
            options = try HostOptions.parse(arguments)
        } catch let failure as HostExit {
            fail(failure.message)
            return failure.code
        } catch {
            fail(error.localizedDescription)
            return 2
        }

        if options.help {
            printUsage()
            return 0
        }

        let host = HostApplication(options: options)
        return await host.run()
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func printUsage() {
        print(
            """
            MacportVMHost — one background process per QEMU virtual machine

            USAGE
              MacportVMHost --vm <uuid> [--socket <path>]

            OPTIONS
              --vm <uuid>      Virtual machine to run (required)
              --socket <path>  Control socket. Defaults to <bundle>/control.sock,
                               or a short temporary path when the bundle path is
                               longer than macOS's 103-byte socket limit.
              --help           Show this message

            ROOT
              MACPORT_VM_ROOT overrides the VM directory (default:
              \(VMStore.defaultRoot.path)).

            EXIT CODES
              0  clean shutdown
              2  configuration or runtime error
              3  the machine is already running (its .lock is held)
              4  the machine is not a QEMU machine

            The host prints one line when ready:

              ready vm=<uuid> socket=<path> pid=<pid>
            """
        )
    }
}

// MARK: - Host

@MainActor
private final class HostApplication {
    private let options: HostOptions
    private let startedAt = Date()

    private var config: VMConfiguration?
    private var engine: QEMUEngine?
    private var server: VMControlServer?
    private var metadata: VMHostMetadata?
    private var bundle: URL?
    private var lockDescriptor: Int32 = -1
    private var signalSources: [DispatchSourceSignal] = []
    private var keepAliveTimer: Timer?
    private var isShuttingDown = false

    init(options: HostOptions) {
        self.options = options
    }

    func run() async -> Int32 {
        do {
            try await start()
        } catch let failure as HostExit {
            FileHandle.standardError.write(Data((failure.message + "\n").utf8))
            return failure.code
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 2
        }

        if !isShuttingDown {
            serve()
        }
        await shutdown()
        return 0
    }

    // MARK: Startup

    private func start() async throws {
        let root = ProcessInfo.processInfo.environment["MACPORT_VM_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? VMStore.defaultRoot
        let store = VMStore(root: root)
        store.load()

        guard let config = store.machines.first(where: { $0.id == options.vmID }) else {
            throw HostExit(
                code: 2,
                message: "No virtual machine with id \(options.vmID.uuidString) in \(root.path)."
            )
        }

        let engineType = EngineRegistry.engineType(for: config)
        guard ObjectIdentifier(engineType) == ObjectIdentifier(QEMUEngine.self) else {
            throw HostExit(
                code: 4,
                message: "Virtualization.framework machines are bound to the app "
                    + "process; only QEMU machines can run in the background host"
            )
        }

        let bundle = store.bundleURL(for: config)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        self.bundle = bundle
        self.config = config

        try acquireLock(in: bundle)

        let socketPath = options.socketPath
            ?? VMHostRuntime.socketPath(for: bundle, vmID: config.id)
        let engine = QEMUEngine()
        self.engine = engine

        do {
            let server = VMControlServer(
                socketPath: socketPath,
                handler: { [weak self] request in
                    guard let self else {
                        return VMControlResponse.failure(
                            id: request.id,
                            error: "The background host is shutting down."
                        )
                    }
                    return await self.handle(request)
                },
                onResponseSent: { [weak self] request in
                    guard case .shutdownHost = request.command else { return }
                    // The reply has been written; stopping from inside the
                    // handler would have raced that write.
                    Task { @MainActor [weak self] in
                        self?.requestShutdown()
                    }
                }
            )
            self.server = server
            try server.start()

            // `create` is idempotent for QEMU: it only fills in a missing disk,
            // EFI store or answer media. Calling it on every start also repairs
            // a bundle whose disk was removed rather than failing obscurely at
            // boot.
            try await engine.create(config, in: bundle)
            try await engine.start(config, in: bundle)

            let metadata = VMHostMetadata(
                pid: getpid(),
                socketPath: socketPath,
                startedAt: startedAt,
                engineIdentifier: QEMUEngine.identifier
            )
            try VMHostRuntime.writeMetadata(metadata, in: bundle)
            self.metadata = metadata

            installSignalHandlers()

            print("ready vm=\(config.id.uuidString.lowercased()) socket=\(socketPath) pid=\(getpid())")
            fflush(stdout)
        } catch {
            await cleanUpFailedStart()
            throw error
        }
    }

    private func acquireLock(in bundle: URL) throws {
        let lockURL = VMHostRuntime.lockFileURL(in: bundle)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else {
            throw HostExit(
                code: 2,
                message: "Could not open \(lockURL.path): \(String(cString: strerror(errno)))"
            )
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK {
                if let metadata = VMHostRuntime.readMetadata(in: bundle) {
                    throw HostExit(
                        code: 3,
                        message: "already running (pid \(metadata.pid))"
                    )
                }
                throw HostExit(
                    code: 3,
                    message: "already running (another MacportVMHost holds \(lockURL.path))"
                )
            }
            throw HostExit(
                code: 2,
                message: "Could not lock \(lockURL.path): \(String(cString: strerror(code)))"
            )
        }
        lockDescriptor = fd
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.requestShutdown()
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Run loop

    private func serve() {
        // A hosted VM's work happens in QEMU and on the control queue; the main
        // run loop exists to service signals and `shutdownHost`. The timer keeps
        // CFRunLoopRun from returning immediately on a Mac with no other main
        // run loop sources.
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in }
        CFRunLoopRun()
    }

    private func requestShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        CFRunLoopStop(CFRunLoopGetMain())
    }

    // MARK: Control commands

    private func handle(_ request: VMControlRequest) async -> VMControlResponse {
        guard let engine else {
            return .failure(id: request.id, error: "The engine is not available.")
        }

        do {
            switch request.command {
            case .status:
                return .success(id: request.id, payload: .status(currentStatus()))

            case .pause:
                try await engine.pause()
                return .success(id: request.id)

            case .resume:
                try await engine.resume()
                return .success(id: request.id)

            case .stop(let graceful):
                try await stopEngine(graceful: graceful, timeout: 8)
                return .success(id: request.id)

            case .snapshots:
                let snapshots = try await engine.listSnapshots()
                return .success(id: request.id, payload: .snapshots(snapshots))

            case .takeSnapshot(let name):
                let snapshot = try await engine.takeSnapshot(named: name)
                return .success(id: request.id, payload: .snapshot(snapshot))

            case .restoreSnapshot(let id):
                try await engine.restoreSnapshot(id: id)
                return .success(id: request.id)

            case .deleteSnapshot(let id):
                try await engine.deleteSnapshot(id: id)
                return .success(id: request.id)

            case .shutdownHost:
                // The response observer stops the host after this reply is on
                // the wire.
                return .success(id: request.id)

            case .unknown(let name):
                return .failure(id: request.id, error: "Unknown command '\(name)'.")
            }
        } catch {
            return .failure(id: request.id, error: error.localizedDescription)
        }
    }

    private func currentStatus() -> VMControlStatus {
        let state = engine?.state ?? .stopped
        return VMControlStatus(
            state: state,
            pid: metadata?.pid ?? getpid(),
            startedAt: metadata?.startedAt ?? startedAt,
            engineIdentifier: QEMUEngine.identifier,
            paused: state == .paused
        )
    }

    /// Ask the guest to stop, then escalate if it has not complied by `timeout`.
    ///
    /// The bound exists because a control client gives up after ten seconds; a
    /// wedged guest must still leave the host in a state it can report.
    private func stopEngine(graceful: Bool, timeout: TimeInterval) async throws {
        guard let engine, engine.state.isActive || engine.state == .error else { return }
        if !graceful {
            try await engine.forceStop()
            return
        }

        _ = Task { try? await engine.stop() }
        let deadline = Date().addingTimeInterval(timeout)
        while engine.state.isActive && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if engine.state.isActive {
            try await engine.forceStop()
        }
    }

    // MARK: Shutdown

    private func shutdown() async {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil

        // The engine needs no `if let`: `stopEngine` is a no-op once it is gone.
        try? await stopEngine(graceful: true, timeout: 10)

        server?.stop()
        server = nil

        if let bundle {
            VMHostRuntime.removeMetadata(in: bundle)
        }
        releaseLock()
        for source in signalSources { source.cancel() }
        signalSources.removeAll()
    }

    /// Undo everything a failed start put on disk or on screen.
    private func cleanUpFailedStart() async {
        if let engine, engine.state.isActive {
            try? await engine.forceStop()
        }
        server?.stop()
        server = nil
        if let bundle {
            VMHostRuntime.removeMetadata(in: bundle)
        }
        releaseLock()
    }

    private func releaseLock() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }
}
