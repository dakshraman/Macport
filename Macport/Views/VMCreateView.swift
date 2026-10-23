import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacportKit

/// The signature Parallels Desktop + UTM style Installation Assistant.
///
/// Provides a guided 4-step wizard:
/// 1. Operating System Selection (Windows 11 on Arm, Linux distros, macOS, Custom Image)
/// 2. Primary Use Profile (Productivity, Software Development, Gaming & High Performance, Custom)
/// 3. Configuration & Mac Integration (One-click Desktop/Documents/Downloads folder sharing, media picker, hardware tuning)
/// 4. Review & Honesty Check (Hardware breakdown, Virtio drivers, TPM 2.0 status, hypervisor engine allocation)
@MainActor
struct VMCreateView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var ui: UIParityState
    @Environment(\.dismiss) private var dismiss

    let onCreate: (VMConfiguration) -> Void
    var onCreateAndStart: ((VMConfiguration) -> Void)? = nil

    // MARK: - Wizard Navigation State

    enum WizardStep: Int, CaseIterable, Comparable {
        case osChoice = 0
        case profile = 1
        case configuration = 2
        case review = 3

        static func < (lhs: WizardStep, rhs: WizardStep) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var title: String {
            switch self {
            case .osChoice: return "Operating System"
            case .profile: return "Primary Use"
            case .configuration: return "Mac Integration & Hardware"
            case .review: return "Review & Create"
            }
        }
    }

    @State private var currentStep: WizardStep = .osChoice

    // MARK: - Step 1: OS Selection State

    enum OSTemplate: String, CaseIterable, Identifiable {
        case windows11 = "Windows 11 (Arm)"
        case ubuntuLinux = "Ubuntu Linux"
        case fedoraLinux = "Fedora Linux"
        case debianLinux = "Debian Linux"
        case macOS = "macOS"
        case customImage = "Custom Image"

        var id: String { rawValue }

        var guestKind: GuestKind {
            switch self {
            case .windows11: return .windowsARM
            case .ubuntuLinux, .fedoraLinux, .debianLinux: return .linuxARM
            case .macOS: return .macOSGuest
            case .customImage: return .linuxARM
            }
        }

        var defaultName: String {
            switch self {
            case .windows11: return "Windows 11"
            case .ubuntuLinux: return "Ubuntu 24.04 LTS"
            case .fedoraLinux: return "Fedora 40"
            case .debianLinux: return "Debian 12"
            case .macOS: return "macOS"
            case .customImage: return "Custom Machine"
            }
        }
    }

    @State private var selectedOS: OSTemplate = .windows11
    @State private var name: String = "Windows 11"
    @State private var installMediaPath: String?

    // MARK: - Step 2: Use Profile State

    enum UsageProfile: String, CaseIterable, Identifiable {
        case productivity = "Productivity"
        case softwareDev = "Software Development"
        case performance = "Performance & Games"
        case custom = "Custom Specification"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .productivity: return "briefcase.fill"
            case .softwareDev: return "chevron.left.forwardslash.chevron.right"
            case .performance: return "gamecontroller.fill"
            case .custom: return "slider.horizontal.3"
            }
        }

        var description: String {
            switch self {
            case .productivity:
                return "Optimized for office applications, web browsing, email, and multitasking."
            case .softwareDev:
                return "Optimized for programming, code compilation, Docker containers, and database workloads."
            case .performance:
                return "Maximum allocation of CPU cores and RAM for demanding 3D graphics, simulations, and games."
            case .custom:
                return "Manually configure exact vCPU count, memory allocation, and storage capacities."
            }
        }
    }

    @State private var selectedProfile: UsageProfile = .productivity

    // MARK: - Step 3: Hardware & Sharing State

    @State private var cpuCount: Int = 4
    @State private var memoryGB: Int = 8
    @State private var diskGB: Int = 64
    @State private var network: NetworkMode = .sharedNAT
    @State private var engineChoice: String = VMConfiguration.automaticEngine

    // Mac Folder Sharing presets
    @State private var shareDesktop: Bool = true
    @State private var shareDocuments: Bool = true
    @State private var shareDownloads: Bool = true
    @State private var shareReadOnly: Bool = false
    @State private var customSharedFolders: [String] = []

    // Drag-and-drop state
    @State private var isTargetedForDrop: Bool = false

    // MARK: - Host Limits

    private var host: HostCapacity { state.registry.capacity }
    private var maxHostCPUs: Int { max(1, host.processorCount) }
    private var maxHostMemoryGB: Int {
        let usable = host.physicalMemory > AdmissionControl.minimumReserve
            ? host.physicalMemory - AdmissionControl.minimumReserve
            : AdmissionControl.gibibyte
        return max(1, Int(usable / AdmissionControl.gibibyte))
    }

    var body: some View {
        VStack(spacing: 0) {
            assistantHeader
            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    switch currentStep {
                    case .osChoice:
                        stepOSChoiceView
                    case .profile:
                        stepProfileView
                    case .configuration:
                        stepConfigurationView
                    case .review:
                        stepReviewView
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            assistantFooter
        }
        .frame(width: 760, height: 620)
        .background(Color.macportWindow)
        .onAppear {
            applyProfileDefaults()
        }
    }

    // MARK: - Header with Step Progress

    private var assistantHeader: some View {
        HStack(spacing: 14) {
            MacportAppLogoView(size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("New Virtual Machine Assistant")
                    .font(.system(size: 14, weight: .bold))
                Text(currentStep.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Step Progress Pills
            HStack(spacing: 6) {
                ForEach(WizardStep.allCases, id: \.self) { step in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(step == currentStep ? Color.macportAccent : (step < currentStep ? Color.macportRunning : Color.macportOff.opacity(0.3)))
                            .frame(width: 7, height: 7)
                        Text("\(step.rawValue + 1)")
                            .font(.system(size: 11, weight: step == currentStep ? .bold : .regular))
                            .foregroundStyle(step == currentStep ? .primary : .secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(step == currentStep ? Color.macportAccent.opacity(0.12) : Color.macportInset.opacity(0.6))
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.macportCard.opacity(0.7))
    }

    // MARK: - Step 1: OS Selection View

    private var stepOSChoiceView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What would you like to run on this Mac?")
                    .font(.title3.weight(.bold))
                Text("Select an operating system optimized for Apple Silicon virtualization.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                // Windows 11 Card
                osTile(
                    template: .windows11,
                    title: "Windows 11 on Arm",
                    badge: "Parallels Fast Install",
                    badgeColor: .blue,
                    icon: "square.grid.2x2.fill",
                    accentGradient: [Color.blue, Color.cyan],
                    description: "High-performance Windows on Apple Silicon. Auto-configured with TPM 2.0 device and VirtIO drivers."
                )

                // Ubuntu Linux Card
                osTile(
                    template: .ubuntuLinux,
                    title: "Ubuntu 24.04 LTS",
                    badge: "Fast & Lightweight",
                    badgeColor: .orange,
                    icon: "terminal.fill",
                    accentGradient: [Color.orange, Color.red],
                    description: "Modern Linux workstation with 3D graphics, VirtioFS folder sharing, and native ARM64 speed."
                )

                // macOS Card
                osTile(
                    template: .macOS,
                    title: "macOS",
                    badge: "Apple Virtualization",
                    badgeColor: .gray,
                    icon: "apple.logo",
                    accentGradient: [Color.gray, Color.secondary],
                    description: "Run macOS Sonoma, Sequoia, or newer in an isolated virtual sandbox using an IPSW restore image."
                )

                // Custom Image Card
                osTile(
                    template: .customImage,
                    title: "Install from Image File",
                    badge: "ISO / IMG / QCOW2",
                    badgeColor: .purple,
                    icon: "opticaldisc.fill",
                    accentGradient: [Color.purple, Color.indigo],
                    description: "Boot any existing Linux, Windows, or custom operating system installer ISO or raw disk image."
                )
            }

            // Distro Selection when Linux is chosen
            if selectedOS == .ubuntuLinux || selectedOS == .fedoraLinux || selectedOS == .debianLinux {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose Linux Distribution")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $selectedOS) {
                        Text("Ubuntu 24.04 LTS").tag(OSTemplate.ubuntuLinux)
                        Text("Fedora 40").tag(OSTemplate.fedoraLinux)
                        Text("Debian 12").tag(OSTemplate.debianLinux)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.macportInset))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.macportBorderSubtle, lineWidth: 1))
            }
        }
    }

    private func osTile(
        template: OSTemplate,
        title: String,
        badge: String,
        badgeColor: Color,
        icon: String,
        accentGradient: [Color],
        description: String
    ) -> some View {
        let isSelected = selectedOS == template
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedOS = template
                name = template.defaultName
                applyProfileDefaults()
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: accentGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 36, height: 36)
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Spacer()

                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(badgeColor.opacity(0.14)))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)

                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Color.macportAccent : Color.macportOff.opacity(0.4))
                }
            }
            .padding(14)
            .frame(height: 155)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.macportCard))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.macportAccent : Color.macportBorderSubtle, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? Color.macportAccent.opacity(0.15) : Color.black.opacity(0.04), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: Use Profile View (Parallels Style)

    private var stepProfileView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How will you primarily use \(selectedOS.defaultName)?")
                    .font(.title3.weight(.bold))
                Text("Macport will tune virtual CPU cores, RAM, and graphics resources for your workflow.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(UsageProfile.allCases) { profile in
                    profileTile(profile)
                }
            }
        }
    }

    private func profileTile(_ profile: UsageProfile) -> some View {
        let isSelected = selectedProfile == profile
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedProfile = profile
                applyProfileDefaults()
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.macportAccent.opacity(0.18) : Color.macportInset)
                        .frame(width: 44, height: 44)
                    Image(systemName: profile.icon)
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? Color.macportAccent : .secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(profile.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)

                        if profile == .productivity {
                            Text("RECOMMENDED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.macportAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.macportAccent.opacity(0.12)))
                        }
                    }

                    Text(profile.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.macportAccent : Color.macportOff.opacity(0.4))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.macportCard))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.macportAccent : Color.macportBorderSubtle, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? Color.macportAccent.opacity(0.12) : Color.black.opacity(0.04), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func applyProfileDefaults() {
        switch selectedProfile {
        case .productivity:
            cpuCount = min(4, maxHostCPUs)
            memoryGB = min(8, maxHostMemoryGB)
            diskGB = 64
        case .softwareDev:
            cpuCount = min(max(4, maxHostCPUs - 2), maxHostCPUs)
            memoryGB = min(max(8, maxHostMemoryGB / 2), maxHostMemoryGB)
            diskGB = 96
        case .performance:
            cpuCount = max(1, maxHostCPUs - 1)
            memoryGB = max(2, (maxHostMemoryGB * 3) / 4)
            diskGB = 128
        case .custom:
            break
        }
    }

    // MARK: - Step 3: Configuration & Mac Integration View

    private var stepConfigurationView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // General Info
            VStack(alignment: .leading, spacing: 10) {
                Text("Virtual Machine Name")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("Machine Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.macportCard))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.macportBorderSubtle, lineWidth: 1))

            // Boot Media Card
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "opticaldisc.fill")
                        .foregroundStyle(Color.macportAccent)
                    Text("Installation Media / Image")
                        .font(.headline)
                    Spacer()
                }

                bootMediaSection
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.macportCard))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.macportBorderSubtle, lineWidth: 1))

            // Hardware Specification Card
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "cpu")
                        .foregroundStyle(Color.macportAccent)
                    Text("Hardware Resources")
                        .font(.headline)
                    Spacer()
                }

                // CPUs
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Processors (vCPUs)")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(cpuCount) cores")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    Slider(
                        value: Binding(get: { Double(cpuCount) }, set: { cpuCount = Int($0) }),
                        in: 1...Double(maxHostCPUs),
                        step: 1
                    )
                    Text("Host has \(host.processorCount) physical Apple Silicon cores available.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Memory
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Memory (RAM)")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(memoryGB) GB")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    Slider(
                        value: Binding(get: { Double(memoryGB) }, set: { memoryGB = Int($0) }),
                        in: 2...Double(maxHostMemoryGB),
                        step: 1
                    )
                    Text("Host has \(MacportFormat.fileSize(host.physicalMemory)) physical memory.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Disk Size
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("NVMe Virtual Storage")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(diskGB) GB")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    Slider(
                        value: Binding(get: { Double(diskGB) }, set: { diskGB = Int($0) }),
                        in: 32...512,
                        step: 16
                    )
                    Text("Disks are created as sparse images and only consume real space as the guest writes data.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.macportCard))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.macportBorderSubtle, lineWidth: 1))

            // Mac Folder Sharing Card
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.macportAccent)
                    Text("Mac Folder Sharing (VirtioFS)")
                        .font(.headline)
                    Spacer()
                }

                Text("Access your Mac files seamlessly inside the virtual machine at native storage speeds.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Toggle("Desktop", isOn: $shareDesktop)
                    Toggle("Documents", isOn: $shareDocuments)
                    Toggle("Downloads", isOn: $shareDownloads)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

                Toggle("Mount shares as Read-Only for safety", isOn: $shareReadOnly)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.macportCard))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.macportBorderSubtle, lineWidth: 1))
        }
    }

    private var bootMediaSection: some View {
        Group {
            if let path = installMediaPath {
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(Color.macportAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(path)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Change…") { chooseMedia() }
                        .controlSize(.small)
                    Button {
                        installMediaPath = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.macportInset))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.macportAccent.opacity(0.4), lineWidth: 1))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 24))
                        .foregroundStyle(isTargetedForDrop ? Color.macportAccent : .secondary)

                    Text(selectedOS == .macOS ? "Choose an IPSW restore image or drag it here" : "Choose an ISO or disk image or drag it here")
                        .font(.system(size: 12, weight: .medium))

                    HStack(spacing: 10) {
                        Button("Choose Image…") { chooseMedia() }
                            .controlSize(.small)

                        Text("or leave empty to boot from existing drive")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.macportInset.opacity(0.6)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isTargetedForDrop ? Color.macportAccent : Color.macportBorderSubtle, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in
                        installMediaPath = url.path
                    }
                }
            }
            return true
        }
    }

    // MARK: - Step 4: Review & Honesty View

    private var stepReviewView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ready to create \(name)")
                    .font(.title3.weight(.bold))
                Text("Confirm specifications and hypervisor resources before creating.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Specs Card
            VStack(spacing: 0) {
                HStack {
                    GuestAvatar(guest: selectedOS.guestKind, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 15, weight: .bold))
                        Text("\(selectedOS.rawValue) · \(selectedProfile.rawValue)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    EngineChip(config: makeConfiguration())
                }
                .padding(16)

                Divider()

                VStack(spacing: 10) {
                    reviewRow(label: "Virtual Processors", value: "\(cpuCount) Cores")
                    reviewRow(label: "Memory (RAM)", value: "\(memoryGB) GB")
                    reviewRow(label: "Primary NVMe Storage", value: "\(diskGB) GB (Sparse)")
                    reviewRow(label: "Network Mode", value: network.displayName)

                    let folderCount = resolvedSharedFolders().count
                    reviewRow(label: "Shared Mac Folders", value: folderCount > 0 ? "\(folderCount) folder(s) (\(shareReadOnly ? "Read-Only" : "Read-Write"))" : "None")

                    if let mediaPath = installMediaPath {
                        reviewRow(label: "Boot Media", value: URL(fileURLWithPath: mediaPath).lastPathComponent)
                    }

                    if selectedOS.guestKind == .windowsARM {
                        reviewRow(label: "TPM 2.0 Security", value: "Emulated TPM 2.0 Device Active")
                        reviewRow(label: "Macport Tools", value: MacportTools.resolve() != nil ? "virtio-win.iso auto-attached" : "Optional virtio-win.iso")
                    } else if selectedOS.guestKind == .macOSGuest {
                        reviewRow(label: "Virtualization Mode", value: "Apple Virtualization Framework (Native GPU)")
                    }
                }
                .padding(16)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.macportCard))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.macportBorderSubtle, lineWidth: 1))

            // Honesty Expectations
            let warnings = capabilityWarnings
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hypervisor Notes & Host Check")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(Color.macportAccent)
                                .font(.system(size: 12))
                            Text(warning)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.macportInset))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.macportBorderSubtle, lineWidth: 1))
            }
        }
    }

    private func reviewRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    // MARK: - Footer Navigation Actions

    private var assistantFooter: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if currentStep > .osChoice {
                Button("◀ Back") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if let prev = WizardStep(rawValue: currentStep.rawValue - 1) {
                            currentStep = prev
                        }
                    }
                }
            }

            if currentStep < .review {
                Button("Continue ▶") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if let next = WizardStep(rawValue: currentStep.rawValue + 1) {
                            currentStep = next
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                HStack(spacing: 8) {
                    Button("Create Machine") {
                        let config = makeConfiguration()
                        onCreate(config)
                        dismiss()
                    }
                    .controlSize(.regular)

                    Button("Create & Start") {
                        let config = makeConfiguration()
                        if let onCreateAndStart = onCreateAndStart {
                            onCreateAndStart(config)
                        } else {
                            onCreate(config)
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                state.start(config, in: store)
                            }
                        }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.macportCard.opacity(0.7))
    }

    // MARK: - Helpers

    private func resolvedSharedFolders() -> [SharedFolder] {
        var folders: [SharedFolder] = []
        if shareDesktop, let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            folders.append(SharedFolder(hostPath: url.path, readOnly: shareReadOnly))
        }
        if shareDocuments, let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            folders.append(SharedFolder(hostPath: url.path, readOnly: shareReadOnly))
        }
        if shareDownloads, let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            folders.append(SharedFolder(hostPath: url.path, readOnly: shareReadOnly))
        }
        for custom in customSharedFolders {
            if !folders.contains(where: { $0.hostPath == custom }) {
                folders.append(SharedFolder(hostPath: custom, readOnly: shareReadOnly))
            }
        }
        return folders
    }

    private func makeConfiguration() -> VMConfiguration {
        let guestKind: GuestKind = selectedOS.guestKind
        let boot: BootSource = installMediaPath != nil ? .installMedia(path: installMediaPath!) : .diskOnly
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? selectedOS.defaultName : name
        return VMConfiguration(
            name: finalName,
            guest: guestKind,
            cpuCount: cpuCount,
            memoryBytes: UInt64(memoryGB) * 1024 * 1024 * 1024,
            diskBytes: UInt64(diskGB) * 1024 * 1024 * 1024,
            network: network,
            sharedFolders: resolvedSharedFolders(),
            boot: boot,
            tpmEnabled: guestKind.requiresTPM,
            engineIdentifier: engineChoice == VMConfiguration.automaticEngine ? nil : engineChoice,
            wineSettings: nil
        )
    }

    private var capabilityWarnings: [String] {
        let config = makeConfiguration()
        return state.warnings(for: config)
    }

    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = selectedOS == .macOS ? "Choose an IPSW restore image" : "Choose an ISO or disk image to boot"
        if panel.runModal() == .OK {
            installMediaPath = panel.url?.path
        }
    }
}
