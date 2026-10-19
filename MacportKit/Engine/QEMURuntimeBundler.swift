import Foundation

/// Vendors a QEMU installation into a directory Macport owns.
///
/// This is what makes Macport self-contained, and it is the piece UTM solves by
/// building QEMU themselves. A package manager's QEMU is not a portable artifact:
/// its binaries are linked against absolute paths under the install prefix, so
/// copying the executable alone yields something that cannot start. Vendoring
/// means copying the whole dependency closure, rewriting every install name to
/// point inside the copy, and re-signing — because rewriting an install name
/// invalidates a code signature, and Apple silicon refuses to load an unsigned
/// Mach-O at all.
///
/// The result is a directory that runs with nothing outside it:
///
/// ```
/// Runtime/QEMU/
///   bin/qemu-system-aarch64   rewritten to @loader_path/../lib/
///   lib/libglib-2.0.0.dylib   dependencies rewritten to @loader_path/
///   share/qemu/               firmware, keymaps and the rest of QEMU's data
/// ```
public enum QEMURuntimeBundler {

    public struct Report: Sendable {
        public var destination: URL
        public var executables: Int
        public var libraries: Int
        public var dataFiles: Int
    }

    public enum BundleError: Error, LocalizedError, Sendable {
        case toolFailed(String, Int32, String)
        case missingDependency(String)
        case noExecutables(String)
        case noFirmware(String)

        public var errorDescription: String? {
            switch self {
            case .toolFailed(let tool, let status, let detail):
                return "\(tool) exited with status \(status): \(detail)"
            case .missingDependency(let path):
                return "QEMU depends on \(path), which could not be found."
            case .noExecutables(let directory):
                return "No QEMU executables were found in \(directory)."
            case .noFirmware(let detail):
                return "Could not bundle the QEMU firmware: \(detail)"
            }
        }
    }

    /// The executables Macport actually launches.
    ///
    /// Deliberately not "every `qemu-*` binary": the full set runs to hundreds of
    /// megabytes and Macport uses two of them.
    private static let requiredExecutables = [
        QEMURuntime.systemBinaryName,
        "qemu-img",
    ]

