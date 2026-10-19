import Foundation
import MacportKit

/// Command-line counterpart to the app.
///
/// It links `MacportKit` — the same model, registry and engines the UI uses —
/// rather than reimplementing them. That is the point of the framework split: a VM
/// created from the terminal is byte-for-byte the same machine the app lists, and
/// the engine it runs on is chosen by the same rules.
///
/// Deliberately a `tool` with hand-rolled flag parsing: a handful of options do not
/// justify a dependency.
@main
struct MacportCtl {
    static func main() async {
        // Unbuffered stdout. This tool reports progress across a VM boot that can
        // run for minutes, and block-buffered output would hide it until exit —
        // which is exactly how a successful boot once looked like silence.
        setvbuf(stdout, nil, _IONBF, 0)

        var args = Array(CommandLine.arguments.dropFirst())
        guard let verb = args.first else {
            printUsage()
            exit(0)
        }
        args.removeFirst()

        switch verb {
        case "list", "ls":
            await list()
        case "capabilities", "caps":
            capabilities(guest: args.first)
        case "runtime":
            await runtime(args)
        case "create":
            await create(args)
        case "start", "boot":
            await start(args)
        case "stop":
            await stop(args)
        case "path":
            print(VMStore.defaultRoot.path)
        case "help", "--help", "-h":
            printUsage()
        default:
            fail("Unknown command: \(verb)\n\n")
        }
    }

    // MARK: - Commands

    static func list() async {
        let store = await VMStore()
        await store.load()
        let items = await store.machines

        if items.isEmpty {
            print("No virtual machines.")
            print("VM directory: \(VMStore.defaultRoot.path)")
            return
        }

        let nameWidth = max(4, items.map(\.name.count).max() ?? 4)
        let engineWidth = max(
            6,
            items.map { EngineRegistry.engineType(for: $0).displayName.count }.max() ?? 6
        )
        print(
            pad("NAME", nameWidth) + "  "
                + pad("GUEST", 16) + "  "
                + pad("ENGINE", engineWidth) + "  "
                + "CPU  MEMORY    DISK"
        )
        for item in items {
            print(
                pad(item.name, nameWidth) + "  "
                    + pad(item.guest.displayName, 16) + "  "
                    + pad(EngineRegistry.engineType(for: item).displayName, engineWidth) + "  "
                    + pad("\(item.cpuCount)", 3) + "  "
                    + pad(item.memoryBytes.gbString, 8) + "  "
                    + item.diskBytes.gbString
            )
        }
    }

    /// Print what each engine can actually do, and which one a guest will get.
    ///
    /// Exists so capability limits can be checked in a script or a release
    /// checklist rather than only by clicking through the app — and so the routing
    /// decision is inspectable without reading the source.
    static func capabilities(guest: String?) {
        let kinds: [GuestKind]
        if let guest, let kind = parseGuest(guest) {
            kinds = [kind]
        } else {
            kinds = GuestKind.allCases
        }

        for kind in kinds {
            let chosen = EngineRegistry.preferredType(for: kind)
            print("\(kind.displayName)")
            print("  selected engine : \(chosen.displayName)")

            for type in EngineRegistry.all {
                let caps = type.capabilities(for: kind)
                let marker = type.identifier == chosen.identifier ? "*" : " "
                print(
                    "  \(marker) \(pad(type.displayName, 24))"
                        + " tpm:\(yesNo(caps.tpm))"
                        + "  installer-ISO:\(yesNo(caps.opticalMedia))"
                        + "  snapshots:\(yesNo(caps.snapshots))"
                        + "  available:\(yesNo(EngineRegistry.isAvailable(type)))"
                )
            }

            if let rationale = EngineRegistry.rationale(
                for: VMConfiguration(name: "probe", guest: kind)
            ) {
                print("  why: \(rationale)")
            }
            if kind.requiresTPM {
                print("  note: Windows 11 setup will need its TPM check bypassed.")
            }
            print("")
        }
    }

