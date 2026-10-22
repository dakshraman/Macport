import Foundation

/// Locates and inspects the Wine translation runtime used by `WineEngine`.
///
/// Mirroring `QEMURuntime`, resolution order runs from most self-contained to least:
/// 1. `MACPORT_WINE_DIR` environment override.
/// 2. The app bundle's `Contents/Resources/Runtime/Wine`.
/// 3. Macport's managed directory in Application Support (`~/Library/Application Support/Macport/Runtime/Wine`).
/// 4. Discovered host installations (CrossOver, Whisky, or Homebrew wine).
public enum WineRuntime: Sendable {

    public struct Locations: Sendable, Hashable {
        public let root: URL
        public let wineloader: URL
        public let wineserver: URL
        public let wineboot: URL?
        public let libDirectory: URL
        public let hasMetalAcceleration: Bool

        public init(
            root: URL,
            wineloader: URL,
            wineserver: URL,
            wineboot: URL? = nil,
            libDirectory: URL,
            hasMetalAcceleration: Bool = false
        ) {
            self.root = root
            self.wineloader = wineloader
            self.wineserver = wineserver
            self.wineboot = wineboot
            self.libDirectory = libDirectory
            self.hasMetalAcceleration = hasMetalAcceleration
        }
    }

    // MARK: - Standard Directories

    /// Where Macport keeps runtime dependencies it manages.
    nonisolated public static var managedDirectory: URL {
        VMStore.defaultRoot
            .deletingLastPathComponent()
            .appendingPathComponent("Runtime", isDirectory: true)
    }

    /// The vendored Wine directory inside Macport's support directory.
    nonisolated public static var managedRuntimeDirectory: URL {
        managedDirectory.appendingPathComponent("Wine", isDirectory: true)
    }

    /// Where a bundled runtime lives inside an application bundle.
    nonisolated public static func bundledRuntimeDirectory(in bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("Wine", isDirectory: true)
    }

    // MARK: - Resolution

    /// Discovers an available Wine runtime on this Mac, trying candidates in priority order.
    nonisolated public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> Result<Locations, EngineError> {
        var searched: [String] = []

        // 1. Explicit environment override
        if let override = environment["MACPORT_WINE_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if let loc = inspectRuntime(at: url) {
                return .success(loc)
            }
            searched.append("MACPORT_WINE_DIR (\(override))")
        }

        // 2. App bundle runtime
        if let bundled = bundledRuntimeDirectory(in: bundle) {
            if let loc = inspectRuntime(at: bundled) {
                return .success(loc)
            }
            searched.append("app bundle (\(bundled.path))")
        }

        // 3. Managed runtime in Application Support
        let managed = managedRuntimeDirectory
        if let loc = inspectRuntime(at: managed) {
            return .success(loc)
        }
        searched.append("Application Support (\(managed.path))")

        // 4. Discovered host installations (CrossOver, Whisky, Homebrew)
        let homeAppDir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Applications", isDirectory: true)
        let hostCandidates: [URL] = [
            homeAppDir.appendingPathComponent("CrossOver.app/Contents/SharedSupport/CrossOver", isDirectory: true),
            URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver", isDirectory: true),
            URL(fileURLWithPath: "/private/tmp/crossover_inspect/CrossOver.app/Contents/SharedSupport/CrossOver", isDirectory: true),
            homeAppDir.appendingPathComponent("Whisky.app/Contents/Resources/Wine", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Whisky.app/Contents/Resources/Wine", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew", isDirectory: true),
            URL(fileURLWithPath: "/usr/local", isDirectory: true)
        ]

        for candidate in hostCandidates {
            if let loc = inspectRuntime(at: candidate) {
                return .success(loc)
            }
            searched.append(candidate.path)
        }

        return .failure(.runtimeMissing(
            engine: "Wine",
            detail: "No Wine translation runtime was found. Searched: " + searched.joined(separator: ", ")
        ))
    }

    /// Inspects a candidate directory to verify if it contains a functional Wine runtime.
    nonisolated private static func inspectRuntime(at directory: URL) -> Locations? {
        let fm = FileManager.default

        // Check for binary locations: either bin/ or CrossOver's bin symlink/directory
        let candidateBins = [
            directory.appendingPathComponent("bin", isDirectory: true),
            directory.appendingPathComponent("CrossOver-Hosted Application", isDirectory: true),
            directory
        ]

        var loaderURL: URL?
        var serverURL: URL?
        var bootURL: URL?

        for bin in candidateBins {
            let loader = bin.appendingPathComponent("wineloader")
            if fm.isExecutableFile(atPath: loader.path) {
                loaderURL = loader
            } else {
                let wine64 = bin.appendingPathComponent("wine64")
                if fm.isExecutableFile(atPath: wine64.path) {
                    loaderURL = wine64
                }
            }

            let server = bin.appendingPathComponent("wineserver")
            if fm.isExecutableFile(atPath: server.path) {
                serverURL = server
            }

            let boot = bin.appendingPathComponent("wineboot")
            if fm.isExecutableFile(atPath: boot.path) {
                bootURL = boot
            }
        }

        guard let wineloader = loaderURL, let wineserver = serverURL else {
            return nil
        }

        let libDir = directory.appendingPathComponent("lib", isDirectory: true)

        // Check for DXMT / winemetal.so or D3DMetal acceleration
        let dxmtDir = directory.appendingPathComponent("lib/dxmt", isDirectory: true)
        let hasDXMT = fm.fileExists(atPath: dxmtDir.path)

        return Locations(
            root: directory,
            wineloader: wineloader,
            wineserver: wineserver,
            wineboot: bootURL,
            libDirectory: libDir,
            hasMetalAcceleration: hasDXMT
        )
    }

    /// Checks whether Rosetta 2 translation is functional on an Apple Silicon host.
    nonisolated public static var isRosettaAvailable: Bool {
        #if arch(arm64)
        // Check if Rosetta 2 translation daemon or oahd is functional
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", "/usr/bin/true"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
        #else
        return true
        #endif
    }
}

