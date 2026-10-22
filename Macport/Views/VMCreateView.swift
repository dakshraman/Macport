import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacportKit

/// The signature Parallels Desktop style Installation Assistant.
///
/// Provides a guided 4-step wizard:
/// 1. Operating System Selection (Windows 11 on Arm, Linux distros, macOS, Custom Image)
/// 2. Primary Use Profile (Productivity, Software Development, Gaming & High Performance, Custom)
/// 3. Configuration & Mac Integration (One-click Desktop/Documents/Downloads folder sharing, media picker, hardware tuning)
/// 4. Review & Honesty Check (Hardware breakdown, Virtio drivers, TPM 2.0 answer file, engine allocation)
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
        case windowsApp = "Windows App (.exe)"
        case windows11 = "Windows 11 (Arm)"
        case ubuntuLinux = "Ubuntu Linux"
        case fedoraLinux = "Fedora Linux"
        case debianLinux = "Debian Linux"
        case macOS = "macOS"
        case customImage = "Custom Image"

        var id: String { rawValue }

        var guestKind: GuestKind {
            switch self {
            case .windowsApp: return .windowsApp
            case .windows11: return .windowsARM
            case .ubuntuLinux, .fedoraLinux, .debianLinux: return .linuxARM
            case .macOS: return .macOSGuest
            case .customImage: return .linuxARM
            }
        }

        var defaultName: String {
            switch self {
            case .windowsApp: return "Windows App"
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

        var subtitle: String {
            switch self {
            case .productivity:
                return "Optimized for Microsoft Office, Safari/Chrome, email, and everyday apps."
            case .softwareDev:
                return "Tuned for Visual Studio, Docker, Xcode, compilers, and high I/O throughput."
            case .performance:
                return "Maximum processor cores, memory allocation, and accelerated graphics."
            case .custom:
                return "Manually configure virtual processors, memory limits, and engine pinning."
            }
        }
    }

    @State private var selectedProfile: UsageProfile = .productivity

    // MARK: - Wine / CrossOver Bottle State

    @State private var selectedBottleTemplate: String = "win11_64"
    @State private var selectedCrossOverBottle: String = ""
    @State private var isLinkingExistingBottle: Bool = false
    @State private var selectedGraphicsBackend: GraphicsBackend = .auto
    @State private var msyncEnabled: Bool = true
    @State private var metalFXEnabled: Bool = true
    @State private var hudEnabled: Bool = false
    @State private var existingCrossOverBottles: [(name: String, url: URL)] = []

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
            existingCrossOverBottles = WineRuntime.existingCrossOverBottles()
        }
    }

    // MARK: - Header & Step Indicator

    private var assistantHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.macportAccent.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "plus.square.dashed")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.macportAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Installation Assistant")
                    .font(.system(size: 16, weight: .bold))
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
                // Windows App (.exe) Card
                osTile(
                    template: .windowsApp,
                    title: "Windows App (.exe)",
                    badge: "Zero Overhead",
                    badgeColor: .cyan,
                    icon: "macwindow",
                    accentGradient: [Color.cyan, Color.blue],
                    description: "Run Windows software, games, and installers directly on macOS at native speed without VM memory overhead."
                )

                // Windows 11 Card
                osTile(
                    template: .windows11,
                    title: "Windows 11 on Arm",
                    badge: "Full Virtual Machine",
                    badgeColor: .blue,
                    icon: "square.grid.2x2.fill",
                    accentGradient: [Color.blue, Color.cyan],
                    description: "High-performance Windows on Apple Silicon. Auto-configured with TPM 2.0 bypass and Virtio drivers."
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
                    description: "Run macOS Sonoma or Sequoia in an isolated virtual sandbox using an IPSW restore image."
                )

                // Custom Image Card
                osTile(
                    template: .customImage,
                    title: "Install from Image File",
                    badge: "ISO / IMG",
                    badgeColor: .purple,
                    icon: "opticaldisc.fill",
                    accentGradient: [Color.purple, Color.indigo],
                    description: "Boot any existing Linux, Windows, or custom operating system installer ISO or raw disk image."
                )
            }

            if selectedOS == .windowsApp {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(Color.macportAccent)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wine Translation Engine (Direct Execution)")
                            .font(.system(size: 12, weight: .semibold))
                        switch WineRuntime.resolve() {
                        case .success(let loc):
                            Text("Ready: \(loc.hasMetalAcceleration ? "Apple Metal GPU acceleration & Rosetta 2 active." : "Rosetta 2 translation active.") Runs directly on macOS as native processes.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        case .failure(let err):
                            Text(err.localizedDescription)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.macportPaused)
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.macportInset))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.macportBorderSubtle, lineWidth: 1))
            } else if selectedOS == .windows11 {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.macportRunning)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Macport Tools (Windows Virtio Drivers)")
                            .font(.system(size: 12, weight: .semibold))
                        if MacportTools.resolve() != nil {
                            Text("virtio-win.iso is staged in Macport Runtime. Network and display drivers will be automatically installed.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("virtio-win.iso will be attached once placed in the Runtime Tools directory.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.macportPaused)
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.macportInset))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.macportBorderSubtle, lineWidth: 1))
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
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedOS = template
                name = template.defaultName
                applyProfileDefaults()
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: accentGradient, startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.2))
                            .frame(width: 44, height: 44)
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(accentGradient.first ?? .blue)
                    }

                    Spacer()

                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(badgeColor.opacity(0.12)))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)

                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.macportCard))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.macportAccent : Color.macportBorderSubtle, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? Color.macportAccent.opacity(0.15) : Color.clear, radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: Primary Use Profile View

    private var stepProfileView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How will you primarily use this machine?")
                    .font(.title3.weight(.bold))
                Text("Macport automatically tailors processor count, memory allocation, and folder sharing for optimal performance.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(UsageProfile.allCases) { profile in
                    profileRow(profile: profile)
                }
            }
        }
    }

    private func profileRow(profile: UsageProfile) -> some View {
        let isSelected = selectedProfile == profile

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedProfile = profile
                applyProfileDefaults()
            }
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.macportAccent : Color.macportInset)
                        .frame(width: 42, height: 42)
                    Image(systemName: profile.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .primary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(profile.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.macportAccent : Color.macportOff.opacity(0.4))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.macportCard))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.macportAccent : Color.macportBorderSubtle, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 3: Configuration & Mac Integration View

    private var stepConfigurationView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // General Info
            VStack(alignment: .leading, spacing: 8) {
                Text("Virtual Machine Identity")
                    .font(.headline)

                TextField("Machine Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            }

            // Install Media Picker / Drop Zone
            VStack(alignment: .leading, spacing: 8) {
                Text("Installation Media")
                    .font(.headline)

                installMediaDropZone
            }

            // Mac Folder Sharing Integration (Parallels Style)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "folder.badge.gearshape")
                        .foregroundStyle(Color.macportAccent)
                    Text("Mac Folder Sharing")
                        .font(.headline)
                    Spacer()
                    Toggle("Allow Guest to Write (Read-Write)", isOn: Binding(
                        get: { !shareReadOnly },
                        set: { shareReadOnly = !$0 }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                Text("Seamlessly access your Mac folders inside the virtual machine.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        folderPresetCheckbox(title: "Desktop", path: "~/Desktop", isOn: $shareDesktop)
                        folderPresetCheckbox(title: "Documents", path: "~/Documents", isOn: $shareDocuments)
                        folderPresetCheckbox(title: "Downloads", path: "~/Downloads", isOn: $shareDownloads)
                    }

                    if !customSharedFolders.isEmpty {
                        ForEach(customSharedFolders, id: \.self) { folder in
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Color.macportAccent)
                                Text(folder)
                                    .font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Button {
                                    customSharedFolders.removeAll { $0 == folder }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.macportInset))
                        }
                    }

                    Button("+ Add Custom Mac Folder…") {
                        chooseCustomFolder()
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.macportInset))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.macportBorderSubtle, lineWidth: 1))
            }

            if selectedOS == .windowsApp {
                // CrossOver Bottle Architecture & Gaming Settings
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "gamecontroller.fill")
                            .foregroundStyle(Color.macportAccent)
                        Text("CrossOver Bottle Architecture & Gaming Settings")
                            .font(.headline)
                    }

                    if !existingCrossOverBottles.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bottle Origin")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Picker("", selection: $isLinkingExistingBottle) {
                                Text("Create New Clean Bottle").tag(false)
                                Text("Link Existing CrossOver Bottle").tag(true)
                            }
                            .pickerStyle(.segmented)

                            if isLinkingExistingBottle {
                                Picker("Select CrossOver Bottle", selection: $selectedCrossOverBottle) {
                                    Text("Choose a Bottle…").tag("")
                                    ForEach(existingCrossOverBottles, id: \.name) { b in
                                        Text(b.name).tag(b.name)
                                    }
                                }
                                .onChange(of: selectedCrossOverBottle) { _, newBottle in
                                    if !newBottle.isEmpty {
                                        name = newBottle
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.macportInset))
                    }

                    if !isLinkingExistingBottle {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Windows Bottle Template")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Picker("", selection: $selectedBottleTemplate) {
                                Text("Windows 11 64-bit (win11_64) — Recommended for D3DMetal / GPTK").tag("win11_64")
                                Text("Windows 10 64-bit (win10_64)").tag("win10_64")
                                Text("Windows 7 64-bit (win7_64)").tag("win7_64")
                            }
                            .pickerStyle(.menu)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.macportInset))
                    }

                    // Graphics Backend & Synchronization
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Graphics Backend")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Picker("", selection: $selectedGraphicsBackend) {
                                ForEach(GraphicsBackend.allCases) { b in
                                    Text(b.displayName).tag(b)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        Divider()

                        Toggle("MSync (High-Performance Mutex Synchronization)", isOn: $msyncEnabled)
                            .font(.system(size: 12))

                        Toggle("Apple MetalFX Temporal / Spatial Upscaling", isOn: $metalFXEnabled)
                            .font(.system(size: 12))

                        Toggle("Metal Performance HUD (FPS / Frame-Time Counter)", isOn: $hudEnabled)
                            .font(.system(size: 12))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.macportInset))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.macportBorderSubtle, lineWidth: 1))
                }
            } else {
                // Fine-tuning Hardware
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hardware Allocation")
                        .font(.headline)

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Processors")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Stepper("\(cpuCount) vCPUs", value: $cpuCount, in: 1...maxHostCPUs)
                                .font(.system(size: 12, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Memory (RAM)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Stepper("\(memoryGB) GB", value: $memoryGB, in: 2...maxHostMemoryGB)
                                .font(.system(size: 12, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Storage (NVMe)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Stepper("\(diskGB) GB", value: $diskGB, in: 16...1024, step: 16)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.macportInset))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.macportBorderSubtle, lineWidth: 1))
                }
            }
        }
    }

    private func folderPresetCheckbox(title: String, path: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn.wrappedValue ? Color.macportAccent : Color.macportOff.opacity(0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(path)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.macportCard))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isOn.wrappedValue ? Color.macportAccent.opacity(0.5) : Color.macportBorderSubtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var installMediaDropZone: some View {
        VStack(spacing: 10) {
            if let mediaPath = installMediaPath {
                HStack(spacing: 12) {
                    Image(systemName: "opticaldisc.fill")
                        .font(.title2)
                        .foregroundStyle(Color.macportAccent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: mediaPath).lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(mediaPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button("Change…") { chooseMedia() }
                        .controlSize(.small)

                    Button {
                        installMediaPath = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
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

                    Text(selectedOS == .macOS ? "Choose an IPSW restore image or drag it here" : (selectedOS == .windowsApp ? "Choose a Windows executable (.exe, .msi) or drag it here" : "Choose an ISO or disk image or drag it here"))
                        .font(.system(size: 12, weight: .medium))

                    HStack(spacing: 10) {
                        Button(selectedOS == .windowsApp ? "Choose Executable…" : "Choose Image…") { chooseMedia() }
                            .controlSize(.small)

                        Text(selectedOS == .windowsApp ? "or leave empty to open Windows Desktop" : "or leave empty to boot existing drive")
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
                        if selectedOS == .windowsApp, (name == "Windows App" || name.isEmpty) {
                            name = url.deletingPathExtension().lastPathComponent
                        }
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
                Text("Ready to Create Virtual Machine")
                    .font(.title3.weight(.bold))
                Text("Confirm specifications and host integration.")
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
                    reviewRow(label: "Primary NVMe Storage", value: "\(diskGB) GB (Sparse Ceil)")
                    reviewRow(label: "Network Mode", value: network.displayName)

                    let folderCount = resolvedSharedFolders().count
                    reviewRow(label: "Shared Mac Folders", value: folderCount > 0 ? "\(folderCount) folder(s) (\(shareReadOnly ? "Read-Only" : "Read-Write"))" : "None")

                    if let mediaPath = installMediaPath {
                        reviewRow(label: "Install Media", value: URL(fileURLWithPath: mediaPath).lastPathComponent)
                    }

                    if selectedOS.guestKind == .windowsApp {
                        reviewRow(label: "Execution Engine", value: "Wine Translation Layer (Metal / Rosetta 2)")
                        reviewRow(label: "Target Executable", value: installMediaPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Windows Explorer (explorer.exe)")
                        reviewRow(label: "Memory Overhead", value: "0 MB (Dynamic Host Processes)")
                    } else if selectedOS.guestKind == .windowsARM {
                        reviewRow(label: "Macport Tools", value: MacportTools.resolve() != nil ? "virtio-win.iso auto-attached" : "Missing virtio-win.iso")
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
                    Text("What to expect")
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
                    .keyboardShortcut(.defaultAction)
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.macportCard.opacity(0.8))
    }

    // MARK: - Logic & Defaults

    private func applyProfileDefaults() {
        let hostCores = maxHostCPUs
        let hostRAM = maxHostMemoryGB

        if selectedOS == .windowsApp {
            cpuCount = min(4, hostCores)
            memoryGB = 4
            diskGB = 32
            shareDesktop = true
            shareDocuments = true
            shareDownloads = true
            return
        }

        // On an 8 GB host (usable = 6 GB), calibrate defaults so machines fit host admission limits
        let defaultMem: Int
        if hostRAM <= 6 {
            defaultMem = selectedOS.guestKind == .windowsARM ? 4 : 2
        } else {
            defaultMem = min(8, hostRAM - 2)
        }

        switch selectedProfile {
        case .productivity:
            cpuCount = min(4, hostCores)
            memoryGB = defaultMem
            diskGB = 64
            shareDesktop = true
            shareDocuments = true
            shareDownloads = true
        case .softwareDev:
            cpuCount = max(2, min(hostCores - 1, 8))
            memoryGB = min(max(defaultMem, 4), hostRAM > 4 ? hostRAM - 2 : hostRAM)
            diskGB = 128
            shareDesktop = true
            shareDocuments = true
            shareDownloads = true
        case .performance:
            cpuCount = max(2, hostCores - 1)
            memoryGB = min(max(defaultMem + 1, 4), hostRAM)
            diskGB = 128
            shareDesktop = true
            shareDocuments = true
            shareDownloads = true
        case .custom:
            break
        }
    }

    private func resolvedSharedFolders() -> [SharedFolder] {
        var folders: [SharedFolder] = []
        let fm = FileManager.default

        if shareDesktop, let url = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            folders.append(SharedFolder(hostPath: url.path, readOnly: shareReadOnly))
        }
        if shareDocuments, let url = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            folders.append(SharedFolder(hostPath: url.path, readOnly: shareReadOnly))
        }
        if shareDownloads, let url = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
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
        let boot: BootSource = installMediaPath.map { .installMedia(path: $0) } ?? .diskOnly
        var wineSettings: WineBottleSettings? = nil
        if selectedOS.guestKind == .windowsApp {
            wineSettings = WineBottleSettings(
                backend: selectedGraphicsBackend,
                msyncEnabled: msyncEnabled,
                metalFXEnabled: metalFXEnabled,
                hudEnabled: hudEnabled,
                bottleTemplate: selectedBottleTemplate,
                linkedCrossOverBottle: isLinkingExistingBottle && !selectedCrossOverBottle.isEmpty ? selectedCrossOverBottle : nil
            )
        }
        return VMConfiguration(
            name: name,
            guest: selectedOS.guestKind,
            cpuCount: cpuCount,
            memoryBytes: UInt64(memoryGB) * 1024 * 1024 * 1024,
            diskBytes: UInt64(diskGB) * 1024 * 1024 * 1024,
            network: network,
            sharedFolders: resolvedSharedFolders(),
            boot: boot,
            tpmEnabled: selectedOS.guestKind.requiresTPM,
            engineIdentifier: engineChoice == VMConfiguration.automaticEngine ? nil : engineChoice,
            wineSettings: wineSettings
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
        panel.message = selectedOS == .windowsApp
            ? "Choose a Windows executable (.exe, .msi, or installer) to run"
            : (selectedOS == .macOS ? "Choose an IPSW restore image" : "Choose an ISO or disk image to boot")
        if panel.runModal() == .OK {
            installMediaPath = panel.url?.path
            if selectedOS == .windowsApp, let filename = panel.url?.deletingPathExtension().lastPathComponent, name == "Windows App" || name.isEmpty {
                name = filename
            }
        }
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Mac folder to share with the virtual machine"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            if !customSharedFolders.contains(path) {
                customSharedFolders.append(path)
            }
        }
    }
}
