import Combine
import Foundation
import Virtualization
import MacportKit

/// The app's view of what is running, and the one seam between SwiftUI and the
/// runtime.
///
/// `AppState` deliberately no longer owns an engine or the "currently running VM"
/// id. It keeps its name — the UI talks to it everywhere — but it is now a facade
/// over `VMRuntimeRegistry`, which owns every running machine. Two VMs up at once
/// is therefore an ordinary case here, not a special one, and admission control
/// (in the registry) decides whether a start is honest before it happens.
@MainActor
final class AppState: ObservableObject {
    @Published var isPresentingCreateSheet = false

    /// Surfaced to the user. Cleared by `dismissError()`.
    @Published var errorMessage: String?

    /// Non-fatal notice, e.g. an honest capability warning before an install.
    @Published var notice: String?

    // MARK: - QEMU runtime installation

    /// Non-nil while Macport is installing the QEMU runtime, holding the latest
    /// line of installer output. This is the whole reason the installer reports
    /// progress as text: it can take minutes and silence reads as a hang.
    @Published private(set) var runtimeInstallProgress: String?
    @Published private(set) var isInstallingRuntime = false

    /// The runtime that actually holds running machines.
    ///
    /// Exposed rather than hidden so a view can observe the registry directly if
    /// it ever needs per-instance detail this facade does not forward.
    let registry: VMRuntimeRegistry

    /// Republished so SwiftUI re-renders when a VM appears, changes state or is
    /// stopped. The registry's own notifications drive this; there is no copy of
    /// the state to fall out of sync.
    var instances: [UUID: VMInstance] { registry.instances }

    private var registryObservation: AnyCancellable?

    init(registry: VMRuntimeRegistry = VMRuntimeRegistry()) {
        self.registry = registry
        // The registry announces state changes on the main actor; AppState
        // mirrors them so every view observing AppState stays live without
        // knowing the registry exists.
        registryObservation = registry.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.objectWillChange.send()
                }
            }

        // A QEMU host outlives the app that launched it. Without this the window
        // would show a running machine as absent after a relaunch; the registry
        // verifies pid and socket before believing a runtime.json record.
        Task { await registry.adoptRunningHosts() }
    }

    // MARK: - Engine selection

    /// The engine that will host `config`.
    ///
    /// Exposed so the UI can name it rather than leaving the user to infer which
    /// hypervisor they are about to run on.
    func hostingEngine(for config: VMConfiguration) -> any VMEngine.Type {
        EngineRegistry.engineType(for: config)
    }

    /// What the hosting engine can and cannot do for this VM's guest.
    func capabilities(for config: VMConfiguration) -> EngineCapabilities {
        hostingEngine(for: config).capabilities(for: config.guest)
    }

    /// Warnings that must be shown before a guest is installed.
    ///
    /// These are stated up front on purpose. Every outlet in this space either
    /// hides these limits or lets the user discover them by failure, and a user who
    /// has just downloaded an 8 GB ISO deserves the warning first.
    func warnings(for config: VMConfiguration) -> [String] {
        var warnings: [String] = []
        let engineType = hostingEngine(for: config)
        let caps = engineType.capabilities(for: config.guest)

        if let rationale = EngineRegistry.rationale(for: config) {
            warnings.append(rationale)
        }

        if config.guest.requiresTPM && !caps.tpm {
            warnings.append(
                "No engine Macport ships can provide a virtual TPM yet, and "
                    + "\(config.guest.displayName) setup requires TPM 2.0. Windows setup "
                    + "will need its TPM check bypassed — Shift-F10, then the LabConfig "
                    + "registry keys. Macport prints the exact steps when you start it."
            )
        }

        if config.guest == .windowsARM {
            warnings.append(
                "Windows on Arm runs x86 software through Microsoft's Prism translation "
                    + "layer. Macport cannot make those programs native — no architecture can."
            )
        }

        if !caps.snapshots {
            warnings.append("\(engineType.displayName) does not support snapshots yet.")
        }

        return warnings
    }

    // MARK: - Creation

    /// Persist the configuration and prepare its bundle. Does not start it.
    func create(_ config: VMConfiguration, in store: VMStore) {
        do {
            let saved = try store.save(config)
            let engine = EngineRegistry.makeEngine(for: saved)
            let bundle = store.bundleURL(for: saved)
            Task {
                do {
                    try await engine.create(saved, in: bundle)
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Lifecycle

    /// Start a VM. Fire-and-forget: the registry owns the state and surfaces
    /// failures through `errorMessage`.
    func start(_ config: VMConfiguration, in store: VMStore) {
        Task {
            do {
                try await registry.start(config, in: store)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Stop one VM. Errors are surfaced, and the machine stays listed if the
    /// engine refused to stop it.
    func stop(id: UUID, graceful: Bool = true) async {
        do {
            try await registry.stop(id, graceful: graceful)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pause(id: UUID) async {
        do {
            try await registry.pause(id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resume(id: UUID) async {
        do {
            try await registry.resume(id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Per-VM queries

    func instance(for id: UUID) -> VMInstance? { registry.instance(id) }

    func state(for id: UUID) -> VMState { registry.state(of: id) }

    /// Is this VM up (running, paused or in a transition)? Drives the sidebar dot
    /// and the detail pane's power controls.
    func isRunning(_ id: UUID) -> Bool { state(for: id).isActive }

    /// The live machine for the in-app framebuffer, when this VM's engine has one
    /// the app can embed.
    ///
    /// Only Virtualization.framework exposes a machine object bindable to a view.
    /// QEMU renders to its own window, so this is nil there — deliberately nil
    /// rather than a blank pane that looks like a failure.
    func liveMachine(for id: UUID) -> VZVirtualMachine? {
        (registry.instance(id)?.engine as? VZEngine)?.virtualMachine
    }

    /// Is this VM rendering in a window the app does not own?
    func runsInExternalWindow(for id: UUID) -> Bool {
        registry.instance(id)?.runsInExternalWindow ?? false
    }

    /// The engine holding this VM, once it is up. `nil` when it is not running;
    /// the UI falls back to the engine that *will* host it.
    func engineName(for id: UUID) -> String? {
        registry.instance(id)?.engineName
    }

    // MARK: - QEMU runtime

    var isQEMURuntimeInstalled: Bool { QEMURuntime.isInstalled }

    /// Install the QEMU runtime that Windows and other guests need.
    ///
    /// Macport owns this dependency so the user never has to drive a package
    /// manager by hand.
    func installQEMURuntime() {
        guard !isInstallingRuntime else { return }
        isInstallingRuntime = true
        runtimeInstallProgress = "Starting…"

        Task {
            do {
                _ = try await QEMURuntime.install { line in
                    Task { @MainActor in
                        self.runtimeInstallProgress = line
                    }
                }
                await MainActor.run {
                    self.isInstallingRuntime = false
                    self.runtimeInstallProgress = nil
                    self.notice = "The QEMU runtime is installed. Windows guests can run now."
                }
            } catch {
                await MainActor.run {
                    self.isInstallingRuntime = false
                    self.runtimeInstallProgress = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func dismissError() { errorMessage = nil }
    func dismissNotice() { notice = nil }
}
