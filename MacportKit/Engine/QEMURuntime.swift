import Foundation

/// Locates the QEMU runtime Macport runs guests with — and installs one when the
/// Mac does not have it.
///
/// Macport owns this dependency rather than asking the user to drive a package
/// manager. Resolution order is deliberate, and it runs from most self-contained to
/// least:
///
/// 1. An explicit override, for development and for pointing at a custom build.
/// 2. The **app bundle's own runtime** — the shipping location. QEMU travels with
///    Macport, so a machine needs nothing installed for Windows guests to work.
/// 3. Macport's vendored runtime in Application Support, which is where an
///    install lands when there is no bundle to write into (the CLI, for instance).
/// 4. A package manager's QEMU, and finally anything on `PATH` — development
///    fallbacks, never the shipping path.
///
/// The ordering matters because it decides what a VM actually runs on. Nothing the
/// user later does to a global toolchain can silently change which hypervisor their
/// machines start under.
public enum QEMURuntime {

    // MARK: - Identity

    /// Only the host architecture is supported, because `hvf` accelerates a guest
    /// by running it on the real CPU — it cannot translate a foreign instruction
    /// set. A cross-architecture guest needs TCG emulation, which is a different
    /// decision with a very different performance profile.
    nonisolated public static var systemBinaryName: String {
        #if arch(arm64)
        return "qemu-system-aarch64"
        #else
        return "qemu-system-x86_64"
        #endif
    }

    /// UEFI firmware file name for the host architecture.
    nonisolated static var codeFirmwareNames: [String] {
        #if arch(arm64)
        return ["edk2-aarch64-code.fd"]
        #else
        return ["edk2-x86_64-code.fd"]
        #endif
    }

    /// The *variable store* template. On arm64 QEMU ships this under the `arm`
    /// name even though the code firmware is `aarch64`, which is an easy trap.
    nonisolated static var varsFirmwareNames: [String] {
        #if arch(arm64)
        return ["edk2-arm-vars.fd", "edk2-aarch64-vars.fd"]
        #else
        return ["edk2-x86_64-vars.fd"]
        #endif
    }

    // MARK: - Locations

    /// Where Macport keeps a runtime it owns.
    nonisolated public static var managedDirectory: URL {
        VMStore.defaultRoot
            .deletingLastPathComponent()
            .appendingPathComponent("Runtime", isDirectory: true)
    }

    /// The vendored runtime directory inside Macport's support directory.
    nonisolated public static var managedRuntimeDirectory: URL {
        managedDirectory.appendingPathComponent("QEMU", isDirectory: true)
    }

