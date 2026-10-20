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
        case "status":
            await status(args)
        case "pause":
            await pause(args)
        case "resume":
            await resume(args)
        case "snapshots":
            await snapshots(args)
        case "snapshot":
            await snapshot(args)
        case "restore":
            await restore(args)
        case "delete-snapshot":
            await deleteSnapshot(args)
        case "clone":
            await clone(args)
        case "import":
            await importImage(args)
        case "disk":
            await disk(args)
        case "delete", "rm":
            await delete(args)
        case "host-path":
            hostPath()
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
            fail("Usage: macportctl start <name> [options] [--foreground]\n")
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

        if ObjectIdentifier(engineType) == ObjectIdentifier(QEMUEngine.self) {
            await startHosted(config, in: bundle, args: args)
            return
        }

        // Virtualization.framework's display object is bound to the process that
        // created it, so a VZ guest cannot be handed to a separate host without a
        // frame-transport layer. It therefore stays in this process, and this
        // command stays in the foreground until the guest stops. That is a stated
        // engine capability, not an unfinished path.
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

    /// Launch the per-VM host and return once it answers.
    ///
    /// QEMU is the engine that can outlive this command. The host is detached, so
    /// its lifetime is the guest's, not the terminal's; `--foreground` is the
    /// opt-in to the old blocking behaviour when someone wants the diagnostics.
    static func startHosted(
        _ config: VMConfiguration,
        in bundle: URL,
        args: [String]
    ) async {
        let socketPath = VMHostRuntime.socketPath(for: bundle, vmID: config.id)

        if let metadata = VMHostRuntime.readMetadata(in: bundle),
           VMHostRuntime.isProcessAlive(pid: metadata.pid) {
            fail("\(config.name) is already running (pid \(metadata.pid)). Stop it first.\n")
        }
        // A dead pid's record describes a host that is gone; leaving it would
        // make the next start look like a double start.
        VMHostRuntime.removeMetadata(in: bundle)

        do {
            _ = try VMHostLauncher.resolve()
        } catch {
            fail("\(error.localizedDescription)\n")
        }

        if args.contains("--foreground") {
            print("Engine: \(QEMUEngine.displayName)")
            do {
                let status = try VMHostLauncher.runForeground(
                    config,
                    bundle: bundle,
                    socketPath: socketPath
                )
                exit(status)
            } catch {
                fail("\(error.localizedDescription)\n")
            }
        }

        do {
            let metadata = try await VMHostLauncher.launchDetached(
                config,
                bundle: bundle,
                socketPath: socketPath,
                logURL: VMHostRuntime.hostLogURL(in: bundle)
            )
            print(
                "\(config.name) is running (pid \(metadata.pid), "
                    + "engine \(QEMUEngine.displayName))"
            )
        } catch {
            fail("\(error.localizedDescription)\n")
        }
    }

    static func status(_ args: [String]) async {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("Usage: macportctl status <name> [--json]\n")
        }
        guard let config = await find(name) else { exit(1) }
        let store = await VMStore()
        await store.load()
        let bundle = await store.bundleURL(for: config)
        let metadata = requireRunning(config, in: bundle)

        let response = await send(.status, to: metadata, name: config.name)
        guard case .status(let status)? = response.payload else {
            fail("\(config.name): the host returned no status payload.\n")
        }

        if args.contains("--json") {
            let encoder = VMControl.makeEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try encoder.encode(status)
                print(String(decoding: data, as: UTF8.self))
            } catch {
                fail("Could not encode status: \(error.localizedDescription)\n")
            }
            return
        }

        print("Name    : \(config.name)")
        print("State   : \(status.state.rawValue)")
        print("Engine  : \(EngineRegistry.displayName(forIdentifier: status.engineIdentifier))")
        print("PID     : \(status.pid)")
        print("Started : \(dateString(status.startedAt))")
        print("Uptime  : \(uptimeString(since: status.startedAt))")
    }

    static func stop(_ args: [String]) async {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("Usage: macportctl stop <name> [--force]\n")
        }
        let force = args.contains("--force")
        guard let config = await find(name) else { exit(1) }
        let store = await VMStore()
        await store.load()
        let bundle = await store.bundleURL(for: config)
        let metadata = requireRunning(config, in: bundle)

        // A graceful guest shutdown can legitimately take longer than the
        // default one-exchange timeout: the host gives the guest up to eight
        // seconds, then terminates QEMU and waits for it to exit. Failing here
        // on that budget used to skip `shutdownHost` entirely, leaving a host
        // alive with no VM and no way to start it again. The stop is best-effort
        // on purpose — retiring the host force-stops an unresponsive engine.
        let stopClient = VMControlClient(
            socketPath: metadata.socketPath,
            connectTimeout: 2,
            commandTimeout: 25
        )
        do {
            let response = try await stopClient.send(VMControlRequest(command: .stop(graceful: !force)))
            if !response.ok {
                FileHandle.standardError.write(
                    Data("\(config.name): \(response.error ?? "the host refused the stop request")\n".utf8)
                )
            }
        } catch {
            FileHandle.standardError.write(
                Data("\(config.name): \(error.localizedDescription)\n".utf8)
            )
        }

        // `stop` powers the guest off; `shutdownHost` retires the process that
        // owns it, so a later `start` is not refused by a stale lock.
        await shutdownHost(metadata)

        let exited = await waitForExit(pid: metadata.pid, timeout: 20)
        if !exited && force {
            kill(metadata.pid, SIGKILL)
            _ = await waitForExit(pid: metadata.pid, timeout: 2)
        }

        if VMHostRuntime.isProcessAlive(pid: metadata.pid) {
            // Keep the record: the host is still discoverable and retryable
            // with `stop --force`. Removing it here would orphan a live host.
            fail("\(config.name) was asked to stop, but its host (pid \(metadata.pid)) has not exited yet.\n")
        }
        VMHostRuntime.removeMetadata(in: bundle)
        print("Stopped \(config.name).")
    }

    static func pause(_ args: [String]) async {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("Usage: macportctl pause <name>\n")
        }
        guard let config = await find(name) else { exit(1) }
        let store = await VMStore()
        await store.load()
        let bundle = await store.bundleURL(for: config)
        let metadata = requireRunning(config, in: bundle)

        _ = await send(.pause, to: metadata, name: config.name)
        print("Paused \(config.name).")
    }

    static func resume(_ args: [String]) async {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("Usage: macportctl resume <name>\n")
        }
        guard let config = await find(name) else { exit(1) }
        let store = await VMStore()
        await store.load()
        let bundle = await store.bundleURL(for: config)
        let metadata = requireRunning(config, in: bundle)

        _ = await send(.resume, to: metadata, name: config.name)
        print("Resumed \(config.name).")
    }

    static func snapshots(_ args: [String]) async {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("Usage: macportctl snapshots <name>\n")
        }
        guard let config = await find(name) else { exit(1) }
        let store = await VMStore()
        await store.load()
        let bundle = await store.bundleURL(for: config)
        let metadata = requireRunning(config, in: bundle)

        let response = await send(.snapshots, to: metadata, name: config.name)
        guard case .snapshots(let snapshots)? = response.payload else {
            fail("\(config.name): the host returned no snapshot list.\n")
        }
        if snapshots.isEmpty {
            print("No snapshots for \(config.name).")
            return
        }

        let idWidth = max(2, snapshots.map(\.id.count).max() ?? 2)
        let nameWidth = max(4, snapshots.map(\.name.count).max() ?? 4)
        print(
            pad("ID", idWidth) + "  "
                + pad("NAME", nameWidth) + "  "
                + "CREATED             MEMORY"
        )
        for snapshot in snapshots.sorted(by: { $0.createdAt > $1.createdAt }) {
            print(
                pad(snapshot.id, idWidth) + "  "
                    + pad(snapshot.name, nameWidth) + "  "
                    + pad(dateString(snapshot.createdAt), 19) + "  "
                    + (snapshot.includesMemory ? "yes" : "no")
            )
        }
    }

    static func snapshot(_ args: [String]) async {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("Usage: macportctl snapshot <name> --name <snapshot name>\n")
        }
        guard let snapshotName = value(of: "--name", in: args) else {
            fail("Usage: macportctl snapshot <name> --name <snapshot name>\n")
        }
        guard let config = await find(name) else { exit(1) }
        let store = await VMStore()
        await store.load()
        let bundle = await store.bundleURL(for: config)
        let metadata = requireRunning(config, in: bundle)

        let response = await send(.takeSnapshot(name: snapshotName), to: metadata, name: config.name)
        guard case .snapshot(let snapshot)? = response.payload else {
            fail("\(config.name): the host did not return the snapshot it created.\n")
        }
        print("Created '\(snapshot.name)' (id \(snapshot.id)).")
    }

    static func restore(_ args: [String]) async {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("Usage: macportctl restore <name> --snapshot <id>\n")
        }
        guard let snapshotID = value(of: "--snapshot", in: args) else {
            fail("Usage: macportctl restore <name> --snapshot <id>\n")
        }
        guard let config = await find(name) else { exit(1) }
        let store = await VMStore()
        await store.load()
        let bundle = await store.bundleURL(for: config)
        let metadata = requireRunning(config, in: bundle)

        _ = await send(.restoreSnapshot(id: snapshotID), to: metadata, name: config.name)
        print("Restored \(config.name) to snapshot \(snapshotID).")
    }

    static func deleteSnapshot(_ args: [String]) async {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("Usage: macportctl delete-snapshot <name> --snapshot <id>\n")
        }
        guard let snapshotID = value(of: "--snapshot", in: args) else {
            fail("Usage: macportctl delete-snapshot <name> --snapshot <id>\n")
        }
        guard let config = await find(name) else { exit(1) }
        let store = await VMStore()
        await store.load()
        let bundle = await store.bundleURL(for: config)
        let metadata = requireRunning(config, in: bundle)

        _ = await send(.deleteSnapshot(id: snapshotID), to: metadata, name: config.name)
        print("Deleted snapshot \(snapshotID) from \(config.name).")
    }

    static func clone(_ args: [String]) async {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("Usage: macportctl clone <name> [--as <new name>]\n")
        }
        guard let config = await find(name) else { exit(1) }
        let store = await VMStore()
        await store.load()
        let bundle = await store.bundleURL(for: config)

        // A clone is a copy of bytes on disk. Copying a machine that is writing
        // those bytes produces a disk that may not boot, and APFS clonefile is
        // no more trustworthy while a guest is running.
        if let metadata = VMHostRuntime.readMetadata(in: bundle) {
            if VMHostRuntime.isProcessAlive(pid: metadata.pid) {
                fail(
                    "\(config.name) is running (pid \(metadata.pid)). Stop it first: "
                        + "a clone must come from a quiescent disk.\n"
                )
            }
            VMHostRuntime.removeMetadata(in: bundle)
        }

        do {
            let clone = try await VMCloner.clone(
                config,
                in: store,
                named: value(of: "--as", in: args) ?? ""
            )
            let cloneBundle = await store.bundleURL(for: clone)
            print("Cloned \(config.name) as \(clone.name).")
            print("  id     : \(clone.id.uuidString)")
            print("  bundle : \(cloneBundle.path)")
        } catch {
            fail("\(error.localizedDescription)\n")
        }
    }

    static func importImage(_ args: [String]) async {
        guard let sourcePath = args.first, !sourcePath.hasPrefix("-") else {
            fail("""
            Usage: macportctl import <image> --name <name> --guest <kind> [options]

              --guest <linux|windows>  Guest family (required)
              --name <name>            Name for the new machine (required)
              --disk <gb>              Disk ceiling in GB (default: image virtual size)
              --engine <qemu|vz>       Pin an engine (default: chosen by guest)

            """)
        }
        guard let name = value(of: "--name", in: args) else {
            fail("import needs --name <name>.\n")
        }
        guard let guestRaw = value(of: "--guest", in: args),
              let guest = parseGuest(guestRaw) else {
            fail("import needs --guest <linux|windows>. '\(value(of: "--guest", in: args) ?? "")' is not a guest Macport can import.\n")
        }
        guard guest != .macOSGuest else {
            fail("macOS guests need an IPSW restore path, which the disk importer does not provide yet.\n")
        }

        let source = URL(fileURLWithPath: sourcePath)
        guard DiskImporter.isSupported(source) else {
            fail(
                "Macport cannot import \(source.pathExtension.isEmpty ? "a file with no extension" : ".\(source.pathExtension)"). "
                    + "Supported: \(DiskImporter.supportedExtensions.sorted().joined(separator: ", ")).\n"
            )
        }

        let engineArgument = value(of: "--engine", in: args)?.lowercased()
        if let engineArgument, engineArgument != "qemu", engineArgument != "vz" {
            fail("--engine must be qemu or vz, not '\(engineArgument)'.\n")
        }
        let engineType: any VMEngine.Type
        switch engineArgument {
        case "qemu":
            engineType = QEMUEngine.self
        case "vz":
            engineType = VZEngine.self
        default:
            engineType = EngineRegistry.preferredType(for: guest)
        }

        if ObjectIdentifier(engineType) == ObjectIdentifier(VZEngine.self), guest == .windowsARM {
            fail(
                "Virtualization.framework cannot host Windows: it has no TPM or "
                    + "optical device. Use --engine qemu.\n"
            )
        }
        if case .failure(let error) = engineType.availability() {
            fail("\(error.localizedDescription)\n")
        }

        let info: DiskImporter.DiskInfo
        do {
            info = try DiskImporter.inspect(source)
        } catch {
            fail("\(error.localizedDescription)\n")
        }

        var diskBytes = info.virtualSize ?? 0
        if let gb = value(of: "--disk", in: args) {
            guard let value = Int(gb), value > 0 else {
                fail("--disk expects a positive whole number of gigabytes.\n")
            }
            diskBytes = UInt64(value) * 1024 * 1024 * 1024
        }
        guard diskBytes > 0 else {
            fail("qemu-img did not report a virtual size for this image; pass --disk <gb>.\n")
        }

        var config = VMConfiguration(
            name: name,
            guest: guest,
            diskBytes: diskBytes,
            boot: .diskOnly
        )
        // Pin the engine that was chosen now. The disk format below is that
        // engine's format, so a later availability change must not reroute the
        // machine to an engine that cannot read it.
        config.engineIdentifier = engineType.identifier

        let store = await VMStore()
        await store.load()
        let bundle = await store.bundleURL(for: config)

        // The exact names the engines' own `create` methods expect. QEMU probes
        // `disk.qcow2` first (the snapshot-capable default); VZ opens `disk.img`
        // and treats it as raw.
        let isQEMU = ObjectIdentifier(engineType) == ObjectIdentifier(QEMUEngine.self)
        let diskName = isQEMU ? "disk.qcow2" : "disk.img"
        let format: DiskImporter.TargetFormat = isQEMU ? .qcow2 : .raw

        do {
            let saved = try await store.save(config)
            let destination = await store.bundleURL(for: saved).appendingPathComponent(diskName)
            _ = try DiskImporter.convert(source, to: destination, format: format)
            print("Imported \(saved.name) as \(saved.id.uuidString)")
            print("  engine : \(engineType.displayName)")
            print("  disk   : \(destination.path) (\(info.format) → \(format.rawValue), \(saved.diskBytes.gbString))")
        } catch {
            // A half-converted bundle would appear in `list` and fail to boot.
            try? FileManager.default.removeItem(at: bundle)
            await store.load()
            fail("\(error.localizedDescription)\n")
        }
    }

    static func disk(_ args: [String]) async {
        guard args.first == "convert", args.count >= 3 else {
            fail("Usage: macportctl disk convert <source> <destination> [--format qcow2|raw]\n")
        }
        let source = URL(fileURLWithPath: args[1])
        let destination = URL(fileURLWithPath: args[2])
        let formatName = value(of: "--format", in: args) ?? "qcow2"
        guard let format = DiskImporter.TargetFormat(rawValue: formatName) else {
            fail("--format must be qcow2 or raw, not '\(formatName)'.\n")
        }

        do {
            let info = try DiskImporter.convert(source, to: destination, format: format)
            print("Converted \(source.path) → \(destination.path)")
            print("  format : \(format.rawValue)")
            print("  size   : \((info.virtualSize ?? 0).gbString)")
        } catch {
            fail("\(error.localizedDescription)\n")
        }
    }

    static func delete(_ args: [String]) async {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("Usage: macportctl delete <name> [--force]\n")
        }
        let force = args.contains("--force")
        guard let config = await find(name) else { exit(1) }
        let store = await VMStore()
        await store.load()
        let bundle = await store.bundleURL(for: config)

        if let metadata = VMHostRuntime.readMetadata(in: bundle),
           VMHostRuntime.isProcessAlive(pid: metadata.pid) {
            guard force else {
                fail(
                    "\(config.name) is running (pid \(metadata.pid)). Stop it first with "
                        + "`macportctl stop \(config.name)`, or pass --force to stop and delete it.\n"
                )
            }
            let client = VMControlClient(socketPath: metadata.socketPath)
            _ = try? await client.send(VMControlRequest(command: .stop(graceful: false)))
            await shutdownHost(metadata)
            let exited = await waitForExit(pid: metadata.pid, timeout: 10)
            if !exited {
                kill(metadata.pid, SIGKILL)
                _ = await waitForExit(pid: metadata.pid, timeout: 2)
            }
            if VMHostRuntime.isProcessAlive(pid: metadata.pid) {
                fail("Could not stop the background host (pid \(metadata.pid)).\n")
            }
        }

        // The store owns everything under its root, but a path that is not a
        // `.macport` bundle means something is wrong with the record; deleting it
        // would be the wrong repair.
        guard bundle.pathExtension == "macport" else {
            fail("Refusing to delete \(bundle.path): it is not a .macport bundle.\n")
        }

        do {
            try FileManager.default.removeItem(at: bundle)
        } catch {
            fail("Could not delete \(bundle.path): \(error.localizedDescription)\n")
        }
        await store.load()
        print("Deleted \(config.name).")
    }

    static func hostPath() {
        do {
            print(try VMHostLauncher.resolve().path)
        } catch {
            fail("\(error.localizedDescription)\n")
        }
    }

    // MARK: - Control helpers

    /// The metadata for a machine that is genuinely up.
    ///
    /// A live pid is not enough — a host can be wedged — but a dead pid is
    /// conclusive, so its record is removed and the caller is told the machine is
    /// not running rather than being handed a socket that cannot answer.
    static func requireRunning(_ config: VMConfiguration, in bundle: URL) -> VMHostMetadata {
        guard let metadata = VMHostRuntime.readMetadata(in: bundle) else {
            fail("\(config.name) is not running.\n")
        }
        guard VMHostRuntime.isProcessAlive(pid: metadata.pid) else {
            VMHostRuntime.removeMetadata(in: bundle)
            fail("\(config.name) is not running (its recorded pid \(metadata.pid) has exited).\n")
        }
        return metadata
    }

    static func send(
        _ command: VMControlCommand,
        to metadata: VMHostMetadata,
        name: String
    ) async -> VMControlResponse {
        let client = VMControlClient(socketPath: metadata.socketPath)
        do {
            let response = try await client.send(VMControlRequest(command: command))
            guard response.ok else {
                fail("\(name): \(response.error ?? "the background host refused the command")\n")
            }
            return response
        } catch {
            fail("\(name): \(error.localizedDescription)\n")
        }
    }

    /// Best-effort retirement of the host process. The caller waits for the pid.
    static func shutdownHost(_ metadata: VMHostMetadata) async {
        let client = VMControlClient(
            socketPath: metadata.socketPath,
            connectTimeout: 2,
            commandTimeout: 5
        )
        _ = try? await client.send(VMControlRequest(command: .shutdownHost))
    }

    static func waitForExit(pid: Int32, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !VMHostRuntime.isProcessAlive(pid: pid) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !VMHostRuntime.isProcessAlive(pid: pid)
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func uptimeString(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(remainder)s" }
        if minutes > 0 { return "\(minutes)m \(remainder)s" }
        return "\(remainder)s"
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
              stop <name> [--force]      Stop a running VM
              status <name> [--json]     Show state, engine, pid and uptime
              pause <name>               Suspend a running guest in memory
              resume <name>              Continue a paused guest
              snapshots <name>           List snapshots
              snapshot <name> --name <n> Create a snapshot
              restore <name> --snapshot <id>
                                         Restore a snapshot
              delete-snapshot <name> --snapshot <id>
                                         Delete a snapshot
              clone <name> [--as <name>] Clone a stopped VM
              import <image> --name <name> --guest <kind> [--disk <gb>] [--engine qemu|vz]
                                         Create a VM from an existing disk image
              disk convert <src> <dst> [--format qcow2|raw]
                                         Convert a disk image
              delete <name> [--force]    Delete a VM and its bundle
              host-path                  Print the resolved MacportVMHost path
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
              --foreground               (start) run the QEMU host in this terminal

            ENGINES
              Virtualization.framework runs a guest on the metal with virtio devices.
              It is the leaner engine and is preferred whenever it can host the guest.
              Its display is bound to the process that creates it, so VZ guests stop
              with the app or CLI that started them.

              QEMU adds what that framework does not have — a real CD-ROM device, and
              so the ability to boot vendor installer media. Windows 11 Arm needs it,
              because Windows installers carry no MBR, no GPT and no FAT ESP and
              bootstrap purely through El Torito, which firmware only honours on media
              it identifies as optical. QEMU machines run in a per-VM MacportVMHost
              process and keep running when the app or this command exits.

            NOTES
              No engine Macport ships provides a virtual TPM yet, so Windows 11 setup
              needs its TPM check bypassed. `start` prints the exact steps.

              VM directory: \(VMStore.defaultRoot.path)
            """
        )
    }
}
