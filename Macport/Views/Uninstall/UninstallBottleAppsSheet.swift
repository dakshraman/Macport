import AppKit
import SwiftUI
import MacportKit

/// Sheet listing applications installed in a Wine bottle with direct 1-click uninstallation.
@MainActor
struct UninstallBottleAppsSheet: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let config: VMConfiguration

    @State private var installedApps: [WineInstalledApp] = []
    @State private var searchQuery: String = ""
    @State private var targetToUninstall: WineInstalledApp?
    @State private var isConfirmingUninstall = false
    @State private var removeMacWrappers = true
    @State private var statusMessage: String?
    @State private var isLoading = true

    private var bundleURL: URL { store.bundleURL(for: config) }

    private var filteredApps: [WineInstalledApp] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return installedApps }
        return installedApps.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.key.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.crossoverDangerBg)
                        .frame(width: 40, height: 40)
                    Image(systemName: "xmark.bin.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.crossoverDangerText)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall Applications")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Bottle: \(config.name)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.crossoverTextSecondary)
                }

                Spacer()

                // Search field
                if installedApps.count > 3 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.5))

                        TextField("Filter apps…", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.white)

                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(white: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.2)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .frame(width: 170)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Color.crossoverBorder)

            // Status message banner
            if let msg = statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.crossoverBlue)
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                    Spacer()
                    Button { statusMessage = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.crossoverCard)
            }

            // App List
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning bottle for installed applications…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.crossoverTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredApps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundStyle(Color(white: 0.35))
                    Text(installedApps.isEmpty ? "No removable applications detected" : "No applications matching '\(searchQuery)'")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Text("You can still open Windows Add/Remove Programs below to manage system components.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.crossoverTextSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredApps) { app in
                            appRow(app)
                        }
                    }
                    .padding(16)
                }
            }

            Divider().background(Color.crossoverBorder)

            // Bottom Actions Bar
            HStack {
                Button {
                    launchAddRemovePrograms()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11))
                        Text("Open Windows Add/Remove Programs…")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.crossoverBlue)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 420)
        .background(Color.crossoverInspector)
        .onAppear {
            refreshApps()
        }
        .confirmationDialog(
            "Uninstall \(targetToUninstall?.displayName ?? "Application")?",
            isPresented: $isConfirmingUninstall,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                if let app = targetToUninstall {
                    performUninstall(app)
                }
            }
            Button("Cancel", role: .cancel) {
                targetToUninstall = nil
            }
        } message: {
            Text("This will launch the application's Windows uninstaller in '\(config.name)' to remove its program files. Also clean up any exported Mac application wrappers in Applications and Desktop.")
        }
    }

    private func appRow(_ app: WineInstalledApp) -> some View {
        HStack(spacing: 12) {
            // Icon
            if let iconURL = app.iconURL, let img = NSImage(contentsOf: iconURL) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(white: 0.22))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: app.isSystemTool ? "gearshape.fill" : "app.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.crossoverBlue)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)

                    if app.isSystemTool {
                        Text("SYSTEM")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(white: 0.6))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                }

                if let loc = app.installLocation, !loc.isEmpty {
                    Text(loc)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Button {
                targetToUninstall = app
                isConfirmingUninstall = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                    Text("Uninstall")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.crossoverDangerText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.crossoverDangerBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.crossoverDangerText.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.crossoverCard)
        )
    }

    private func refreshApps() {
        isLoading = true
        Task {
            let apps = WineBottleManager.scanInstalledApplications(in: bundleURL)
            await MainActor.run {
                self.installedApps = apps
                self.isLoading = false
            }
        }
    }

    private func performUninstall(_ app: WineInstalledApp) {
        Task {
            do {
                let parsed: (executable: String, arguments: [String])
                if let uninstStr = app.uninstallString, !uninstStr.isEmpty {
                    parsed = WineBottleManager.parseCommandAndArguments(uninstStr)
                } else {
                    parsed = ("uninstaller.exe", [])
                }

                let engine = (state.instance(for: config.id)?.engine as? WineEngine) ?? WineEngine()
                try await engine.launchExecutable(parsed.executable, arguments: parsed.arguments, in: bundleURL, metal: true)

                // Clean up any exported Mac wrapper apps
                WineBottleManager.removeLauncherApps(appName: app.displayName)

                statusMessage = "Launched uninstaller for '\(app.displayName)'. Follow on-screen instructions to complete uninstallation."

                // Refresh after a brief delay
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                refreshApps()
            } catch {
                statusMessage = "Failed to launch uninstaller: \(error.localizedDescription)"
            }
        }
    }

    private func launchAddRemovePrograms() {
        Task {
            do {
                let engine = (state.instance(for: config.id)?.engine as? WineEngine) ?? WineEngine()
                try await engine.launchExecutable("uninstaller.exe", arguments: [], in: bundleURL, metal: true)
                statusMessage = "Opened Windows Add/Remove Programs panel."
            } catch {
                statusMessage = "Failed to open Add/Remove Programs: \(error.localizedDescription)"
            }
        }
    }
}
