import Foundation

/// The host resources a VM start has to fit inside.
///
/// A value type with injected numbers rather than a pile of `ProcessInfo` calls,
/// because the rules below are the part worth testing — and a test cannot change
/// how much RAM the Mac running it has. Production asks for `.current`; tests
/// hand in whatever scenario they are checking.
public struct HostCapacity: Sendable, Hashable {
    /// Physical RAM on the host, in bytes.
    public var physicalMemory: UInt64
    /// Logical CPU count, as reported by the host.
    public var processorCount: Int
    /// Free space on the volume that holds the VM bundles, in bytes.
    ///
    /// Optional because there is no honest value if the filesystem refuses to
    /// report one: `0` would mean "totally full" and block every start. `nil`
    /// skips the disk check and says so in the code path that skips it.
    public var freeDiskBytes: UInt64?

    public init(
        physicalMemory: UInt64,
        processorCount: Int,
        freeDiskBytes: UInt64? = nil
    ) {
        self.physicalMemory = physicalMemory
        self.processorCount = processorCount
        self.freeDiskBytes = freeDiskBytes
    }

    // MARK: - The real host

    /// Capacity of the machine running this process, with the disk space that
    /// matters for VM bundles.
    public static var current: HostCapacity {
        current(freeDiskAt: VMStore.defaultRoot)
    }

    /// Capacity as seen when VM bundles live at `url`.
    ///
    /// The free-space probe walks up to the nearest existing ancestor, because at
    /// first launch neither the VM root nor its parent may exist yet.
    public static func current(freeDiskAt url: URL) -> HostCapacity {
        HostCapacity(
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            freeDiskBytes: freeDiskSpace(at: url)
        )
    }

    /// Available space on the volume containing `url`.
    ///
    /// `volumeAvailableCapacityForImportantUsage` is the number that matters:
    /// macOS may reclaim purgeable space for a user-initiated operation, so it is
    /// larger than the plain "available" figure on a normal Mac. Falls back to
    /// the conservative value when the richer one is unavailable.
    static func freeDiskSpace(at url: URL) -> UInt64? {
        let fm = FileManager.default
        var probe = url
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { return nil }
            probe = parent
        }

        guard let values = try? probe.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) else {
            return nil
        }

        if let important = values.volumeAvailableCapacityForImportantUsage {
            return UInt64(max(0, important))
        }
        if let available = values.volumeAvailableCapacity {
            return UInt64(max(0, available))
        }
        return nil
    }

    // MARK: - Admission

    /// Admit or refuse `config` against the real host and the VMs already up.
    ///
    /// Convenience over `AdmissionControl` so a caller holding a capacity value
    /// reads naturally: `capacity.check(config, running: others)`.
    public static func check(
        _ config: VMConfiguration,
        running: [VMConfiguration]
    ) -> Result<Void, EngineError> {
        AdmissionControl.check(config, running: running, capacity: .current)
    }

    /// The fully explicit form: every input is the caller's.
    public static func check(
        _ config: VMConfiguration,
        running: [VMConfiguration],
        capacity: HostCapacity
    ) -> Result<Void, EngineError> {
        AdmissionControl.check(config, running: running, capacity: capacity)
    }
}

/// Refuses a VM start the host cannot honestly support.
///
/// This runs in `VMRuntimeRegistry.start`, never in the UI. A rule enforced in a
/// view is a suggestion: the CLI, a restored session or a second window would all
/// bypass it. Enforcing it at the one place every start passes through is what
/// makes "the host does not oversubscribe itself" a property of the runtime.
public enum AdmissionControl {
    public static let mebibyte: UInt64 = 1024 * 1024
    public static let gibibyte: UInt64 = 1024 * mebibyte

    /// Reserve at least this much for macOS.
    public static let minimumReserve: UInt64 = 2 * gibibyte

    /// Disk safety floor: fixed headroom plus a fraction of the declared disk.
    public static let diskFloor: UInt64 = 2 * gibibyte

    /// Fraction of the declared disk size that must be free, as a divisor.
    /// 5% expressed as `/ 20` to avoid floating point in the admission path.
    public static let diskFractionDivisor: UInt64 = 20