    /// Manage the runtime Macport runs QEMU guests with.
    static func runtime(_ args: [String]) async {
        switch args.first ?? "status" {
        case "status":
            printRuntimeStatus()

        case "install", "reinstall":
            // `reinstall` and `--force` mean the same thing: replace the runtime
            // rather than accept an existing one. They exist because an install is
            // idempotent by default, and there is no other way to repair a runtime
            // that has been altered or partially written.
            let force = args.first == "reinstall"
                || args.contains("--force")
                || args.contains("--reinstall")
            // `--into` is how the runtime is placed inside an app bundle, so a shipped
            // Macport carries it and the target Mac needs nothing installed.
            let destination = value(of: "--into", in: args).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            do {
                let tool = try await QEMURuntime.install(into: destination, force: force) { line in
                    print(line)
                }
                print("Installed: \(tool.systemBinary.path)")
            } catch {
                fail("\(error.localizedDescription)\n")
            }

        default:
            fail("Usage: macportctl runtime [status|install [--force] [--into DIR]|reinstall]\n")
        }
    }

    /// Report where the runtime came from and whether the QEMU engine can use it.
    ///
    /// Prints the *searched* locations even when nothing is found, because the most
    /// common question is "why is Macport ignoring the QEMU I installed?" — and the
    /// answer is always which directory won.
    static func printRuntimeStatus() {
        let locations = [
            ("bundled with app", QEMURuntime.bundledRuntimeDirectory?.path
                ?? "not a bundled build"),
            ("vendored by Macport", QEMURuntime.managedRuntimeDirectory.path),
            ("MACPORT_QEMU_DIR", ProcessInfo.processInfo.environment["MACPORT_QEMU_DIR"]
                ?? "unset"),
        ]

        guard let tool = QEMURuntime.locate() else {
            print("QEMU runtime : not installed")
            print("  install it with: macportctl runtime install")
            print("")
            print("Searched, in order:")
            for (label, path) in locations {
                print("  \(pad(label, 20))  \(path)")
            }
            return
        }

        print("QEMU runtime : installed — \(tool.origin)")
        print("  managed by Macport : \(yesNo(tool.isManagedByMacport))")
        print("  binary             : \(tool.systemBinary.path)")
        print("  qemu-img           : \(tool.imageBinary?.path ?? "not found")")
        print("  firmware           : \(tool.firmwareDirectory?.path ?? "NOT FOUND")")
        if let firmware = QEMURuntime.firmware(for: tool) {
            print("  UEFI code          : \(firmware.code.lastPathComponent)")
            print(
                "  UEFI vars          : "
                    + (firmware.varsTemplate?.lastPathComponent
                        ?? "none — variable stores will be zero-filled")
            )
        }
        if case .failure(let error) = QEMUEngine.availability() {
            print("  status             : \(error.localizedDescription)")
        } else {
            print("  status             : ready")
        }
    }

    static func create(_ args: [String]) async {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("""
            Usage: macportctl create <name> [options]

              --guest <linux|windows|macos>  Guest family (default: linux)
              --iso <path>                   Install media to boot
              --cpu <n>                      Virtual processors (default: 4)
              --memory <gb>                  RAM in GB (default: 4)
              --disk <gb>                    Disk ceiling in GB (default: 64)
              --engine <vz|qemu>             Pin an engine (default: chosen by guest)
              --shared-folder <path>         Share a host directory (read-only)
              --no-network                   Leave the guest disconnected

            """)
        }

        let config = configuration(name: name, args: args)

        let store = await VMStore()
        await store.load()

