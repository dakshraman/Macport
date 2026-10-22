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
        public let wine: URL?

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
            cxbottle: URL? = nil,
            wine: URL? = nil
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
            self.wine = wine
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

        var wineURL: URL?
        let candidateWines = [
            directory.appendingPathComponent("bin/wine"),
            directory.appendingPathComponent("bin/wine64"),
            directory.appendingPathComponent("CrossOver-Hosted Application/wine")
        ]
        for candidate in candidateWines {
            if fm.isExecutableFile(atPath: candidate.path) {
                wineURL = candidate
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
            cxbottle: cxbottleURL,
            wine: wineURL
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
    public let iconURL: URL?
    public let isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        executable: String,
        arguments: [String] = [],
        iconSystemName: String,
        iconURL: URL? = nil,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.iconSystemName = iconSystemName
        self.iconURL = iconURL
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

    /// Scans a bottle for installed Windows applications (.exe / .lnk) in common installation paths,
    /// matching CrossOver's authentic curated shortcut model with high-resolution app icon resolution.
    public static func scanInstalledShortcuts(in bundle: URL) -> [WineProgramShortcut] {
        let driveC = driveCURL(for: bundle)
        let actualBottle = bottleURL(for: bundle).resolvingSymlinksInPath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: driveC.path) else { return [] }

        var results: [WineProgramShortcut] = []
        var seenExecutables = Set<String>()
        var seenNames = Set<String>()

        // Ignored executable keywords (helpers, redistributables, unpackers, uninstallers, wine builtins)
        let blacklistedTokens: [String] = [
            "unins", "repair", "update", "crash", "helper", "worker", "safemode", "patch",
            "7z", "vc_redist", "vcredist", "dxsetup", "redist", "wmplayer", "wordpad", "iexplore",
            "notepad", "regedit", "winecfg", "taskmgr", "cmd", "explorer", "control", "setup",
            "feedback", "manual", "website", "dxdiag", "upload_crash", "crashreport"
        ]

        func isBlacklisted(_ str: String) -> Bool {
            let low = str.lowercased()
            return blacklistedTokens.contains { low.contains($0) }
        }

        // 1. Scan genuine Windows desktop and Start Menu shortcuts (.lnk files)
        var lnkDirectories: [URL] = [
            driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs", isDirectory: true)
        ]

        let usersDir = driveC.appendingPathComponent("users", isDirectory: true)
        if let userDirs = try? fm.contentsOfDirectory(at: usersDir, includingPropertiesForKeys: nil) {
            for u in userDirs {
                lnkDirectories.append(u.appendingPathComponent("Desktop", isDirectory: true))
                lnkDirectories.append(u.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu/Programs", isDirectory: true))
            }
        }

        for dir in lnkDirectories where fm.fileExists(atPath: dir.path) {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension.lowercased() == "lnk" {
                    let shortcutName = fileURL.deletingPathExtension().lastPathComponent
                    if isBlacklisted(shortcutName) { continue }

                    if let targetExe = extractTargetFromLnk(at: fileURL, driveC: driveC) {
                        let baseExeName = URL(fileURLWithPath: targetExe).deletingPathExtension().lastPathComponent
                        if isBlacklisted(baseExeName) { continue }

                        if !seenExecutables.contains(targetExe) && !seenNames.contains(shortcutName.lowercased()) {
                            seenExecutables.insert(targetExe)
                            seenNames.insert(shortcutName.lowercased())

                            let icon = findIcon(for: shortcutName, executable: targetExe, in: actualBottle)
                            let iconSys = shortcutName.lowercased().contains("genshin") || shortcutName.lowercased().contains("game") || shortcutName.lowercased().contains("steam") ? "gamecontroller.fill" : "app.fill"

                            results.append(WineProgramShortcut(
                                id: targetExe,
                                name: shortcutName,
                                executable: targetExe,
                                arguments: [],
                                iconSystemName: iconSys,
                                iconURL: icon,
                                isBuiltIn: false
                            ))
                        }
                    }
                }
            }
        }

        // 2. Scan primary Program Files and Program Files (x86) top-level directories
        let programFilesDirs = [
            driveC.appendingPathComponent("Program Files", isDirectory: true),
            driveC.appendingPathComponent("Program Files (x86)", isDirectory: true)
        ]

        for pDir in programFilesDirs where fm.fileExists(atPath: pDir.path) {
            guard let appFolders = try? fm.contentsOfDirectory(at: pDir, includingPropertiesForKeys: nil) else { continue }
            for appFolder in appFolders {
                let folderName = appFolder.lastPathComponent.lowercased()
                if folderName.contains("windows") || folderName.contains("common") || folderName.contains("internet") {
                    continue
                }

                // Look for root launcher or executable in this folder
                if let folderItems = try? fm.contentsOfDirectory(at: appFolder, includingPropertiesForKeys: nil) {
                    for item in folderItems where item.pathExtension.lowercased() == "exe" {
                        let exeName = item.deletingPathExtension().lastPathComponent
                        if isBlacklisted(exeName) { continue }

                        let path = item.path
                        let cleanName = appFolder.lastPathComponent
                        if !seenExecutables.contains(path) && !seenNames.contains(exeName.lowercased()) {
                            seenExecutables.insert(path)
                            seenNames.insert(exeName.lowercased())

                            let icon = findIcon(for: exeName, executable: path, in: actualBottle)
                            let iconSys = exeName.lowercased().contains("game") || exeName.lowercased().contains("genshin") || exeName.lowercased().contains("steam") ? "gamecontroller.fill" : "app.fill"

                            results.append(WineProgramShortcut(
                                id: path,
                                name: exeName,
                                executable: path,
                                arguments: [],
                                iconSystemName: iconSys,
                                iconURL: icon,
                                isBuiltIn: false
                            ))
                        }
                    }
                }
            }
        }

        return results
    }

    /// Resolves an authentic extracted application icon from CrossOver's icon cache or local .ico/.png.
    private static func findIcon(for name: String, executable: String, in bottleURL: URL) -> URL? {
        let fm = FileManager.default
        let windataIcons = bottleURL.appendingPathComponent("windata/cxmenu/icons/hicolor", isDirectory: true)
        let resolutions = ["256x256", "128x128", "96x96", "64x64", "48x48", "32x32"]

        let lowName = name.lowercased()
        let lowExe = URL(fileURLWithPath: executable).deletingPathExtension().lastPathComponent.lowercased()

        // 1. Check windata extracted icons created by CrossOver
        for res in resolutions {
            let appsDir = windataIcons.appendingPathComponent("\(res)/apps", isDirectory: true)
            if fm.fileExists(atPath: appsDir.path),
               let files = try? fm.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension.lowercased() == "png" {
                    let fLow = file.lastPathComponent.lowercased()
                    if (lowName.contains("genshin") || lowExe.contains("genshin")) && (fLow.contains("hk4e") || fLow.contains("gameicon")) {
                        return file
                    }
                    if (lowName.contains("hoyoplay") || lowExe.contains("launcher")) && fLow.contains("launcher") {
                        return file
                    }
                    if fLow.contains(lowExe) || fLow.contains(lowName) {
                        return file
                    }
                }
            }
        }

        // 2. Check executable directory for .ico or .png
        let exeDir = URL(fileURLWithPath: executable).deletingLastPathComponent()
        let icoSearchDirs = [
            exeDir,
            exeDir.appendingPathComponent("ico"),
            exeDir.deletingLastPathComponent().appendingPathComponent("ico")
        ]
        for sDir in icoSearchDirs where fm.fileExists(atPath: sDir.path) {
            if let files = try? fm.contentsOfDirectory(at: sDir, includingPropertiesForKeys: nil) {
                for file in files {
                    let ext = file.pathExtension.lowercased()
                    if ext == "ico" || ext == "png" {
                        let fLow = file.lastPathComponent.lowercased()
                        if (lowName.contains("genshin") && fLow.contains("hk4e")) ||
                           (lowName.contains("hoyoplay") && fLow.contains("launcher")) ||
                           fLow.contains(lowExe) {
                            return file
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Extracts Windows executable target from a .lnk binary payload.
    private static func extractTargetFromLnk(at url: URL, driveC: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let str = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8) else {
            return nil
        }
        let pattern = try? NSRegularExpression(pattern: "[A-Za-z]:\\\\[^\0\r\n\t<>\"]+?\\.exe", options: .caseInsensitive)
        let range = NSRange(str.startIndex..<str.endIndex, in: str)
        if let match = pattern?.firstMatch(in: str, options: [], range: range),
           let matchRange = Range(match.range, in: str) {
            let winPath = String(str[matchRange])
            let relative = winPath.dropFirst(2)
                .replacingOccurrences(of: "\\", with: "/")
            let candidate = driveC.appendingPathComponent(String(relative)).standardized
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
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

// MARK: - Native Mac App Publishing (.app in ~/Applications & ~/Desktop)

/// Generates and installs native macOS .app launcher bundles for bottle applications into
/// ~/Applications (for Launchpad, Spotlight, and Finder integration) and ~/Desktop.
public enum MacportAppPublisher: Sendable {

    public enum Destination: Sendable {
        case applications
        case desktop
        case custom(URL)

        public var directoryURL: URL {
            switch self {
            case .applications:
                let homeApps = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true)
                let macportApps = homeApps.appendingPathComponent("Macport", isDirectory: true)
                return macportApps
            case .desktop:
                return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
            case .custom(let url):
                return url
            }
        }

        public var displayName: String {
            switch self {
            case .applications: return "Applications"
            case .desktop: return "Desktop"
            case .custom(let url): return url.lastPathComponent
            }
        }
    }

    /// Exports a native macOS `.app` bundle.
    @discardableResult
    public static func exportLauncherApp(
        bottleId: UUID,
        bottleName: String,
        appName: String,
        executable: String,
        iconURL: URL? = nil,
        to destination: Destination = .applications
    ) throws -> URL {
        let fm = FileManager.default
        let destDir = destination.directoryURL
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let safeName = appName.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let appBundleURL = destDir.appendingPathComponent("\(safeName).app", isDirectory: true)

        if fm.fileExists(atPath: appBundleURL.path) {
            try? fm.removeItem(at: appBundleURL)
        }

        let contentsURL = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macosURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

        try fm.createDirectory(at: macosURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        // 1. Info.plist
        let alphanumericId = safeName.filter { $0.isLetter || $0.isNumber }
        let bundleID = "com.dakshraman.macport.launcher.\(bottleId.uuidString.lowercased()).\(alphanumericId.isEmpty ? "app" : alphanumericId)"
        let plistDict: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "launch",
            "CFBundleIconFile": "AppIcon",
            "CFBundleIdentifier": bundleID,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": safeName,
            "CFBundleDisplayName": safeName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
            "MacportBottleID": bottleId.uuidString,
            "MacportBottleName": bottleName,
            "MacportExecutable": executable
        ]

        let plistData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        // 2. PkgInfo
        try "APPL????".write(to: contentsURL.appendingPathComponent("PkgInfo"), atomically: true, encoding: .ascii)

        // 3. MacOS/launch executable script
        let encodedExec = executable.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? executable
        let script = """
        #!/bin/bash
        # Macport Launcher for \(safeName) in bottle \(bottleName)
        open "macport://launch?bottle=\(bottleId.uuidString)&exec=\(encodedExec)" 2>/dev/null || open -b com.dakshraman.macport "macport://launch?bottle=\(bottleId.uuidString)&exec=\(encodedExec)"
        """
        let launchURL = macosURL.appendingPathComponent("launch")
        try script.write(to: launchURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchURL.path)

        // 4. Resources/AppIcon.icns
        let targetIcon = resourcesURL.appendingPathComponent("AppIcon.icns")
        if let icon = iconURL, fm.fileExists(atPath: icon.path) {
            if icon.pathExtension.lowercased() == "icns" {
                try? fm.copyItem(at: icon, to: targetIcon)
            } else if icon.pathExtension.lowercased() == "png" {
                convertPNGToICNS(source: icon, destination: targetIcon)
            }
        }
        if !fm.fileExists(atPath: targetIcon.path) {
            copyDefaultMacportIcon(to: targetIcon)
        }

        // 5. Register with macOS LaunchServices
        registerWithLaunchServices(at: appBundleURL)

        return appBundleURL
    }

    private static func copyDefaultMacportIcon(to target: URL) {
        let fm = FileManager.default
        if let defaultICNS = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           fm.fileExists(atPath: defaultICNS.path) {
            try? fm.copyItem(at: defaultICNS, to: target)
        } else {
            let candidates = [
                URL(fileURLWithPath: "/Applications/Macport.app/Contents/Resources/AppIcon.icns"),
                Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns")
            ]
            for cand in candidates where fm.fileExists(atPath: cand.path) {
                try? fm.copyItem(at: cand, to: target)
                return
            }
        }
    }

    private static func convertPNGToICNS(source: URL, destination: URL) {
        let fm = FileManager.default
        let tempIconset = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
        try? fm.createDirectory(at: tempIconset, withIntermediateDirectories: true)
        let s512 = tempIconset.appendingPathComponent("icon_512x512.png")
        let s1024 = tempIconset.appendingPathComponent("icon_512x512@2x.png")
        try? fm.copyItem(at: source, to: s512)
        try? fm.copyItem(at: source, to: s1024)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        proc.arguments = ["-c", "icns", tempIconset.path, "-o", destination.path]
        try? proc.run()
        proc.waitUntilExit()
        try? fm.removeItem(at: tempIconset)
    }

    private static func registerWithLaunchServices(at url: URL) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
        if FileManager.default.fileExists(atPath: lsregister) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: lsregister)
            proc.arguments = ["-f", url.path]
            try? proc.run()
            proc.waitUntilExit()
        }
    }
}

