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

        let wineSettings = config.wineSettings ?? WineBottleSettings()

        // Initialize CrossOver bottle prefix if not already present
        let driveC = bottleURL.appendingPathComponent("drive_c", isDirectory: true)
        if !fm.fileExists(atPath: driveC.path) {
            try WineBottleManager.createBottle(
                in: bundle,
                name: config.name,
                template: wineSettings.bottleTemplate,
                wineSettings: wineSettings,
                runtime: runtime
            )
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
            let fm = FileManager.default

            let process = Process()

            // Build complete CrossOver-grade gaming environment (D3DMetal, MSync, MetalFX, AVX)
            let env = buildEnvironment(
                settings: config.wineSettings ?? WineBottleSettings(),
                bottleURL: bottleURL,
                runtime: runtime
            )

            // Determine target executable and working directory
            let targetArgs: [String]
            var workingDir: URL?

            if let primary = config.wineSettings?.primaryExecutable, !primary.isEmpty {
                targetArgs = [primary]
                if primary.hasPrefix("/") {
                    workingDir = URL(fileURLWithPath: primary).deletingLastPathComponent()
                }
            } else {
                let shortcuts = WineBottleManager.scanInstalledShortcuts(in: bundle)
                // Prefer installed launcher/game over installer media
                if let mainShortcut = shortcuts.first(where: {
                    let low = $0.name.lowercased()
                    return low.contains("launcher") || low.contains("game") || low.contains("genshin") || low.contains("steam")
                }) ?? shortcuts.first {
                    targetArgs = [mainShortcut.executable]
                    workingDir = URL(fileURLWithPath: mainShortcut.executable).deletingLastPathComponent()
                } else {
                    switch config.boot {
                    case .installMedia(let path):
                        targetArgs = [path]
                        workingDir = URL(fileURLWithPath: path).deletingLastPathComponent()
                    case .kernelImage(let kernel, let commandLine):
                        let cmdArgs = commandLine.isEmpty ? [] : commandLine.components(separatedBy: .whitespaces)
                        targetArgs = [kernel] + cmdArgs
                    default:
                        targetArgs = ["explorer.exe"]
                    }
                }
            }

            if let wd = workingDir, fm.fileExists(atPath: wd.path) {
                process.currentDirectoryURL = wd
            } else {
                let driveC = WineBottleManager.driveCURL(for: bundle)
                if fm.fileExists(atPath: driveC.path) {
                    process.currentDirectoryURL = driveC
                }
            }

            if let wineBin = runtime.wine, runtime.cxbottle != nil {
                process.executableURL = wineBin
                let bottleName = bottleURL.resolvingSymlinksInPath().lastPathComponent
                process.arguments = ["--bottle", bottleName] + targetArgs
            } else {
                process.executableURL = runtime.wineloader
                process.arguments = targetArgs
            }

            process.environment = env

            // Redirect output to machine log to avoid unread Pipe() buffer deadlock
            let logURL = bundle.appendingPathComponent("wine.log")
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: nil)
            }
            if let logHandle = try? FileHandle(forWritingTo: logURL) {
                logHandle.seekToEndOfFile()
                process.standardOutput = logHandle
                process.standardError = logHandle
            } else {
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
            }

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
        metal: Bool = true,
        settings: WineBottleSettings? = nil
    ) async throws {
        let runtime = try resolveRuntime()
        self.runtimeLocations = runtime

        let bottleURL = bundle.appendingPathComponent("bottle", isDirectory: true)
        self.activeBottleURL = bottleURL

        let process = Process()
        var effectiveSettings = settings ?? WineBottleSettings()
        if !metal {
            effectiveSettings.backend = .wined3d
        }

        let env = buildEnvironment(
            settings: effectiveSettings,
            bottleURL: bottleURL,
            runtime: runtime
        )

        let targetArgs = [executable] + arguments

        if let wineBin = runtime.wine, runtime.cxbottle != nil {
            process.executableURL = wineBin
            let bottleName = bottleURL.resolvingSymlinksInPath().lastPathComponent
            process.arguments = ["--bottle", bottleName] + targetArgs
        } else {
            process.executableURL = runtime.wineloader
            process.arguments = targetArgs
        }

        process.environment = env

        if executable.hasPrefix("/") {
            let dir = URL(fileURLWithPath: executable).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.path) {
                process.currentDirectoryURL = dir
            }
        } else {
            let driveC = WineBottleManager.driveCURL(for: bundle)
            if FileManager.default.fileExists(atPath: driveC.path) {
                process.currentDirectoryURL = driveC
            }
        }

        let fm = FileManager.default
        let logURL = bundle.appendingPathComponent("wine.log")
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            logHandle.seekToEndOfFile()
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .running {
                    self.state = .stopped
                }
                self.activeProcess = nil
            }
        }

        try process.run()
        self.activeProcess = process
        self.state = .running
    }

    // MARK: - Environment & Graphics Pipeline Construction

    nonisolated private func buildEnvironment(
        settings: WineBottleSettings,
        bottleURL: URL,
        runtime: WineRuntime.Locations
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // 1. Core Bottle Paths & Logging
        env["WINEPREFIX"] = bottleURL.path
        env["CX_ROOT"] = runtime.root.path
        env["CX_BOTTLE"] = bottleURL.resolvingSymlinksInPath().lastPathComponent
        env["WINEDEBUG"] = "-all"
        env["DISPLAY"] = ":0"

        // 2. Performance & Game Launch Optimizations
        if settings.msyncEnabled {
            env["WINEMSYNC"] = "1"
        } else {
            env["WINEMSYNC"] = "0"
        }
        env["ROSETTA_ADVERTISE_AVX"] = "1"
        env["DOTNET_EnableWriteXorExecute"] = "0"
        env["WINE_WAIT_CHILD_PIPE_IGNORE"] = "launcher.exe;GenshinImpact.exe;YuanShen.exe;ZFGameBrowser.exe;crashpad_handler.exe"

        if settings.hudEnabled {
            env["MTL_HUD_ENABLED"] = "1"
            env["WINE_D3DMETAL_PERF_OVERLAY"] = "1"
        }

        if settings.metalFXEnabled {
            env["D3DM_ENABLE_METALFX"] = "1"
            env["DXMT_ENABLE_NVEXT"] = "1"
        }

        if settings.retinaMode {
            env["WINE_MAC_HIGH_RES"] = "1"
        }

        // 3. Dynamic WINEDLLPATH Setup
        var dllPaths: [String] = []
        let x86Windows = runtime.root.appendingPathComponent("lib/wine/x86_64-windows")
        let i386Windows = runtime.root.appendingPathComponent("lib/wine/i386-windows")
        let wineUnix = runtime.libDirectory.appendingPathComponent("wine")

        if FileManager.default.fileExists(atPath: x86Windows.path) {
            dllPaths.append(x86Windows.path)
        }
        if FileManager.default.fileExists(atPath: i386Windows.path) {
            dllPaths.append(i386Windows.path)
        }
        dllPaths.append(wineUnix.path)
        env["WINEDLLPATH"] = dllPaths.joined(separator: ":")

        // 4. Graphics Backend & Dynamic Library Fallback Path
        var fallbackPaths: [String] = []
        let lib64 = runtime.root.appendingPathComponent("lib64")
        if FileManager.default.fileExists(atPath: lib64.path) {
            fallbackPaths.append(lib64.path)
        }
        fallbackPaths.append(runtime.libDirectory.path)

        // Resolve backend selection
        let effectiveBackend: GraphicsBackend
        if settings.backend == .auto {
            if runtime.hasD3DMetal {
                effectiveBackend = .d3dmetal
            } else if runtime.hasDXMT {
                effectiveBackend = .dxmt
            } else if runtime.hasDXVK {
                effectiveBackend = .dxvk
            } else {
                effectiveBackend = .wined3d
            }
        } else {
            effectiveBackend = settings.backend
        }

        switch effectiveBackend {
        case .d3dmetal:
            env["CX_GRAPHICS_BACKEND"] = "d3dmetal"
            env["WINED3DMETAL"] = "1"
            env["WINEDLLOVERRIDES"] = "d3d11,d3d12,dxgi=n,b"
            if let d3dshared = runtime.d3dsharedPath {
                env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = d3dshared.path
            }
            if let fwk = runtime.d3dmetalFrameworkPath {
                fallbackPaths.insert(fwk.deletingLastPathComponent().path, at: 0)
            }
        case .dxmt:
            env["CX_GRAPHICS_BACKEND"] = "dxmt"
            env["WINEDLLOVERRIDES"] = "d3d11,dxgi,d3d10core=n,b"
            let dxmtDir = runtime.root.appendingPathComponent("lib/dxmt/x86_64-unix").path
            fallbackPaths.insert(dxmtDir, at: 0)
        case .dxvk:
            env["CX_GRAPHICS_BACKEND"] = "dxvk"
            env["WINEDLLOVERRIDES"] = "d3d11,d3d10core,d3d9,dxgi=n,b"
            let dxvkDir = runtime.root.appendingPathComponent("lib/dxvk").path
            fallbackPaths.insert(dxvkDir, at: 0)
        case .wined3d:
            env["CX_GRAPHICS_BACKEND"] = "wined3d"
        case .auto:
            break
        }

        let existingDyld = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
        let combinedFallback = fallbackPaths.joined(separator: ":")
        env["DYLD_FALLBACK_LIBRARY_PATH"] = existingDyld.isEmpty
            ? combinedFallback
            : combinedFallback + ":" + existingDyld

        return env
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