        do {
            let saved = try await store.save(config)
            let bundle = await store.bundleURL(for: saved)
            let engine = EngineRegistry.engineType(for: saved)
            print("Created \(saved.name) [\(saved.guest.displayName)]")
            print("  engine     : \(engine.displayName)")
            print("  processors : \(saved.cpuCount)")
            print("  memory     : \(saved.memoryBytes.gbString)")
            print("  disk       : \(saved.diskBytes.gbString)")
            print("  boot       : \(describe(saved.boot))")
            print("  bundle     : \(bundle.path)")
        } catch {
            fail("\(error.localizedDescription)\n")
        }
    }

    static func start(_ args: [String]) async {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("Usage: macportctl start <name> [--iso <path>] [--memory <gb>] [--disk <gb>] [--engine <vz|qemu>]\n")
        }
        guard var config = await find(name) else { exit(1) }

        // `start` accepts the same flags as `create` so a VM made without an
        // installer can be given one without being rebuilt from scratch.
        config = configuration(name: config.name, args: args, base: config)

        // Engine selection is the registry's decision, not this command's — the CLI
        // and the app must not be able to disagree about which hypervisor a VM runs
        // on, because a VM's disk layout depends on it.
        let engineType = EngineRegistry.engineType(for: config)
        if case .failure(let error) = engineType.availability() {
            // A missing QEMU runtime is the one availability failure the user can
            // act on, and Macport owns that dependency — so it fixes it here rather
            // than telling the user to go drive a package manager.
            guard case EngineError.runtimeMissing = error else {
                fail("\(error.localizedDescription)\n")
            }
            print("This machine needs the QEMU runtime. Macport will install it.\n")
            do {
                _ = try await QEMURuntime.install { line in
                    print(line)
                }
                print("")
            } catch {
                fail("\(error.localizedDescription)\n")
            }
        }

        if config.guest.requiresTPM && !engineType.capabilities(for: config.guest).tpm {
            print("""
            NOTE  \(config.guest.displayName) requires a TPM 2.0 device and no engine
                  Macport ships provides one yet. Windows Setup will refuse at the
                  "This PC can't run Windows 11" screen. To continue:

                    Shift-F10  to open a command prompt
                    regedit  →  HKLM\\SYSTEM\\Setup\\LabConfig
                    create DWORD  BypassTPMCheck         = 1
                    create DWORD  BypassSecureBootCheck  = 1
                    close both windows, click Back, then Next again

            """)
        }

        let store = await VMStore()
        // Persist any overrides so the app sees the same machine this command is
        // booting — otherwise the CLI and the GUI would disagree about the VM.
        _ = try? await store.save(config)

        let bundle = await store.bundleURL(for: config)
        let engine = await EngineRegistry.makeEngine(for: config)

        print("Engine: \(engineType.displayName)")

        do {
            try await engine.create(config, in: bundle)
            try await engine.start(config, in: bundle)
            print("Started \(config.name). Press Ctrl-C to stop.")
        } catch {
            fail("\(error.localizedDescription)\n")
        }

        // Poll rather than compare inline: `await` cannot sit to the right of `||`,
        // because the operator's right side is an autoclosure that does not support
        // concurrency.
        while true {
            let current = await engine.state
            if current != .running && current != .starting { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Report *why* it ended. Looping silently on a dead machine is worse than
        // failing loudly.
        let outcome = await engine.state
        if outcome == .error {
            let detail = await engine.lastError ?? "no detail reported"
            fail("The virtual machine stopped with an error: \(detail)\n")
        }
        print("The virtual machine stopped.")
    }

    static func stop(_ args: [String]) async {
        // A VM's lifetime belongs to the process that started it, so a separate
        // invocation cannot reach it. Report that honestly rather than pretend to
        // have stopped something.
        fail("""
        macportctl cannot stop a VM started by another process yet.

        A virtual machine's lifecycle is owned by the process that booted it, and \
        there is no control socket between invocations. Stopping one from a second \
        command needs a host control channel in MacportKit — tracked for Phase 2.

        For now: press Ctrl-C in the terminal that started it, or use the Macport app.

        """)
    }

    // MARK: - Configuration from flags

    /// Build a configuration from CLI flags.
    ///
    /// Shared by `create` and `start` so the two accept the same vocabulary and
    /// cannot drift into disagreeing about what `--memory` means.
    static func configuration(
        name: String,
        args: [String],
        base: VMConfiguration? = nil
    ) -> VMConfiguration {
        var config = base ?? VMConfiguration(
            name: name,
            guest: parseGuest(value(of: "--guest", in: args) ?? "linux") ?? .linuxARM
        )

        if let iso = value(of: "--iso", in: args) {
            config.boot = .installMedia(path: iso)
        }
        if let gb = value(of: "--memory", in: args).flatMap(Int.init) {
            config.memoryBytes = UInt64(gb) * 1024 * 1024 * 1024
        }
        if let gb = value(of: "--disk", in: args).flatMap(Int.init) {
            config.diskBytes = UInt64(gb) * 1024 * 1024 * 1024
        }
        if let count = value(of: "--cpu", in: args).flatMap(Int.init) {
            config.cpuCount = count
        }
        if let engine = value(of: "--engine", in: args) {
            config.engineIdentifier = engine.lowercased()
        }
        if let folder = value(of: "--shared-folder", in: args) {
            config.sharedFolders.append(SharedFolder(hostPath: folder))
        }
        if args.contains("--no-network") {
            config.network = .disconnected
        }
        return config
    }

    // MARK: - Helpers

    static func find(_ name: String) async -> VMConfiguration? {
        let store = await VMStore()
        await store.load()
        let machines = await store.machines
        guard let match = machines.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            FileHandle.standardError.write(Data("No virtual machine named '\(name)'.\n".utf8))
            return nil
        }
        return match
    }

    static func parseGuest(_ raw: String) -> GuestKind? {
        switch raw.lowercased() {
        case "linux", "linux-arm", "linuxarm": return .linuxARM
        case "windows", "windows-arm", "windowsarm", "win11": return .windowsARM
        case "macos": return .macOSGuest
        default: return nil
        }
    }

    static func describe(_ boot: BootSource) -> String {
        switch boot {
        case .diskOnly:
            return "existing disk"
        case .installMedia(let path):
            return "install media — \(URL(fileURLWithPath: path).lastPathComponent)"
        case .kernelImage(let kernel, _):
            return "kernel — \(URL(fileURLWithPath: kernel).lastPathComponent)"
        }
    }

    static func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    static func pad(_ string: String, _ width: Int) -> String {
        string.count >= width
            ? string
            : string + String(repeating: " ", count: width - string.count)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(message.utf8))
        exit(1)
    }

    static func printUsage() {
        print(
            """
            macportctl — command-line control for Macport virtual machines

            USAGE
              macportctl <command> [options]

            COMMANDS
              list                       List virtual machines
              capabilities [guest]       Show engines, their limits, and routing
              runtime [status|install]   Inspect or install the QEMU runtime
              create <name> [options]    Create a VM
              start <name> [options]     Boot a VM (creates its disk on first run)
              stop <name>                Not supported yet — see below
              path                       Print the VM storage directory
              help                       Show this message

            OPTIONS (create and start accept the same set)
              --guest <linux|windows|macos>
              --iso <path>               Install media to boot
              --cpu <n>                  Virtual processors
              --memory <gb>              RAM in GB
              --disk <gb>                Disk ceiling in GB
              --engine <vz|qemu>         Pin an engine; by default the guest decides
              --shared-folder <path>     Share a host directory, read-only
              --no-network               Leave the guest disconnected

            ENGINES
              Virtualization.framework runs a guest on the metal with virtio devices.
              It is the leaner engine and is preferred whenever it can host the guest.

              QEMU adds what that framework does not have — a real CD-ROM device, and
              so the ability to boot vendor installer media. Windows 11 Arm needs it,
              because Windows installers carry no MBR, no GPT and no FAT ESP and
              bootstrap purely through El Torito, which firmware only honours on media
              it identifies as optical.

            NOTES
              No engine Macport ships provides a virtual TPM yet, so Windows 11 setup
              needs its TPM check bypassed. `start` prints the exact steps.

              VM directory: \(VMStore.defaultRoot.path)
            """
        )
    }
}
