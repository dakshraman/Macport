import Foundation

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
