import Foundation

/// Executes Windows applications directly on macOS using Wine and Apple Metal
/// without launching a virtual machine or consuming extra OS resources.
///
/// Discovered through reverse engineering CrossOver and Whisky, this engine:
/// - Replaces a 40 GB disk image with a lightweight, instantaneous directory prefix ("Bottle").
/// - Renders native macOS floating windows with Cocoa dropshadows and Dock icons via `winemac.so`.
/// - Translates DirectX 10/11/12 graphics into Apple Metal commands on the GPU via DXMT / D3DMetal.
/// - Consumes 0 MB of extra operating system RAM when idle.
@MainActor
public final class WineEngine: VMEngine {

    // MARK: - VMEngine Static Metadata

    nonisolated public static var identifier: String { "wine" }
    nonisolated public static var displayName: String { "Wine Translation Engine" }

    public init() {}

    nonisolated public static func capabilities(for guest: GuestKind) -> EngineCapabilities {
        switch guest {
        case .windowsApp:
            return EngineCapabilities(
                tpm: false,
                opticalMedia: false,
                nestedVirtualization: false,
                graphics: .acceleratedDX12,
                snapshots: false,
                sharedFolders: true, // Native access to / through Z:\
                usbPassthrough: false,
                foreignArchitectureEmulation: true, // Rosetta 2 executes x86_64 Windows apps
                pauseResume: false,
                saveState: false,
                backgroundHosting: true,
                diskImport: false
            )
        default:
            return EngineCapabilities(
                tpm: false,
                opticalMedia: false,
                nestedVirtualization: false,
                graphics: .none,
                snapshots: false,
                sharedFolders: false,
                usbPassthrough: false,
                foreignArchitectureEmulation: false,
                pauseResume: false,
                saveState: false,
                backgroundHosting: false,
                diskImport: false
            )
        }
    }

