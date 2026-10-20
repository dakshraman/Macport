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
    @State private var scalingMode: DisplayScalingMode = .aspectFit

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VNCRepresentable(
                socketPath: socketPath,
                isConnected: $isConnected,
                guestSize: $guestSize,
                clientHolder: $client,
                scalingMode: $scalingMode
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
                HStack(spacing: 10) {
                    if guestSize.width > 0 {
                        Text("\(Int(guestSize.width)) × \(Int(guestSize.height))")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.12)))

                        // Snap Window to Guest Resolution
                        Button {
                            snapWindowToGuest()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                                    .font(.system(size: 10))
                                Text("Snap")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.15)))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Snap window size directly to guest resolution (\(Int(guestSize.width))×\(Int(guestSize.height)))")

                        // Scaling Mode Toggle (Fit vs Stretch)
                        Button {
                            scalingMode = scalingMode == .aspectFit ? .fill : .aspectFit
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: scalingMode == .aspectFit ? "aspectratio" : "arrow.up.left.and.down.right.magnifyingglass")
                                    .font(.system(size: 10))
                                Text(scalingMode == .aspectFit ? "Fit" : "Stretch")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(scalingMode == .fill ? Color.macportAccent.opacity(0.6) : Color.white.opacity(0.15)))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Toggle between Aspect Fit and Stretch to Fill (eliminates black borders)")
                    }

                    Button {
                        client?.sendKeyEvent(key: 0x0020, isDown: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            client?.sendKeyEvent(key: 0x0020, isDown: false)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "space")
                                .font(.system(size: 10))
                            Text("Space")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.15)))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Send Space keypress")

                    Button {
                        client?.sendKeyEvent(key: 0xFF09, isDown: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            client?.sendKeyEvent(key: 0xFF09, isDown: false)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.to.line")
                                .font(.system(size: 10))
                            Text("Tab")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.15)))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Send Tab keypress to cycle focus")

                    Button {
                        client?.sendKeyEvent(key: 0xFF0D, isDown: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            client?.sendKeyEvent(key: 0xFF0D, isDown: false)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "return")
                                .font(.system(size: 10))
                            Text("Enter")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.15)))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Send Enter / Return keypress")

                    Button {
                        // Shift + F10 opens Command Prompt in Windows Setup
                        client?.sendKeyEvent(key: 0xFFE1, isDown: true)
                        client?.sendKeyEvent(key: 0xFFC7, isDown: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            client?.sendKeyEvent(key: 0xFFC7, isDown: false)
                            client?.sendKeyEvent(key: 0xFFE1, isDown: false)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal")
                                .font(.system(size: 10))
                            Text("Shift+F10")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.15)))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Send Shift+F10 to open Command Prompt / LabConfig in Windows Setup")

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

    private func snapWindowToGuest() {
        guard guestSize.width > 0, guestSize.height > 0, let window = NSApp.keyWindow else { return }
        let titlebarHeight = window.frame.height - (window.contentView?.frame.height ?? window.frame.height)
        var newFrame = window.frame
        newFrame.size = CGSize(width: guestSize.width, height: guestSize.height + titlebarHeight)
        newFrame.origin.y = window.frame.maxY - newFrame.height
        window.setFrame(newFrame, display: true, animate: true)
    }
}

// MARK: - Display Scaling Mode

public enum DisplayScalingMode: String, CaseIterable, Identifiable, Sendable {
    case aspectFit = "Fit"
    case fill = "Stretch"
    case center = "1:1 Native"
    public var id: String { rawValue }
}

// MARK: - AppKit View Representable

@MainActor
private struct VNCRepresentable: NSViewRepresentable {
    let socketPath: String
    @Binding var isConnected: Bool
    @Binding var guestSize: CGSize
    @Binding var clientHolder: RFBDisplayClient?
    @Binding var scalingMode: DisplayScalingMode

