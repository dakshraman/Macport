import AppKit
import SwiftUI
import Virtualization
import MacportKit

/// Dedicated Standalone Virtual Machine Window: matches Parallels Desktop's
/// signature single-VM window architecture.
///
/// Pure edge-to-edge guest console display without any in-window toolbars or bars,
/// allowing true distraction-free fullscreen and native window presentation.
/// All controls are accessible via macOS Menu Bar commands and right-click context menu.
@MainActor
struct DedicatedVMWindowView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ui: UIParityState
    @Environment(\.dismiss) private var dismiss

    let config: VMConfiguration

    @State private var scalingMode: DisplayScalingMode = .fill
    @State private var isPresentingSettings = false
    @State private var isPresentingSnapshots = false

    private var vmState: VMState { state.state(for: config.id) }
    private var engineType: any VMEngine.Type { state.hostingEngine(for: config) }
    private var capabilities: EngineCapabilities { state.capabilities(for: config) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if vmState.isActive, let machine = state.liveMachine(for: config.id) {
                VMDisplayView(machine: machine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vmState.isActive, let vncPath = state.vncSocketPath(for: config.id) {
                EmbeddedVNCDisplayView(
                    socketPath: vncPath,
                    externalScalingMode: $scalingMode,
                    showOverlayBar: false
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                stoppedStatePlaceholder
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(Color.black)
        .background(
            WindowAccessor { window in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if !window.styleMask.contains(.fullScreen) {
                        window.toggleFullScreen(nil)
                    }
                }
            }
        )
        .contextMenu {
            displayContextMenu
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MacportSetScalingMode"))) { notif in
            if let mode = notif.object as? DisplayScalingMode {
                scalingMode = mode
            }
        }
        .sheet(isPresented: $isPresentingSettings) {
            MachineSettingsSheet(config: config)
        }
        .sheet(isPresented: $isPresentingSnapshots) {
            SnapshotsSheet(config: config)
        }
    }

    // MARK: - Display Context Menu (Right-Click Parity)

    @ViewBuilder
    private var displayContextMenu: some View {
        Button("Toggle Full Screen (⌃⌘F)") {
            NSApp.keyWindow?.toggleFullScreen(nil)
        }
        Divider()
        if vmState.isActive {
            Button("Paste from Mac Clipboard (⌘V)") {
                NotificationCenter.default.post(name: NSNotification.Name("MacportPasteClipboard"), object: nil)
            }
            Button("Send Ctrl+Alt+Del") {
                NotificationCenter.default.post(name: NSNotification.Name("MacportSendCtrlAltDel"), object: nil)
            }
            Button("Send Shift+F10 (Command Prompt)") {
                NotificationCenter.default.post(name: NSNotification.Name("MacportSendShiftF10"), object: nil)
            }
            Button("Paste from Mac Clipboard (⌘V)") {
                NotificationCenter.default.post(name: NSNotification.Name("MacportPasteClipboard"), object: nil)
            }
            Divider()
            if vmState == .paused {
                Button("Resume (⌘P)") {
                    Task { await state.resume(id: config.id) }
                }
            } else {
                Button("Pause (⌘P)") {
                    Task { await state.pause(id: config.id) }
                }
            }
            Button("Shut Down (⌘.)") {
                Task { await state.stop(id: config.id, graceful: true) }
            }
            Button("Force Off (⌥⌘.)") {
                Task { await state.stop(id: config.id, graceful: false) }
            }
        } else {
            Button("Start (⌘R)") {
                state.start(config, in: store)
            }
        }
        Divider()
        Button("Control Center (⌘0)") {
            bringControlCenterToFront()
        }
        Button("Settings… (⌘,)") {
            isPresentingSettings = true
        }
        Button("Snapshots…") {
            isPresentingSnapshots = true
        }
    }

    // MARK: - Stopped State Placeholder

    private var stoppedStatePlaceholder: some View {
        VStack(spacing: 16) {
            GuestAvatar(guest: config.guest, size: 64)
            Text(config.name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
            Text("Virtual Machine is Stopped")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))

            Button {
                state.start(config, in: store)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("Start Machine")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.macportRunning)
        }
    }

    // MARK: - Actions

    private func snapWindowToGuestResolution() {
        NotificationCenter.default.post(name: NSNotification.Name("MacportSnapWindow"), object: nil)
    }

    private func bringControlCenterToFront() {
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains("main") == true ||
            $0.title.contains("Control Center") ||
            $0.title == "Macport"
        }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Window Accessor Helper

private struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