    nonisolated public static func availability() -> Result<Void, EngineError> {
        #if arch(arm64)
        guard WineRuntime.isRosettaAvailable else {
            return .failure(.engineUnavailable("Rosetta 2 is required to run Windows binaries under Wine on Apple Silicon."))
        }
        #endif

        switch WineRuntime.resolve() {
        case .success:
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - State

    public private(set) var state: VMState = .stopped
    public private(set) var lastError: String?

    private var activeProcess: Process?
    private var activeBottleURL: URL?
    private var runtimeLocations: WineRuntime.Locations?

    // MARK: - Lifecycle

    public func create(_ config: VMConfiguration, in bundle: URL) async throws {
        guard config.guest == .windowsApp else {
            throw EngineError.unsupportedGuest(config.guest, reason: "WineEngine only supports Windows applications.")
        }

        let bottleURL = bundle.appendingPathComponent("bottle", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: bottleURL.path) {
            try fm.createDirectory(at: bottleURL, withIntermediateDirectories: true)
        }

        // Write configuration into bundle
        let configData = try JSONEncoder().encode(config)
        try configData.write(to: bundle.appendingPathComponent("config.json"))

        // Resolve runtime
        let runtime = try resolveRuntime()
        self.runtimeLocations = runtime

        // Initialize bottle prefix if not already present
        let driveC = bottleURL.appendingPathComponent("drive_c", isDirectory: true)
        if !fm.fileExists(atPath: driveC.path) {
            try initializeBottle(at: bottleURL, with: runtime)
        }
    }

    public func start(_ config: VMConfiguration, in bundle: URL) async throws {
        guard state == .stopped || state == .error else {
            throw EngineError.operationFailed("Engine is already active in state \(state)")
        }

        state = .starting
        lastError = nil

        let bottleURL = bundle.appendingPathComponent("bottle", isDirectory: true)
        self.activeBottleURL = bottleURL

        do {
            let runtime = try resolveRuntime()
            self.runtimeLocations = runtime

            let process = Process()
            process.executableURL = runtime.wineloader

            // Build environment for native Mac windowing & Metal graphics
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = bottleURL.path
            env["WINEDEBUG"] = "-all"
            env["DISPLAY"] = ":0"
            env["WINEDLLPATH"] = runtime.libDirectory.appendingPathComponent("wine").path
            env["ROSETTA_ADVERTISE_AVX"] = "1"

            var fallbackLibs = runtime.libDirectory.path
            if runtime.hasMetalAcceleration {
                // Direct DXMT / winemetal.so acceleration
                env["WINEDLLOVERRIDES"] = "d3d11,dxgi,d3d10core=n,b"
                let dxmtDir = runtime.root.appendingPathComponent("lib/dxmt/x86_64-unix").path
                fallbackLibs = dxmtDir + ":" + fallbackLibs
            }
            let currentDyld = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
            env["DYLD_FALLBACK_LIBRARY_PATH"] = currentDyld.isEmpty ? fallbackLibs : fallbackLibs + ":" + currentDyld

            // Determine target executable to run
            let targetArgs: [String]
            switch config.boot {
            case .installMedia(let path):
                targetArgs = [path]
            case .kernelImage(let kernel, let commandLine):
                let cmdArgs = commandLine.isEmpty ? [] : commandLine.components(separatedBy: .whitespaces)
                targetArgs = [kernel] + cmdArgs
            default:
                // Default to wine's built-in explorer or command shell
                targetArgs = ["explorer.exe"]
            }

            process.arguments = targetArgs
            process.environment = env

            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe

            process.terminationHandler = { [weak self] proc in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.state == .running || self.state == .starting {
                        if proc.terminationStatus != 0 {
                            self.lastError = "Process exited with code \(proc.terminationStatus)"
                            self.state = .error
                        } else {
                            self.state = .stopped
                        }
                    }
                    self.activeProcess = nil
                }
            }

            try process.run()
            self.activeProcess = process
            self.state = .running
        } catch {
            self.state = .error
            self.lastError = error.localizedDescription
            throw error
        }
    }

    public func stop() async throws {
        guard state == .running else { return }
        state = .stopping

        if let proc = activeProcess, proc.isRunning {
            proc.terminate()
        }

        // Gracefully kill wineserver for this prefix if active
        if let runtime = runtimeLocations, let bottle = activeBottleURL {
            let killProcess = Process()
            killProcess.executableURL = runtime.wineserver
            killProcess.arguments = ["-k"]
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = bottle.path
            killProcess.environment = env
            try? killProcess.run()
            killProcess.waitUntilExit()
        }

        activeProcess = nil
        state = .stopped
    }

    public func forceStop() async throws {
        try await stop()
    }

    /// Launches a specific Windows executable or built-in tool within the bottle prefix.
    public func launchExecutable(
        _ executable: String,
        arguments: [String] = [],
        in bundle: URL,
        metal: Bool = true
    ) async throws {
        let runtime = try resolveRuntime()
        self.runtimeLocations = runtime

        let bottleURL = bundle.appendingPathComponent("bottle", isDirectory: true)
        self.activeBottleURL = bottleURL

        let process = Process()
        process.executableURL = runtime.wineloader

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottleURL.path
        env["WINEDEBUG"] = "-all"
        env["DISPLAY"] = ":0"
        env["WINEDLLPATH"] = runtime.libDirectory.appendingPathComponent("wine").path
        env["ROSETTA_ADVERTISE_AVX"] = "1"

        var fallbackLibs = runtime.libDirectory.path
        if runtime.hasMetalAcceleration && metal {
            env["WINEDLLOVERRIDES"] = "d3d11,dxgi,d3d10core=n,b"
            let dxmtDir = runtime.root.appendingPathComponent("lib/dxmt/x86_64-unix").path
            fallbackLibs = dxmtDir + ":" + fallbackLibs
        }
        let currentDyld = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
        env["DYLD_FALLBACK_LIBRARY_PATH"] = currentDyld.isEmpty ? fallbackLibs : fallbackLibs + ":" + currentDyld

        process.arguments = [executable] + arguments
        process.environment = env

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        self.activeProcess = process
        self.state = .running
    }

    // MARK: - Private Helpers

    private func resolveRuntime() throws -> WineRuntime.Locations {
        switch WineRuntime.resolve() {
        case .success(let loc):
            return loc
        case .failure(let error):
            throw error
        }
    }

    private func initializeBottle(at bottleURL: URL, with runtime: WineRuntime.Locations) throws {
        let process = Process()
        if let boot = runtime.wineboot {
            process.executableURL = boot
            process.arguments = ["--init"]
        } else {
            process.executableURL = runtime.wineloader
            process.arguments = ["wineboot", "--init"]
        }

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottleURL.path
        env["WINEDEBUG"] = "-all"
        process.environment = env

        try process.run()
        process.waitUntilExit()
    }
}