    /// Copy a QEMU installation into `destination` as a self-contained runtime.
    public static func vendor(
        from tool: QEMURuntime.Tool,
        into destination: URL,
        progress: @Sendable (String) -> Void
    ) throws -> Report {
        let fileManager = FileManager.default
        let sourceBin = tool.systemBinary.deletingLastPathComponent()
        let sourcePrefix = sourceBin.deletingLastPathComponent()

        let binDirectory = destination.appendingPathComponent("bin", isDirectory: true)
        let libDirectory = destination.appendingPathComponent("lib", isDirectory: true)
        let shareDirectory = destination.appendingPathComponent("share/qemu", isDirectory: true)

        try? fileManager.removeItem(at: destination)
        for directory in [binDirectory, libDirectory, shareDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // 1. Copy the executables, then walk their dependencies breadth-first.
        //
        // A flat list is not enough: every library pulled in may itself depend on
        // others, and a missed one is a runtime failure rather than a build error.
        // Keyed by file name, not by source path. A package manager exposes the
        // same library through both its versioned directory and a stable `opt`
        // symlink, so one file arrives twice under two paths — and copying it twice
        // fails. The name is what the copy is addressed by, so it is what to key on.
        var vendoredLibraries: [String: URL] = [:]
        var queue: [URL] = []
        var executableCount = 0

        for name in requiredExecutables {
            // Resolve before copying. A package manager's `bin` entry is itself a
            // symlink into its versioned directory, so copying the link produces a
            // dangling binary — present, executable-flagged and impossible to run.
            let source = sourceBin.appendingPathComponent(name).resolvingSymlinksInPath()
            guard fileManager.isExecutableFile(atPath: source.path) else { continue }
            try fileManager.copyItem(at: source, to: binDirectory.appendingPathComponent(name))
            executableCount += 1
            queue.append(source)
        }
        guard executableCount > 0 else {
            throw BundleError.noExecutables(sourceBin.path)
        }

        while let current = queue.popLast() {
            for dependency in try dependencies(of: current) {
                guard !isSystemLibrary(dependency) else { continue }
                let resolved = try resolve(dependency, near: current, prefix: sourcePrefix)
                let name = resolved.lastPathComponent
                guard vendoredLibraries[name] == nil else { continue }

                let target = libDirectory.appendingPathComponent(name)
                if !fileManager.fileExists(atPath: target.path) {
                    // Copy the file's *contents* under the name its dependents
                    // reference. A package manager's `opt` libraries are relative
                    // symlinks into a versioned directory, so copying the link
                    // itself would leave it pointing at a path that does not exist
                    // here — and the runtime would fail to load with a bare "no
                    // such file" that says nothing about the real cause.
                    try fileManager.copyItem(at: resolved.resolvingSymlinksInPath(), to: target)
                }
                vendoredLibraries[name] = resolved
                queue.append(resolved)
            }
        }

        progress("Copied \(executableCount) executables and \(vendoredLibraries.count) libraries.")

        // 2. Rewrite install names to point inside the copy.
        //
        // The relative prefix differs by location — a binary reaches its libraries
        // through `../lib`, a library reaches its siblings through the same
        // directory — which is why this is per-file rather than one pass.
        let libraryNames = Set(vendoredLibraries.keys)

        for name in vendoredLibraries.keys {
            let target = libDirectory.appendingPathComponent(name)
            try rewrite(target, relativePrefix: "@loader_path/", libraryNames: libraryNames)
            // Give the library its own portable identity too.
            try run("/usr/bin/install_name_tool", ["-id", "@rpath/" + name, target.path])
        }
        for name in requiredExecutables {
            let target = binDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: target.path) else { continue }
            try rewrite(target, relativePrefix: "@loader_path/../lib/", libraryNames: libraryNames)
        }

        // 3. Re-sign. `install_name_tool` invalidates the signature, and an
        //    unsigned image will not load on Apple silicon — the failure would
        //    appear much later as an unexplained "cannot be opened".
        //
        //    The executables need more than a signature: they need the hypervisor
        //    entitlement. See `entitlementsXML`.
        for name in vendoredLibraries.keys {
            try sign(libDirectory.appendingPathComponent(name), entitlements: nil)
        }
        let entitlements = try writeEntitlements()
        for name in requiredExecutables {
            let target = binDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) {
                try sign(target, entitlements: entitlements)
            }
        }

        // 4. Firmware and data files.
        let dataFiles = try copyRuntimeData(from: tool, into: shareDirectory, progress: progress)