    func makeNSView(context: Context) -> VNCView {
        let view = VNCView()
        let client = RFBDisplayClient(socketPath: socketPath)
        view.client = client
        clientHolder = client
        view.scalingMode = scalingMode

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

        client.onClipboardTextReceived = { text in
            Task { @MainActor in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
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

    func updateNSView(_ nsView: VNCView, context: Context) {
        if nsView.scalingMode != scalingMode {
            nsView.scalingMode = scalingMode
        }
    }

    static func dismantleNSView(_ nsView: VNCView, coordinator: ()) {
        nsView.client?.disconnect()
    }
}

// MARK: - Native AppKit VNC Canvas

private final class VNCView: NSView {
    var client: RFBDisplayClient?
    var scalingMode: DisplayScalingMode = .aspectFit {
        didSet {
            needsDisplay = true
        }
    }
    private var currentImage: CGImage?
    private var trackingAreaRef: NSTrackingArea?
    private var previousModifiers: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    override func resignFirstResponder() -> Bool {
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }

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
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
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
        switch scalingMode {
        case .fill:
            return container
        case .center:
            let x = container.origin.x + (container.width - size.width) / 2
            let y = container.origin.y + (container.height - size.height) / 2
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        case .aspectFit:
            let scale = min(container.width / size.width, container.height / size.height)
            let scaledW = size.width * scale
            let scaledH = size.height * scale
            let x = container.origin.x + (container.width - scaledW) / 2
            let y = container.origin.y + (container.height - scaledH) / 2
            return CGRect(x: x, y: y, width: scaledW, height: scaledH)
        }
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

    private func sendPointer(with event: NSEvent, buttonMask: UInt8) {
        let pt = convert(event.locationInWindow, from: nil)
        if let (gx, gy) = guestCoordinates(from: pt) {
            client?.sendPointerEvent(x: gx, y: gy, buttonMask: buttonMask)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(with: event, buttonMask: 1) // Left click
    }

    override func mouseUp(with event: NSEvent) {
        sendPointer(with: event, buttonMask: 0) // Release
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(with: event, buttonMask: 1)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(with: event, buttonMask: 4) // Right click
    }

    override func rightMouseUp(with event: NSEvent) {
        sendPointer(with: event, buttonMask: 0) // Release
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointer(with: event, buttonMask: 4)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(with: event, buttonMask: 2) // Middle click
    }

    override func otherMouseUp(with event: NSEvent) {
        sendPointer(with: event, buttonMask: 0)
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointer(with: event, buttonMask: 0)
    }

    override func scrollWheel(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let (gx, gy) = guestCoordinates(from: pt) else { return }
        if event.deltaY > 0 {
            client?.sendPointerEvent(x: gx, y: gy, buttonMask: 8) // Scroll up
            client?.sendPointerEvent(x: gx, y: gy, buttonMask: 0)
        } else if event.deltaY < 0 {
            client?.sendPointerEvent(x: gx, y: gy, buttonMask: 16) // Scroll down
            client?.sendPointerEvent(x: gx, y: gy, buttonMask: 0)
        }
    }

    // MARK: - Keyboard Input Mapping

    override func flagsChanged(with event: NSEvent) {
        let current = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let prev = previousModifiers

        if current.contains(.shift) && !prev.contains(.shift) {
            client?.sendKeyEvent(key: 0xFFE1, isDown: true) // Shift_L
        } else if !current.contains(.shift) && prev.contains(.shift) {
            client?.sendKeyEvent(key: 0xFFE1, isDown: false)
        }

        if current.contains(.control) && !prev.contains(.control) {
            client?.sendKeyEvent(key: 0xFFE3, isDown: true) // Control_L
        } else if !current.contains(.control) && prev.contains(.control) {
            client?.sendKeyEvent(key: 0xFFE3, isDown: false)
        }

        if current.contains(.option) && !prev.contains(.option) {
            client?.sendKeyEvent(key: 0xFFE9, isDown: true) // Alt_L
        } else if !current.contains(.option) && prev.contains(.option) {
            client?.sendKeyEvent(key: 0xFFE9, isDown: false)
        }

        if current.contains(.command) && !prev.contains(.command) {
            client?.sendKeyEvent(key: 0xFFEB, isDown: true) // Super_L
        } else if !current.contains(.command) && prev.contains(.command) {
            client?.sendKeyEvent(key: 0xFFEB, isDown: false)
        }

        previousModifiers = current
    }

    override func keyDown(with event: NSEvent) {
        // Mac-to-Windows shortcut translation: ⌘C -> Ctrl+C, ⌘V -> send clipboard + Ctrl+V, ⌘A -> Ctrl+A
        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "c" {
                client?.sendKeyEvent(key: 0xFFE3, isDown: true) // Ctrl_L
                client?.sendKeyEvent(key: 0x0063, isDown: true) // c
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.client?.sendKeyEvent(key: 0x0063, isDown: false)
                    self?.client?.sendKeyEvent(key: 0xFFE3, isDown: false)
                }
                return
            } else if key == "v" {
                if let str = NSPasteboard.general.string(forType: .string) {
                    client?.sendClipboardText(str)
                }
                client?.sendKeyEvent(key: 0xFFE3, isDown: true) // Ctrl_L
                client?.sendKeyEvent(key: 0x0076, isDown: true) // v
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.client?.sendKeyEvent(key: 0x0076, isDown: false)
                    self?.client?.sendKeyEvent(key: 0xFFE3, isDown: false)
                }
                return
            } else if key == "a" {
                client?.sendKeyEvent(key: 0xFFE3, isDown: true) // Ctrl_L
                client?.sendKeyEvent(key: 0x0061, isDown: true) // a
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.client?.sendKeyEvent(key: 0x0061, isDown: false)
                    self?.client?.sendKeyEvent(key: 0xFFE3, isDown: false)
                }
                return
            }
        }

        let keysym = x11KeySym(for: event)
        if keysym != 0 {
            client?.sendKeyEvent(key: keysym, isDown: true)
        }
    }

