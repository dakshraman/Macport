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
