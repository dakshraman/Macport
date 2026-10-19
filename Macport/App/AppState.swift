import Foundation
import Virtualization
import MacportKit

/// Owns the currently running machine and brokers engine selection.
///
/// One running VM at a time is a deliberate v1 constraint. It keeps resource
/// accounting honest — the host does not silently oversubscribe itself because
/// the user started four machines — and it matches how most people use a
/// desktop hypervisor. Lifting it later means turning `engine` into a
/// dictionary keyed by VM id.
@MainActor
final class AppState: ObservableObject {
    @Published var isPresentingCreateSheet = false

    /// The VM currently powered on, if any.
    @Published private(set) var runningVMID: UUID?

    /// Which engine is running it. Worth surfacing: the same guest on a different
    /// engine is a different machine, and users debug far faster when the UI says
    /// which hypervisor they are actually on.
    @Published private(set) var runningEngineName: String?

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

    private(set) var engine: (any VMEngine)?

    var isBusy: Bool { runningVMID != nil }

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

    // MARK: - Lifecycle

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

    func start(_ config: VMConfiguration, in store: VMStore) {
        guard !isBusy else {
            errorMessage = "Stop the running virtual machine first. Macport runs one at a time."
            return
        }

        let engineType = hostingEngine(for: config)
        if case .failure(let error) = engineType.availability() {
            errorMessage = error.localizedDescription
            return
        }

        let engine = EngineRegistry.makeEngine(for: config)
        self.engine = engine
        self.runningEngineName = engineType.displayName
        let bundle = store.bundleURL(for: config)

        Task {
            do {
                try await engine.start(config, in: bundle)
                await MainActor.run { self.runningVMID = config.id }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.runningVMID = nil
                    self.runningEngineName = nil
                    self.engine = nil
                }
            }
        }
    }

    func stop(graceful: Bool = true) async {
        guard let engine else { return }
        do {
            if graceful {
                try await engine.stop()
            } else {
                try await engine.forceStop()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        runningVMID = nil
        runningEngineName = nil
        self.engine = nil
    }

    // MARK: - Display

    /// The live machine for the in-app framebuffer, when the running engine has
    /// one the app can embed.
    ///
    /// Only Virtualization.framework exposes a machine object bindable to a view.
    /// QEMU renders to its own window, so this is nil there — deliberately nil
    /// rather than a blank pane that looks like a failure.
    var liveMachine: VZVirtualMachine? { (engine as? VZEngine)?.virtualMachine }

    /// Is the running machine rendering in a window the app does not own?
    var runsInExternalWindow: Bool { engine is QEMUEngine }

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