    override func keyUp(with event: NSEvent) {
        let keysym = x11KeySym(for: event)
        if keysym != 0 {
            client?.sendKeyEvent(key: keysym, isDown: false)
        }
    }

    private func x11KeySym(for event: NSEvent) -> UInt32 {
        switch event.keyCode {
        case 36: return 0xFF0D // Return
        case 48: return 0xFF09 // Tab
        case 49: return 0x0020 // Space
        case 51: return 0xFF08 // Backspace
        case 53: return 0xFF1B // Escape
        case 76: return 0xFF8D // Keypad Enter
        case 117: return 0xFFFF // Delete
        case 123: return 0xFF51 // Left
        case 124: return 0xFF53 // Right
        case 125: return 0xFF54 // Down
        case 126: return 0xFF52 // Up
        case 115: return 0xFF50 // Home
        case 119: return 0xFF57 // End
        case 116: return 0xFF55 // Page Up
        case 121: return 0xFF56 // Page Down
        case 122: return 0xFFBE // F1
        case 120: return 0xFFBF // F2
        case 99:  return 0xFFC0 // F3
        case 118: return 0xFFC1 // F4
        case 96:  return 0xFFC2 // F5
        case 97:  return 0xFFC3 // F6
        case 98:  return 0xFFC4 // F7
        case 100: return 0xFFC5 // F8
        case 101: return 0xFFC6 // F9
        case 109: return 0xFFC7 // F10
        case 103: return 0xFFC8 // F11
        case 111: return 0xFFC9 // F12
        default:
            if let chars = event.characters, let first = chars.unicodeScalars.first {
                let val = first.value
                if val >= 32 && val <= 126 {
                    return UInt32(val)
                }
            }
            if let chars = event.charactersIgnoringModifiers, let first = chars.unicodeScalars.first {
                return UInt32(first.value)
            }
            return 0
        }
    }
}
