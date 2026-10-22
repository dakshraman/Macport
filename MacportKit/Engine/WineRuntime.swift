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
        public let hasD3DMetal: Bool
        public let hasDXMT: Bool
        public let hasDXVK: Bool
        public let d3dsharedPath: URL?
        public let d3dmetalFrameworkPath: URL?
        public let cxbottle: URL?

        public init(
            root: URL,
            wineloader: URL,
            wineserver: URL,
            wineboot: URL? = nil,
            libDirectory: URL,
            hasMetalAcceleration: Bool = false,
            hasD3DMetal: Bool = false,
            hasDXMT: Bool = false,
            hasDXVK: Bool = false,
            d3dsharedPath: URL? = nil,
            d3dmetalFrameworkPath: URL? = nil,
            cxbottle: URL? = nil
        ) {
            self.root = root
            self.wineloader = wineloader
            self.wineserver = wineserver
            self.wineboot = wineboot
            self.libDirectory = libDirectory
            self.hasMetalAcceleration = hasMetalAcceleration
            self.hasD3DMetal = hasD3DMetal
            self.hasDXMT = hasDXMT
            self.hasDXVK = hasDXVK
            self.d3dsharedPath = d3dsharedPath
            self.d3dmetalFrameworkPath = d3dmetalFrameworkPath
            self.cxbottle = cxbottle
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

        // Check for DXMT / winemetal.so acceleration
        let dxmtDir = directory.appendingPathComponent("lib/dxmt", isDirectory: true)
        let hasDXMT = fm.fileExists(atPath: dxmtDir.path)

        // Check for DXVK (Direct3D to Vulkan via MoltenVK)
        let dxvkDir = directory.appendingPathComponent("lib/dxvk", isDirectory: true)
        let hasDXVK = fm.fileExists(atPath: dxvkDir.path)

        // Check for Apple GPTK / D3DMetal acceleration
        var d3dshared: URL?
        var d3dmetalFwk: URL?

        let candidateD3DShared = [
            directory.appendingPathComponent("lib64/apple_gptk/external/libd3dshared.dylib"),
            directory.appendingPathComponent("lib/apple_gptk/external/libd3dshared.dylib"),
            directory.appendingPathComponent("lib/libd3dshared.dylib")
        ]
        for candidate in candidateD3DShared {
            if fm.fileExists(atPath: candidate.path) {
                d3dshared = candidate
                break
            }
        }

        let candidateD3DFwks = [
            directory.appendingPathComponent("lib64/apple_gptk/external/D3DMetal.framework", isDirectory: true),
            directory.appendingPathComponent("lib/apple_gptk/external/D3DMetal.framework", isDirectory: true),
            directory.appendingPathComponent("Frameworks/D3DMetal.framework", isDirectory: true)
        ]
        for candidate in candidateD3DFwks {
            if fm.fileExists(atPath: candidate.path) {
                d3dmetalFwk = candidate
                break
            }
        }

        let hasD3DMetal = d3dmetalFwk != nil
        let hasMetalAcceleration = hasD3DMetal || hasDXMT

        var cxbottleURL: URL?
        let candidateCxbottles = [
            directory.appendingPathComponent("bin/cxbottle"),
            directory.appendingPathComponent("share/crossover/cxbottle"),
            directory.appendingPathComponent("CrossOver-Hosted Application/cxbottle")
        ]
        for candidate in candidateCxbottles {
            if fm.isExecutableFile(atPath: candidate.path) {
                cxbottleURL = candidate
                break
            }
        }

        return Locations(
            root: directory,
            wineloader: wineloader,
            wineserver: wineserver,
            wineboot: bootURL,
            libDirectory: libDir,
            hasMetalAcceleration: hasMetalAcceleration,
            hasD3DMetal: hasD3DMetal,
            hasDXMT: hasDXMT,
            hasDXVK: hasDXVK,
            d3dsharedPath: d3dshared,
            d3dmetalFrameworkPath: d3dmetalFwk,
            cxbottle: cxbottleURL
        )
    }

    /// Directory where CrossOver stores its user bottles on macOS.
    nonisolated public static var crossoverBottlesDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
        .appendingPathComponent("CrossOver", isDirectory: true)
        .appendingPathComponent("Bottles", isDirectory: true)
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
    }

    /// Discovers existing CrossOver bottles on the host system.
    nonisolated public static func existingCrossOverBottles() -> [(name: String, url: URL)] {
        let dir = crossoverBottlesDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return items.compactMap { url -> (name: String, url: URL)? in
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let driveC = url.appendingPathComponent("drive_c")
                let hasC = FileManager.default.fileExists(atPath: driveC.path)
                let hasConf = FileManager.default.fileExists(atPath: url.appendingPathComponent("cxbottle.conf").path)
                if hasC || hasConf {
                    return (name: url.lastPathComponent, url: url)
                }
            }
            return nil
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Checks whether Rosetta 2 translation is functional on an Apple Silicon host.
    /// Evaluated statically to avoid blocking the main thread or causing
    /// SwiftUI AttributeGraph update re-entrancy precondition failures.
    nonisolated public static let isRosettaAvailable: Bool = {
        #if arch(arm64)
        // Check for presence of Rosetta 2 oahd / libRosettaRuntime without blocking subprocess execution
        let oahdPath = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"
        let altOahdPath = "/usr/libexec/rosetta/oahd"
        return FileManager.default.fileExists(atPath: oahdPath) || FileManager.default.fileExists(atPath: altOahdPath)
        #else
        return true
        #endif
    }()
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

    /// Generates genuine CrossOver `cxbottle.conf` file contents.
    public static func generateCrossOverConfig(
        template: String = "win11_64",
        wineSettings: WineBottleSettings = WineBottleSettings(),
        bottleID: UUID = UUID()
    ) -> String {
        let backendStr: String
        switch wineSettings.backend {
        case .auto, .d3dmetal: backendStr = "d3dmetal"
        case .dxmt: backendStr = "dxmt"
        case .dxvk: backendStr = "dxvk"
        case .wined3d: backendStr = "wined3d"
        }

        var envLines = [
            "\"CX_BOTTLE_CREATOR_APPID\" = \"com.codeweavers.unknown\"",
            "\"CX_GRAPHICS_BACKEND\" = \"\(backendStr)\"",
            "\"ROSETTA_ADVERTISE_AVX\" = \"1\"",
            "\"DOTNET_EnableWriteXorExecute\" = \"0\"",
            "\"WINE_WAIT_CHILD_PIPE_IGNORE\" = \"launcher.exe;GenshinImpact.exe;YuanShen.exe;ZFGameBrowser.exe;crashpad_handler.exe\""
        ]
        if wineSettings.msyncEnabled {
            envLines.append("\"WINEMSYNC\" = \"1\"")
        }
        if wineSettings.metalFXEnabled {
            envLines.append("\"D3DM_ENABLE_METALFX\" = \"1\"")
            envLines.append("\"DXMT_ENABLE_NVEXT\" = \"1\"")
        }
        if wineSettings.hudEnabled {
            envLines.append("\"MTL_HUD_ENABLED\" = \"1\"")
        }
        if wineSettings.retinaMode {
            envLines.append("\"WINE_MAC_HIGH_RES\" = \"1\"")
        }

        return """
        ;;----------------------------------------------------------------------
        ;;  CrossOver Bottle Configuration File
        ;;----------------------------------------------------------------------
        [Bottle]
        "MenuRoot" = "/Windows Applications"
        "MenuStrip" = "1"
        "BottleID" = "\(bottleID.uuidString)"
        "Version" = "26.3.0.39832"
        "Timestamp" = "20260715T103801Z"
        "Encoding" = "UTF-8"
        "Template" = "\(template)"
        "MenuMode" = "install"
        "AssocMode" = "install"
        "WineArch" = "win64"

        [ManagedUpdatePolicy]
        "^\\\\.wineserver$" = "Delete"
        "^desktopdata(?:/|$)" = "LinkDir"
        "^windata(?:/|$)" = "LinkDir"
        "^cxbottle\\\\.conf$" = "Link,ReplaceFiles"
        "^system\\\\.reg$" = "Registry,ReplaceFiles,ReplaceConflicting"
        "^userdef\\\\.reg$" = "Registry,ReplaceConflicting"
        "^user\\\\.reg$" = "Registry,ReplaceConflicting"

        [EnvironmentVariables]
        \(envLines.joined(separator: "\n"))
        """
    }

    /// Links an existing CrossOver bottle directly into a Macport VM bundle.
    public static func linkCrossOverBottle(
        named bottleName: String,
        into bundle: URL
    ) throws {
        let fm = FileManager.default
        let sourceURL = WineRuntime.crossoverBottlesDirectory.appendingPathComponent(bottleName, isDirectory: true)
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw EngineError.operationFailed("CrossOver bottle '\(bottleName)' was not found at \(sourceURL.path)")
        }

        let destination = bottleURL(for: bundle)
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        try fm.createSymbolicLink(at: destination, withDestinationURL: sourceURL)
    }

    /// Creates an authentic CrossOver-grade bottle prefix with complete template and config structure.
    public static func createBottle(
        in bundle: URL,
        name: String,
        template: String = "win11_64",
        wineSettings: WineBottleSettings = WineBottleSettings(),
        runtime: WineRuntime.Locations
    ) throws {
        let fm = FileManager.default
        let bundleBottle = bottleURL(for: bundle)

        // If user requested linking to an existing CrossOver bottle:
        if let linked = wineSettings.linkedCrossOverBottle, !linked.isEmpty {
            try linkCrossOverBottle(named: linked, into: bundle)
            return
        }

        // If CrossOver's cxbottle utility is available, create authentic CrossOver bottle
        if let cxbottle = runtime.cxbottle {
            let sanitizedName = name
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let coBottlesDir = WineRuntime.crossoverBottlesDirectory
            let targetBottleURL = coBottlesDir.appendingPathComponent(sanitizedName, isDirectory: true)

            if !fm.fileExists(atPath: targetBottleURL.path) {
                let proc = Process()
                proc.executableURL = cxbottle
                proc.arguments = ["--bottle", sanitizedName, "--create", "--template", template]
                var env = ProcessInfo.processInfo.environment
                env["CX_ROOT"] = runtime.root.path
                proc.environment = env
                try proc.run()
                proc.waitUntilExit()
            }

            if fm.fileExists(atPath: targetBottleURL.path) {
                // Link into Macport VM bundle
                if fm.fileExists(atPath: bundleBottle.path) {
                    try? fm.removeItem(at: bundleBottle)
                }
                try fm.createSymbolicLink(at: bundleBottle, withDestinationURL: targetBottleURL)

                // Write/update cxbottle.conf with gaming settings
                let confContent = generateCrossOverConfig(template: template, wineSettings: wineSettings)
                let confURL = targetBottleURL.appendingPathComponent("cxbottle.conf")
                try? confContent.write(to: confURL, atomically: true, encoding: .utf8)
                return
            }
        }

        // Fallback or Standalone Wine Bottle Creation:
        try fm.createDirectory(at: bundleBottle, withIntermediateDirectories: true)

        // Setup dosdevices
        let dosdevices = bundleBottle.appendingPathComponent("dosdevices", isDirectory: true)
        try fm.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        let linkC = dosdevices.appendingPathComponent("c:")
        if !fm.fileExists(atPath: linkC.path) {
            try? fm.createSymbolicLink(at: linkC, withDestinationURL: URL(fileURLWithPath: "../drive_c"))
        }
        let linkY = dosdevices.appendingPathComponent("y:")
        if !fm.fileExists(atPath: linkY.path) {
            try? fm.createSymbolicLink(at: linkY, withDestinationURL: URL(fileURLWithPath: NSHomeDirectory()))
        }
        let linkZ = dosdevices.appendingPathComponent("z:")
        if !fm.fileExists(atPath: linkZ.path) {
            try? fm.createSymbolicLink(at: linkZ, withDestinationURL: URL(fileURLWithPath: "/"))
        }

        // Write cxbottle.conf
        let confContent = generateCrossOverConfig(template: template, wineSettings: wineSettings)
        try confContent.write(to: bundleBottle.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)

        // Initialize system.reg placeholder to prevent wine race condition
        let sysReg = bundleBottle.appendingPathComponent("system.reg")
        if !fm.fileExists(atPath: sysReg.path) {
            let initialReg = "WINE REGISTRY Version 2\n#arch=win64\n"
            try? initialReg.write(to: sysReg, atomically: true, encoding: .utf8)
        }

        // Run wineboot --init
        let process = Process()
        if let boot = runtime.wineboot {
            process.executableURL = boot
            process.arguments = ["--init"]
        } else {
            process.executableURL = runtime.wineloader
            process.arguments = ["wineboot", "--init"]
        }

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bundleBottle.path
        env["WINEDEBUG"] = "-all"
        env["ROSETTA_ADVERTISE_AVX"] = "1"
        env["DOTNET_EnableWriteXorExecute"] = "0"
        process.environment = env

        try process.run()
        process.waitUntilExit()
    }
}