/// Represents a launchable application or tool inside a Wine bottle prefix.
public struct WineProgramShortcut: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let executable: String
    public let arguments: [String]
    public let iconSystemName: String
    public let isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        executable: String,
        arguments: [String] = [],
        iconSystemName: String,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.iconSystemName = iconSystemName
        self.isBuiltIn = isBuiltIn
    }
}

/// Provides CrossOver-style bottle prefix inspection, installed application discovery,
/// and management for Windows apps running under `WineEngine`.
public enum WineBottleManager: Sendable {

    /// Standard Windows and Wine utilities available in every bottle.
    public static let builtInTools: [WineProgramShortcut] = [
        WineProgramShortcut(
            id: "winecfg",
            name: "Wine Configuration",
            executable: "winecfg",
            iconSystemName: "gearshape.2.fill",
            isBuiltIn: true
        ),
        WineProgramShortcut(
            id: "regedit",
            name: "Registry Editor",
            executable: "regedit",
            iconSystemName: "archivebox.fill",
            isBuiltIn: true
        ),
        WineProgramShortcut(
            id: "taskmgr",
            name: "Task Manager",
            executable: "taskmgr",
            iconSystemName: "chart.bar.xaxis",
            isBuiltIn: true
        ),
        WineProgramShortcut(
            id: "cmd",
            name: "Command Prompt",
            executable: "cmd.exe",
            iconSystemName: "terminal.fill",
            isBuiltIn: true
        ),
        WineProgramShortcut(
            id: "explorer",
            name: "File Explorer",
            executable: "explorer.exe",
            iconSystemName: "folder.fill",
            isBuiltIn: true
        ),
        WineProgramShortcut(
            id: "control",
            name: "Control Panel",
            executable: "control.exe",
            iconSystemName: "slider.horizontal.3",
            isBuiltIn: true
        )
    ]

    /// Returns the URL of the bottle prefix directory inside a VM bundle.
    public static func bottleURL(for bundle: URL) -> URL {
        bundle.appendingPathComponent("bottle", isDirectory: true)
    }

    /// Returns the URL of the simulated C: drive (`drive_c`) inside a bottle prefix.
    public static func driveCURL(for bundle: URL) -> URL {
        bottleURL(for: bundle).appendingPathComponent("drive_c", isDirectory: true)
    }

    /// Checks if a bottle prefix has been initialized with a valid `drive_c`.
    public static func isBottleInitialized(in bundle: URL) -> Bool {
        let driveC = driveCURL(for: bundle)
        return FileManager.default.fileExists(atPath: driveC.path)
    }

    /// Calculates the disk footprint of the bottle's `drive_c`.
    public static func calculateBottleSize(in bundle: URL) -> UInt64 {
        let driveC = driveCURL(for: bundle)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: driveC, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    /// Scans a bottle for installed Windows applications (.exe / .lnk) in common installation paths.
    public static func scanInstalledShortcuts(in bundle: URL) -> [WineProgramShortcut] {
        let driveC = driveCURL(for: bundle)
        let fm = FileManager.default
        guard fm.fileExists(atPath: driveC.path) else { return [] }

        var results: [WineProgramShortcut] = []
        var seenPaths = Set<String>()

        // Search common application locations
        let searchDirectories: [URL] = [
            driveC.appendingPathComponent("Program Files", isDirectory: true),
            driveC.appendingPathComponent("Program Files (x86)", isDirectory: true),
            driveC.appendingPathComponent("users", isDirectory: true),
            driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs", isDirectory: true)
        ]

        for dir in searchDirectories where fm.fileExists(atPath: dir.path) {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if ext == "exe" {
                    let filename = fileURL.lastPathComponent
                    let lowerName = filename.lowercased()
                    // Filter out uninstaller and helper binaries
                    if lowerName.contains("unins") || lowerName.contains("update") || lowerName.contains("crash") || lowerName.contains("helper") {
                        continue
                    }

                    let path = fileURL.path
                    if !seenPaths.contains(path) {
                        seenPaths.insert(path)
                        let baseName = fileURL.deletingPathExtension().lastPathComponent
                        let iconName = baseName.lowercased().contains("steam") ? "gamecontroller.fill" : "app.fill"
                        results.append(WineProgramShortcut(
                            id: path,
                            name: baseName,
                            executable: path,
                            arguments: [],
                            iconSystemName: iconName,
                            isBuiltIn: false
                        ))
                    }
                }
            }
        }

        return results
    }

    /// Terminates lingering `wineserver` background processes for a bottle prefix.
    public static func killBottleProcesses(in bundle: URL) throws {
        guard let runtime = try? WineRuntime.resolve().get() else { return }
        let bottle = bottleURL(for: bundle)
        let killProcess = Process()
        killProcess.executableURL = runtime.wineserver
        killProcess.arguments = ["-k"]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.path
        killProcess.environment = env
        try? killProcess.run()
        killProcess.waitUntilExit()
    }
}

