import AppKit
import SwiftUI
import CoreGraphics
import MacportKit

/// Hosts a live guest framebuffer directly inside the Macport app window.
///
/// Communicates over a private local UNIX domain socket using RFB (VNC protocol)
/// to the headless background VM daemon, providing the exact same embedded experience
/// as Parallels Desktop without any external pop-up windows.
@MainActor
struct EmbeddedVNCDisplayView: View {
    let socketPath: String

    @State private var isConnected = false
    @State private var guestSize: CGSize = .zero
    @State private var client: RFBDisplayClient?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VNCRepresentable(
                socketPath: socketPath,
                isConnected: $isConnected,
                guestSize: $guestSize,
                clientHolder: $client
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !isConnected {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.white)
                    Text("Connecting to guest console…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.75)))
            }

            // Parallels Floating Console Overlay Bar
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    if guestSize.width > 0 {
                        Text("\(Int(guestSize.width)) × \(Int(guestSize.height))")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }

                    Button {
                        client?.sendCtrlAltDel()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "keyboard")
                                .font(.system(size: 10))
                            Text("Ctrl+Alt+Del")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.15)))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Send Ctrl+Alt+Del to unlock logon or Task Manager")

                    Button {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11))
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.15)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Full Screen")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.65))
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                )
                .padding(.bottom, 14)
            }
        }
    }
}

// MARK: - AppKit View Representable

@MainActor
private struct VNCRepresentable: NSViewRepresentable {
    let socketPath: String
    @Binding var isConnected: Bool
    @Binding var guestSize: CGSize
    @Binding var clientHolder: RFBDisplayClient?

    func makeNSView(context: Context) -> VNCView {
        let view = VNCView()
        let client = RFBDisplayClient(socketPath: socketPath)
        view.client = client
        clientHolder = client

        client.onFrame = { frame in
            Task { @MainActor in
                if !isConnected {
                    isConnected = true
                }
                let newSize = CGSize(width: frame.width, height: frame.height)
                if guestSize != newSize {
                    guestSize = newSize
                }
                view.updateFrame(frame)
            }
        }

        client.onDisconnect = {
            Task { @MainActor in
                isConnected = false
            }
        }

        client.connect()
        return view
    }

    func updateNSView(_ nsView: VNCView, context: Context) {}

    static func dismantleNSView(_ nsView: VNCView, coordinator: ()) {
        nsView.client?.disconnect()
    }
}

// MARK: - Native AppKit VNC Canvas

private final class VNCView: NSView {
    var client: RFBDisplayClient?
    private var currentImage: CGImage?
    private var trackingAreaRef: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateFrame(_ frame: RFBDisplayClient.Frame) {
        self.currentImage = frame.image
        self.needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingAreaRef = area
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)

        guard let image = currentImage else { return }

        let imageSize = CGSize(width: image.width, height: image.height)
        let rect = aspectFitRect(for: imageSize, in: bounds)

        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
    }

    private func aspectFitRect(for size: CGSize, in container: CGRect) -> CGRect {
        guard size.width > 0 && size.height > 0 else { return container }
        let scale = min(container.width / size.width, container.height / size.height)
        let scaledW = size.width * scale
        let scaledH = size.height * scale
        let x = container.origin.x + (container.width - scaledW) / 2
        let y = container.origin.y + (container.height - scaledH) / 2
        return CGRect(x: x, y: y, width: scaledW, height: scaledH)
    }

    // MARK: - Mouse Input Mapping

    private func guestCoordinates(from viewPoint: NSPoint) -> (x: Int, y: Int)? {
        guard let image = currentImage else { return nil }
        let imageSize = CGSize(width: image.width, height: image.height)
        let fitRect = aspectFitRect(for: imageSize, in: bounds)

        guard fitRect.contains(viewPoint) else { return nil }

        let normalizedX = (viewPoint.x - fitRect.origin.x) / fitRect.width
        // Flip Y for top-down guest coordinate system
        let normalizedY = 1.0 - ((viewPoint.y - fitRect.origin.y) / fitRect.height)

        let guestX = Int(normalizedX * CGFloat(image.width))
        let guestY = Int(normalizedY * CGFloat(image.height))

        return (
            x: max(0, min(image.width - 1, guestX)),
            y: max(0, min(image.height - 1, guestY))
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        if let (gx, gy) = guestCoordinates(from: pt) {
            client?.sendPointerEvent(x: gx, y: gy, buttonMask: 1) // Left click
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let (gx, gy) = guestCoordinates(from: pt) {
            client?.sendPointerEvent(x: gx, y: gy, buttonMask: 0) // Release
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        if let (gx, gy) = guestCoordinates(from: pt) {
            client?.sendPointerEvent(x: gx, y: gy, buttonMask: 4) // Right click
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let (gx, gy) = guestCoordinates(from: pt) {
            client?.sendPointerEvent(x: gx, y: gy, buttonMask: 0) // Release
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let (gx, gy) = guestCoordinates(from: pt) {
            client?.sendPointerEvent(x: gx, y: gy, buttonMask: 0)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let (gx, gy) = guestCoordinates(from: pt) {
            client?.sendPointerEvent(x: gx, y: gy, buttonMask: 1)
        }
    }

    // MARK: - Keyboard Input Mapping

    override func keyDown(with event: NSEvent) {
        let keysym = x11KeySym(for: event)
        client?.sendKeyEvent(key: keysym, isDown: true)
    }

    override func keyUp(with event: NSEvent) {
        let keysym = x11KeySym(for: event)
        client?.sendKeyEvent(key: keysym, isDown: false)
    }

    private func x11KeySym(for event: NSEvent) -> UInt32 {
        switch event.keyCode {
        case 36: return 0xFF0D // Return
        case 48: return 0xFF09 // Tab
        case 49: return 0x0020 // Space
        case 51: return 0xFF08 // Backspace
        case 53: return 0xFF1B // Escape
        case 117: return 0xFFFF // Delete
        case 123: return 0xFF51 // Left
        case 124: return 0xFF53 // Right
        case 125: return 0xFF54 // Down
        case 126: return 0xFF52 // Up
        case 115: return 0xFF50 // Home
        case 119: return 0xFF57 // End
        case 116: return 0xFF55 // Page Up
        case 121: return 0xFF56 // Page Down
        default:
            if let chars = event.charactersIgnoringModifiers, let first = chars.utf16.first {
                return UInt32(first)
            }
            return 0
        }
    }
}
