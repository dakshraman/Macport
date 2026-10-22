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

    struct HomeAppItem: Identifiable, Hashable {
        let id: String
        let name: String
        let bottleName: String
        let bottleId: UUID
        let executable: String
        let iconURL: URL?
        let iconSystemName: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: "Home"
            VStack(alignment: .leading, spacing: 14) {
                Text("Home")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)

                Divider()
                    .background(Color.white.opacity(0.08))
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 20)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let msg = statusMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(Color.crossoverBlue)
                            Text(msg)
                                .font(.system(size: 12))
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
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 110, maximum: 130), spacing: 28)],
                            alignment: .leading,
                            spacing: 28
                        ) {
                            ForEach(appItems) { item in
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
        .onAppear {
            refreshAllApps()
        }
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
                        .shadow(color: .black.opacity(isHovered ? 0.45 : 0.25), radius: isHovered ? 8 : 4, y: isHovered ? 4 : 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
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
                                .stroke(Color.white.opacity(isHovered ? 0.3 : 0.1), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(isHovered ? 0.35 : 0.2), radius: isHovered ? 8 : 4, y: 3)
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

            // Titles
            VStack(spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHovered ? Color.crossoverBlue : .white)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)

                Text(item.bottleName)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 110)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? Color.crossoverCard.opacity(0.6) : Color.clear)
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
                Label("Go to Bottle", systemImage: "shippingbox")
            }

            Divider()

            Button {
                NSWorkspace.shared.selectFile(item.executable, inFileViewerRootedAtPath: "")
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
    }

    // MARK: - Empty State

    private var emptyHomeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.crossoverBlue.opacity(0.6))

            VStack(spacing: 6) {
                Text("No Installed Applications")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Install a Windows application, game, or launcher to see it here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button {
                state.isPresentingCreateSheet = true
            } label: {
                Label("Install a Windows Application", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.crossoverBlue)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
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
}