    // MARK: - Checks

    /// Admit or refuse `config` against the real host and the VMs already up.
    public static func check(
        _ config: VMConfiguration,
        running: [VMConfiguration]
    ) -> Result<Void, EngineError> {
        check(config, running: running, capacity: .current)
    }

    /// The testable entry point: every input is explicit.
    public static func check(
        _ config: VMConfiguration,
        running: [VMConfiguration],
        capacity: HostCapacity
    ) -> Result<Void, EngineError> {
        if let failure = checkMemory(config, running: running, capacity: capacity) {
            return .failure(failure)
        }
        if let failure = checkCPUs(config, running: running, capacity: capacity) {
            return .failure(failure)
        }
        if let failure = checkDisk(config, capacity: capacity) {
            return .failure(failure)
        }
        return .success(())
    }

    // MARK: - Individual rules

    /// RAM: running guests plus this one must fit under `physical - reserve`.
    static func checkMemory(
        _ config: VMConfiguration,
        running: [VMConfiguration],
        capacity: HostCapacity
    ) -> EngineError? {
        let reserve = max(minimumReserve, capacity.physicalMemory / 8)
        let usable = capacity.physicalMemory > reserve
            ? capacity.physicalMemory - reserve
            : 0

        let runningMemory = sum(running.map(\.memoryBytes))
        let requested = adding(runningMemory, config.memoryBytes)

        guard requested <= usable else {
            return .hostResourceUnavailable(
                "This Mac has \(capacity.physicalMemory.gbString) of memory. "
                    + "Macport reserves \(reserve.gbString) for macOS, leaving "
                    + "\(usable.gbString) usable. \(runningMemory.gbString) is already "
                    + "allocated to running virtual machines and this one asks for "
                    + "\(config.memoryBytes.gbString), a total of \(requested.gbString). "
                    + "Stop a virtual machine or lower its memory."
            )
        }
        return nil
    }

    /// CPUs: leave at least one host core for macOS and the UI.
    static func checkCPUs(
        _ config: VMConfiguration,
        running: [VMConfiguration],
        capacity: HostCapacity
    ) -> EngineError? {
        let usable = max(1, capacity.processorCount - 1)
        let requested = max(1, running.reduce(0) { $0 + max(1, $1.cpuCount) })
            + max(1, config.cpuCount)

        guard requested <= usable else {
            return .hostResourceUnavailable(
                "This Mac has \(capacity.processorCount) processors and Macport keeps "
                    + "one for the system, leaving \(usable) for guests. The running "
                    + "virtual machines use "
                    + "\(max(1, running.reduce(0) { $0 + max(1, $1.cpuCount) })) and this "
                    + "one asks for \(max(1, config.cpuCount)), a total of \(requested). "
                    + "Stop a virtual machine or lower its processor count."
            )
        }
        return nil
    }

    /// Disk: a sparse disk is not a full allocation, so this is a floor rather
    /// than a reservation — but a start that cannot write its image will fail
    /// halfway through, which is worse than refusing now.
    static func checkDisk(
        _ config: VMConfiguration,
        capacity: HostCapacity
    ) -> EngineError? {
        guard let free = capacity.freeDiskBytes else {
            // The filesystem declined to report free space. Refusing every start
            // would be worse than proceeding; the engine still reports write
            // failures honestly.
            return nil
        }

        let fraction = config.diskBytes / diskFractionDivisor
        let required = adding(diskFloor, fraction)

        guard free >= required else {
            return .hostResourceUnavailable(
                "The volume holding your virtual machines has \(free.gbString) free. "
                    + "This machine needs at least \(required.gbString) — a "
                    + "\(diskFloor.gbString) safety floor plus 5% of its "
                    + "\(config.diskBytes.gbString) disk. Free space or choose a smaller disk."
            )
        }
        return nil
    }

    // MARK: - Arithmetic

    /// Saturating add: an absurd configuration must be refused with numbers,
    /// never trap in a release build.
    static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    static func sum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { adding($0, $1) }
    }
}
