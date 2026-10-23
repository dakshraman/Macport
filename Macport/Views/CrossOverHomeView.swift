import AppKit
import SwiftUI
import MacportKit

/// The CrossOver-style "Home" surface: unified application launcher shelf
/// showing all games and Windows software installed across all bottles.
@MainActor
struct CrossOverHomeView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState

    @State private var appItems: [HomeAppItem] = []
    @State private var hoveredItemId: String?
    @State private var statusMessage: String?
    @State private var searchText = ""
    @State private var selectedBottleFilter: String? = nil
    @State private var targetToUninstall: HomeAppItem?
    @State private var isConfirmingUninstall = false

    struct HomeAppItem: Identifiable, Hashable {
        let id: String
        let name: String
        let bottleName: String
        let bottleId: UUID
        let executable: String
        let iconURL: URL?
        let iconSystemName: String
    }

    private var bottleNames: [String] {
        Array(Set(appItems.map { $0.bottleName })).sorted()
    }

    private var filteredApps: [HomeAppItem] {
        var list = appItems
        if let filter = selectedBottleFilter, !filter.isEmpty {
            list = list.filter { $0.bottleName == filter }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(query) ||
                $0.bottleName.lowercased().contains(query)
            }
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: "Home" + Search & Filter
            headerSection
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 16)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let msg = statusMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(Color.crossoverBlue)
                            Text(msg)
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                            Spacer()
                            Button(action: { statusMessage = nil }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.crossoverCard))
                    }

                    if appItems.isEmpty {
                        emptyHomeView
                    } else if filteredApps.isEmpty {
                        noMatchingResultsView
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 110, maximum: 130), spacing: 28)],
                            alignment: .leading,
                            spacing: 28
                        ) {
                            ForEach(filteredApps) { item in
                                homeAppTile(item)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .background(Color.crossoverCanvas)
        .confirmationDialog(
            "Uninstall \(targetToUninstall?.name ?? "Application")?",
            isPresented: $isConfirmingUninstall,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                if let item = targetToUninstall {
                    performUninstallHomeItem(item)
                }
            }
            Button("Cancel", role: .cancel) {
                targetToUninstall = nil
            }
        } message: {
            Text("This will launch the application's uninstaller in '\(targetToUninstall?.bottleName ?? "bottle")' and clean up its Mac launcher wrappers in Applications and Desktop.")
        }
        .onAppear {
            refreshAllApps()
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Home")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                // Live Search Field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.5))

                    TextField("Search apps & games…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(white: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(white: 0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .frame(width: 220)
            }

            // Bottle Filter Chips (when multiple bottles exist)
            if bottleNames.count > 1 {
                HStack(spacing: 8) {
                    filterChip(title: "All (\(appItems.count))", isSelected: selectedBottleFilter == nil) {
                        selectedBottleFilter = nil
                    }

                    ForEach(bottleNames, id: \.self) { bName in
                        let count = appItems.filter { $0.bottleName == bName }.count
                        filterChip(title: "\(bName) (\(count))", isSelected: selectedBottleFilter == bName) {
                            selectedBottleFilter = bName
                        }
                    }
                }
            }

            Divider()
                .background(Color.white.opacity(0.08))
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : Color(white: 0.65))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.crossoverBlue : Color(white: 0.22))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - App Tile

    private func homeAppTile(_ item: HomeAppItem) -> some View {
        let isHovered = (hoveredItemId == item.id)

        return VStack(spacing: 8) {
            ZStack {
                // Application Icon Container (CrossOver squircle)
                if let iconURL = item.iconURL, let img = NSImage(contentsOf: iconURL) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(isHovered ? 0.5 : 0.25), radius: isHovered ? 10 : 4, y: isHovered ? 5 : 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(isHovered ? Color.crossoverBlue.opacity(0.6) : Color.white.opacity(0.12), lineWidth: isHovered ? 1.5 : 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.crossoverCard, Color.crossoverSidebar],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 72, height: 72)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(isHovered ? Color.crossoverBlue.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 8 : 4, y: 3)
                        .overlay(
                            Image(systemName: item.iconSystemName)
                                .font(.system(size: 30))
                                .foregroundStyle(Color.crossoverBlue)
                        )
                }

                // Hover Play Button Overlay
                if isHovered {
                    Circle()
                        .fill(Color.crossoverBlue)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: 1)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 76, height: 76)
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)

            // Titles
            VStack(spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHovered ? Color.crossoverBlue : .white)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)

                Text(item.bottleName)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 110)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? Color(white: 0.22) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredItemId = hovering ? item.id : nil
            }
        }
        .onTapGesture(count: 2) {
            launchItem(item)
        }
        .contextMenu {
            Button {
                launchItem(item)
            } label: {
                Label("Launch in \(item.bottleName)", systemImage: "play.fill")
            }

            Button {
                ui.selection = item.bottleId
            } label: {
                Label("Go to Bottle", systemImage: "shippingbox.fill")
            }

            Divider()

            Button {
                NSWorkspace.shared.selectFile(item.executable, inFileViewerRootedAtPath: "")
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Divider()

            Button {
                exportHomeApp(item, to: .applications)
            } label: {
                Label("Add to Applications", systemImage: "app.badge.checkmark")
            }

            Button {
                exportHomeApp(item, to: .desktop)
            } label: {
                Label("Add to Desktop", systemImage: "desktopcomputer")
            }

            Button {
                if let config = store.machines.first(where: { $0.id == item.bottleId }) {
                    let driveC = WineBottleManager.driveCURL(for: store.bundleURL(for: config))
                    NSWorkspace.shared.open(driveC)
                }
            } label: {
                Label("Open Bottle C: Drive", systemImage: "internaldrive")
            }

            Divider()

            Button(role: .destructive) {
                targetToUninstall = item
                isConfirmingUninstall = true
            } label: {
                Label("Uninstall Application…", systemImage: "trash")
            }
        }
    }

    // MARK: - Empty State

    private var emptyHomeView: some View {
        VStack(spacing: 20) {
            MacportAppLogoView(size: 72)

            VStack(spacing: 6) {
                Text("Welcome to Macport Pro")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Text("Run your favorite Windows applications and games with native Apple Metal performance.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            HStack(spacing: 12) {
                Button {
                    state.isPresentingCreateSheet = true
                } label: {
                    Label("Install a Windows Application", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.crossoverBlue))
                }
                .buttonStyle(.plain)

                Button {
                    ui.isPresentingImport = true
                } label: {
                    Label("Import CrossOver Bottle", systemImage: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.22)))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private var noMatchingResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(Color(white: 0.4))
            Text("No applications found matching '\(searchText)'")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Button("Clear Search") {
                searchText = ""
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Operations

    private func refreshAllApps() {
        Task {
            var items: [HomeAppItem] = []
            var seen = Set<String>()

            for config in store.machines where config.guest == .windowsApp {
                let bundleURL = store.bundleURL(for: config)
                let shortcuts = WineBottleManager.scanInstalledShortcuts(in: bundleURL)
                for sc in shortcuts {
                    let key = "\(config.id.uuidString)-\(sc.executable)"
                    if !seen.contains(key) {
                        seen.insert(key)
                        items.append(HomeAppItem(
                            id: key,
                            name: sc.name,
                            bottleName: config.name,
                            bottleId: config.id,
                            executable: sc.executable,
                            iconURL: sc.iconURL,
                            iconSystemName: sc.iconSystemName
                        ))
                    }
                }
            }

            await MainActor.run {
                self.appItems = items
            }
        }
    }

    private func launchItem(_ item: HomeAppItem) {
        guard let config = store.machines.first(where: { $0.id == item.bottleId }) else { return }
        let bundleURL = store.bundleURL(for: config)

        Task {
            do {
                if let wineEngine = state.instance(for: config.id)?.engine as? WineEngine {
                    try await wineEngine.launchExecutable(item.executable, in: bundleURL, metal: true)
                } else {
                    let engine = WineEngine()
                    try await engine.launchExecutable(item.executable, in: bundleURL, metal: true)
                }
                statusMessage = "Launched \(item.name) in bottle '\(item.bottleName)'."
            } catch {
                statusMessage = "Failed to launch: \(error.localizedDescription)"
            }
        }
    }

    private func exportHomeApp(_ item: HomeAppItem, to destination: MacportAppPublisher.Destination) {
        do {
            let appURL = try MacportAppPublisher.exportLauncherApp(
                bottleId: item.bottleId,
                bottleName: item.bottleName,
                appName: item.name,
                executable: item.executable,
                iconURL: item.iconURL,
                to: destination
            )
            statusMessage = "Added '\(item.name)' to \(destination.displayName). Launch directly from Spotlight or Launchpad!"
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } catch {
            statusMessage = "Failed to export application: \(error.localizedDescription)"
        }
    }

    private func performUninstallHomeItem(_ item: HomeAppItem) {
        guard let config = store.machines.first(where: { $0.id == item.bottleId }) else { return }
        let bundleURL = store.bundleURL(for: config)
        let shortcut = WineProgramShortcut(
            id: item.id,
            name: item.name,
            executable: item.executable,
            iconSystemName: item.iconSystemName,
            iconURL: item.iconURL
        )

        Task {
            do {
                let cmd = WineBottleManager.findUninstallCommand(for: shortcut, in: bundleURL)
                let engine = (state.instance(for: config.id)?.engine as? WineEngine) ?? WineEngine()
                try await engine.launchExecutable(cmd.executable, arguments: cmd.arguments, in: bundleURL, metal: true)

                WineBottleManager.removeLauncherApps(appName: item.name)

                statusMessage = "Launched uninstaller for '\(item.name)'. Follow on-screen instructions to complete uninstallation."

                try? await Task.sleep(nanoseconds: 1_500_000_000)
                refreshAllApps()
            } catch {
                statusMessage = "Failed to launch uninstaller: \(error.localizedDescription)"
            }
        }
    }
}