        return Report(
            destination: destination,
            executables: executableCount,
            libraries: vendoredLibraries.count,
            dataFiles: dataFiles
        )
    }

    // MARK: - Mach-O inspection

    /// Direct dependencies of a Mach-O image, via `otool -L`.
    private static func dependencies(of file: URL) throws -> [String] {
        let output = try run("/usr/bin/otool", ["-L", file.path])
        return output
            .split(separator: "\n")
            .dropFirst()  // the first line names the file itself
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                // "<path> (compatibility version ...)"
                return trimmed.split(separator: " ").first.map(String.init)
            }
    }

    private static func isSystemLibrary(_ path: String) -> Bool {
        path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/")
    }

    /// Resolve a dependency path to a real file.
    ///
    /// Absolute paths are the common case for a package manager's build. The
    /// `@rpath` form is also possible, so the search falls back to the prefix's
    /// library directories and then to the whole prefix by basename, which is what
    /// keeps this working across layouts rather than assuming one.
    private static func resolve(_ dependency: String, near current: URL, prefix: URL) throws -> URL {
        let fileManager = FileManager.default

        if dependency.hasPrefix("/"), fileManager.fileExists(atPath: dependency) {
            return URL(fileURLWithPath: dependency)
        }

        let name = (dependency as NSString).lastPathComponent
        var candidates: [URL] = [
            current.deletingLastPathComponent().appendingPathComponent(name),
            prefix.appendingPathComponent("lib").appendingPathComponent(name),
            prefix.appendingPathComponent("libexec").appendingPathComponent(name),
        ]

        let optDirectory = prefix.appendingPathComponent("opt")
        if let entries = try? fileManager.contentsOfDirectory(
            at: optDirectory,
            includingPropertiesForKeys: nil
        ) {
            candidates.append(contentsOf: entries.map {
                $0.appendingPathComponent("lib").appendingPathComponent(name)
            })
        }

        if let match = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return match
        }
        throw BundleError.missingDependency(dependency)
    }

    /// Point every vendored dependency of `file` at the copy next to it.
    private static func rewrite(
        _ file: URL,
        relativePrefix: String,
        libraryNames: Set<String>
    ) throws {
        for dependency in try dependencies(of: file) {
            guard !isSystemLibrary(dependency) else { continue }
            let name = (dependency as NSString).lastPathComponent
            guard libraryNames.contains(name) else { continue }
            try run(
                "/usr/bin/install_name_tool",
                ["-change", dependency, relativePrefix + name, file.path]
            )
        }
    }

    /// Sign a Mach-O image ad-hoc, optionally with entitlements.
    ///
    /// The hardened runtime is deliberately *not* enabled. It turns on library
    /// validation, which refuses to load the runtime's own `@loader_path` libraries
    /// because an ad-hoc signature carries no team identifier to match them
    /// against — the runtime then fails with "Library not loaded" before `main`.
    private static func sign(_ file: URL, entitlements: URL?) throws {
        var arguments = ["--force", "--sign", "-"]
        if let entitlements {
            arguments += ["--entitlements", entitlements.path]
        }
        arguments.append(file.path)
        try run("/usr/bin/codesign", arguments)
    }

    /// The entitlements the QEMU executables are signed with.
    ///
    /// This is not decoration. `Hypervisor.framework` gates `hv_gic_create` on the
    /// hypervisor entitlement, and QEMU's `hvf` accelerator calls it to build the
    /// guest's interrupt controller. Signed ad-hoc *without* it, the runtime starts
    /// and then dies with `error creating platform VGIC` / `HV_NO_DEVICE` — an error
    /// that names neither the signature nor the entitlement. With it, hardware
    /// acceleration works. Measured on this host by signing and stripping it again.
    ///
    /// Kept as a literal rather than a bundled resource because this is its only
    /// consumer, and a file that must stay in step with a constant is a drift
    /// waiting to happen.
    private static let entitlementsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>com.apple.security.hypervisor</key>
    \t<true/>
    \t<key>com.apple.security.network.client</key>
    \t<true/>
    </dict>
    </plist>
    """

    private static func writeEntitlements() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macport-qemu-entitlements.plist")
        try entitlementsXML.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Runtime data

    /// Copy the firmware images and data files QEMU reads at run time.
    ///
    /// Deliberately selective. A package manager ships firmware for every
    /// architecture it supports, and copying all of it adds half a gigabyte of
    /// images for instruction sets this Mac cannot execute.
    private static func copyRuntimeData(
        from tool: QEMURuntime.Tool,
        into shareDirectory: URL,
        progress: @Sendable (String) -> Void
    ) throws -> Int {
        guard let firmware = QEMURuntime.firmware(for: tool),
              let source = tool.firmwareDirectory else {
            throw BundleError.noFirmware("this QEMU installation has no firmware directory")
        }

        let fileManager = FileManager.default
        let needed: Set<String> = [
            firmware.code.lastPathComponent,
            firmware.varsTemplate?.lastPathComponent,
        ].compactMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }

        var copied = 0
        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        for entry in entries {
            let name = entry.lastPathComponent

            // Keep this architecture's firmware; skip every other architecture's.
            let isFirmwareImage = name.hasPrefix("edk2-") && name.hasSuffix(".fd")
            if isFirmwareImage && !needed.contains(name) { continue }

            // Skip large non-firmware payloads we do not use.
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if !isFirmwareImage && size > 16 * 1024 * 1024 { continue }

            let target = shareDirectory.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            if (try? fileManager.copyItem(at: entry, to: target)) != nil {
                copied += 1
            }
        }

        progress("Bundled \(copied) firmware and data files.")
        return copied
    }

    // MARK: - Process helper

    /// Run a tool to completion and return its standard output.
    ///
    /// Returns on success only; a non-zero status becomes an error carrying the
    /// tool's own diagnostics, because "codesign failed" without its message is
    /// useless.
    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = output
        process.standardError = errorPipe

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BundleError.toolFailed(
                (executable as NSString).lastPathComponent,
                process.terminationStatus,
                String(decoding: errorData.prefix(400), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: data, as: UTF8.self)
    }
}