    /// Where a bundled runtime lives — whether or not one is there yet.
    ///
    /// Distinct from `bundledRuntimeDirectory`, which only reports an existing one.
    /// This is the destination an install writes to when the runtime is meant to
    /// travel with Macport rather than sit in Application Support.
    nonisolated public static var bundleRuntimeDestination: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Runtime/QEMU", isDirectory: true)
    }

    /// The runtime shipped inside the running app bundle, if this Mac is running a
    /// bundled build rather than the CLI.
    ///
    /// `Bundle.main` is correct here even though this code lives in MacportKit:
    /// MacportKit is a static framework, so the main bundle is whichever executable
    /// linked it — the app, or the CLI.
    nonisolated public static var bundledRuntimeDirectory: URL? {
        bundleRuntimeDestination.flatMap(runtimeDirectoryIfPresent(at:))
    }

    private nonisolated static func runtimeDirectoryIfPresent(at url: URL) -> URL? {
        let binary = url.appendingPathComponent("bin").appendingPathComponent(systemBinaryName)
        return FileManager.default.isExecutableFile(atPath: binary.path) ? url : nil
    }

    /// A resolved QEMU installation. Everything the engine needs to launch is
    /// captured here so the engine never re-derives paths at run time.
    public struct Tool: Sendable, Equatable {
        public var systemBinary: URL
        public var imageBinary: URL?
        /// Directory holding the UEFI firmware images.
        public var firmwareDirectory: URL?
        /// Where this QEMU came from, for the UI and for logs. Knowing whether a
        /// machine runs on Macport's own runtime or on a package manager's install
        /// is the first question worth answering when something misbehaves.
        public var origin: String

        /// Is this runtime one Macport manages, rather than one it found?
        public var isManagedByMacport: Bool {
            origin == Origin.bundled.rawValue || origin == Origin.vendored.rawValue
        }
    }

    /// Named origins, so display strings and comparisons cannot drift apart.
    public enum Origin: String, Sendable {
        case bundled = "Bundled with Macport"
        case vendored = "Macport runtime"
        case override = "MACPORT_QEMU_DIR"
        case packageManager = "Homebrew"
        case path = "PATH"
    }

    // MARK: - Resolution

    /// Find a usable QEMU, preferring Macport's own runtime.
    nonisolated public static func locate() -> Tool? { locate(excluding: nil) }

    /// Find a usable QEMU.
    ///
    /// - Parameter excluded: A runtime root to skip. Re-vendoring needs this: the
    ///   destination is cleared before copying, so sourcing from a runtime that lives
    ///   at the destination would delete the source from under its own copy.
    nonisolated private static func locate(excluding excluded: URL?) -> Tool? {
        func isExcluded(_ directory: URL) -> Bool {
            guard let excluded else { return false }
            return directory.standardizedFileURL == excluded.standardizedFileURL
        }

        // 1. Explicit override, for development and for a custom build.
        if let override = ProcessInfo.processInfo.environment["MACPORT_QEMU_DIR"] {
            let root = URL(fileURLWithPath: override)
            // Accept either the runtime root or its bin directory; guessing wrong
            // should not be the difference between working and not.
            for candidate in [root.appendingPathComponent("bin"), root] {
                if let tool = tool(in: candidate, origin: Origin.override.rawValue) {
                    return tool
                }
            }
        }

        // 2. The runtime shipped inside the app bundle. This is the shipping path.
        if let bundled = bundledRuntimeDirectory, !isExcluded(bundled),
           let tool = tool(in: bundled.appendingPathComponent("bin"), origin: Origin.bundled.rawValue) {
            return tool
        }

        // 3. Macport's vendored runtime in Application Support.
        if !isExcluded(managedRuntimeDirectory),
           let tool = tool(
               in: managedRuntimeDirectory.appendingPathComponent("bin"),
               origin: Origin.vendored.rawValue
           ) {
            return tool
        }

        // 4. A package manager's install, on either prefix.
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let bin = URL(fileURLWithPath: prefix).appendingPathComponent("bin")
            if let tool = tool(in: bin, origin: Origin.packageManager.rawValue) { return tool }
        }

        // 5. Anything on PATH.
        if let found = which(systemBinaryName) {
            let bin = URL(fileURLWithPath: found).deletingLastPathComponent()
            if let tool = tool(in: bin, origin: Origin.path.rawValue) { return tool }
        }

        return nil
    }

    /// Is a runtime present? Cheap enough for a view to ask on every render.
    nonisolated public static var isInstalled: Bool { locate() != nil }

    private nonisolated static func tool(in binDirectory: URL, origin: String) -> Tool? {
        let fileManager = FileManager.default
        let system = binDirectory.appendingPathComponent(systemBinaryName)
        guard fileManager.isExecutableFile(atPath: system.path) else { return nil }

        let image = binDirectory.appendingPathComponent("qemu-img")

        return Tool(
            systemBinary: system,
            imageBinary: fileManager.isExecutableFile(atPath: image.path) ? image : nil,
            firmwareDirectory: firmwareDirectory(near: binDirectory),
            origin: origin
        )
    }

    /// Firmware does not sit beside the binary in any layout QEMU ships; it sits in
    /// a sibling `share/qemu`. Check the plausible shapes rather than assume one.
    ///
    /// The result is canonicalized. A package manager's `share/qemu` is normally a
    /// symlink into its versioned directory, and enumerating a symlinked directory
    /// fails in Foundation — so resolving once here means the engine and the
    /// vendoring pass both get a real path instead of each discovering it.
    private nonisolated static func firmwareDirectory(near binDirectory: URL) -> URL? {
        let fileManager = FileManager.default
        let parent = binDirectory.deletingLastPathComponent()
        let candidates = [
            parent.appendingPathComponent("share/qemu"),
            parent.appendingPathComponent("firmware"),
            binDirectory.appendingPathComponent("firmware"),
        ]
        let match = candidates.first { directory in
            codeFirmwareNames.contains { name in
                fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
            }
        }
        return match?.resolvingSymlinksInPath()
    }

    /// Resolve the UEFI code and variable-store images for this installation.
    ///
    /// Both matter: without a writable variable store the firmware cannot remember
    /// a boot order, so a guest would fall back to the installer on every boot and
    /// the installed system would never start.
    nonisolated public static func firmware(for tool: Tool) -> (code: URL, varsTemplate: URL?)? {
        guard let directory = tool.firmwareDirectory else { return nil }
        let fileManager = FileManager.default

        guard let codeName = codeFirmwareNames.first(where: {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) else { return nil }

        let varsTemplate = varsFirmwareNames
            .map { directory.appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: $0.path) }

        return (directory.appendingPathComponent(codeName), varsTemplate)
    }

    private nonisolated static func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for component in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component))
                .appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    // MARK: - Installation

    public enum InstallError: Error, LocalizedError, Sendable {
        case noInstaller(String)
        case installerFailed(String)
        case verifiedButMissing(String)

        public var errorDescription: String? {
            switch self {
            case .noInstaller(let detail):
                return detail
            case .installerFailed(let detail):
                return "Macport could not install the QEMU runtime: \(detail)"
            case .verifiedButMissing(let detail):
                return "QEMU was installed but Macport cannot find it: \(detail)"
            }
        }
    }

    /// Install a self-contained QEMU runtime, reporting progress as it goes.
    ///
    /// Two stages, and the second is the one that matters. Macport first obtains a
    /// source QEMU — from a package manager, or an existing installation — and then
    /// **vendors** it: copies the dependency closure into Macport's own directory
    /// and rewrites the linking so nothing points back at the source. The result is
    /// a runtime Macport owns, not a package it borrows.
    ///
    /// - Parameters:
    ///   - destination: Where to put the runtime. `nil` means Macport's own directory
    ///     in Application Support; pass `bundleRuntimeDestination` to make the
    ///     runtime travel inside the app instead, which is how a shipped build
    ///     works — no package manager and no prior install needed on the target Mac.
    ///   - force: Re-vendor even when a runtime already exists at that destination.
    ///     This is how a runtime is repaired or refreshed, and the only way to get a
    ///     clean copy after the existing one has been altered.
    @discardableResult
    nonisolated public static func install(
        into destination: URL? = nil,
        force: Bool = false,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> Tool {
        let target = destination ?? managedRuntimeDirectory

        // Already satisfied? Only if the destination being filled already holds a
        // runtime. Asking `locate()` instead would let a bundled runtime satisfy a
        // request to fill the Application Support copy, and silently do nothing.
        if !force, let existing = tool(
            in: target.appendingPathComponent("bin"),
            origin: Origin.vendored.rawValue
        ) {
            progress("A runtime is already installed at \(existing.systemBinary.path).")
            return existing
        }

        let source = try await sourceTool(progress: progress, excluding: target)

        progress("Vendoring QEMU into \(target.path).")
        let report = try await vendoringOffMainThread(
            source: source,
            destination: target,
            progress: progress
        )
        progress(
            "Vendored \(report.executables) executables, "
                + "\(report.libraries) libraries and \(report.dataFiles) data files."
        )

        // Verify at the destination rather than through `locate()`. A runtime in the
        // bundle outranks one in Application Support, so `locate()` would happily
        // return a different runtime than the one just written and report success for
        // an install that did not work.
        let inBundle = Bundle.main.resourceURL
            .map { target.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path) } ?? false
        guard let installed = tool(
            in: target.appendingPathComponent("bin"),
            origin: inBundle ? Origin.bundled.rawValue : Origin.vendored.rawValue
        ) else {
            throw InstallError.verifiedButMissing(
                "the runtime was copied to \(target.path) but Macport cannot load "
                    + "\(systemBinaryName) from it."
            )
        }
        progress("QEMU runtime ready at \(installed.systemBinary.path).")
        return installed
    }

    /// Find a QEMU to vendor from, installing one if the Mac has none.
    nonisolated private static func sourceTool(
        progress: @escaping @Sendable (String) -> Void,
        excluding destination: URL
    ) async throws -> Tool {
        // Anything already on this Mac will do — including a runtime Macport manages,
        // which is how an install upgrades its own runtime in place. Not, however, the
        // runtime sitting at the destination, since vendoring clears it first.
        if let existing = locate(excluding: destination) {
            return existing
        }

        guard let brew = which("brew") else {
            throw InstallError.noInstaller(
                """
                Macport needs a QEMU runtime for Windows and other guests, and could \
                not find one to vendor or a way to obtain one.

                Either install Homebrew from https://brew.sh and let Macport manage \
                QEMU for you, or place a runtime at:
                  \(managedRuntimeDirectory.path)
                """
            )
        }

        progress("Downloading QEMU with Homebrew. This happens once.")
        let status = await withCheckedContinuation { continuation -> Void in
            // A dedicated thread: `waitUntilExit` blocks, and there is nothing
            // useful for the cooperative pool to do while it waits.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(brew, ["install", "qemu"], onLine: progress))
            }
        }

        guard status == 0 else {
            throw InstallError.installerFailed("Homebrew exited with status \(status).")
        }
        guard let installed = locate() else {
            throw InstallError.verifiedButMissing(
                "Homebrew reported success but no \(systemBinaryName) is on this Mac."
            )
        }
        return installed
    }

    /// Run the vendoring pass off the main actor.
    ///
    /// It shells out to `otool`, `install_name_tool` and `codesign` hundreds of
    /// times and takes tens of seconds; blocking a main actor for that is not
    /// acceptable, and the work is purely synchronous.
    nonisolated private static func vendoringOffMainThread(
        source: Tool,
        destination: URL,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> QEMURuntimeBundler.Report {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let report = try QEMURuntimeBundler.vendor(
                        from: source,
                        into: destination,
                        progress: progress
                    )
                    continuation.resume(returning: report)
                } catch {
                    // Propagate rather than swallow. A vendoring failure that
                    // reports success leaves the user with a runtime Macport
                    // cannot load and no idea why.
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run a child process to completion, forwarding its output line by line.
    ///
    /// Returns the exit status rather than throwing, so the caller decides whether a
    /// non-zero exit is fatal — for an installer it always is, but the reason should
    /// come from the output, not from a generic error.
    nonisolated private static func runBlocking(
        _ executable: String,
        _ arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // A chatty installer fills a pipe buffer and blocks forever if nobody
        // drains it, so read on the handler rather than after exit.
        let accumulator = LineAccumulator()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in accumulator.append(chunk) where !line.isEmpty {
                onLine(line)
            }
        }

        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            onLine("Could not run \(executable): \(error.localizedDescription)")
            return -1
        }

        process.waitUntilExit()
        handle.readabilityHandler = nil
        return process.terminationStatus
    }
}

/// Accumulates raw bytes into whole lines.
///
/// `@unchecked Sendable` because the lock is what makes it safe, not the type
/// system — the readability handler runs on a queue Foundation owns.
private final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(chunk)
        var lines: [String] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            lines.append(String(decoding: line, as: UTF8.self))
        }
        return lines
    }
}
