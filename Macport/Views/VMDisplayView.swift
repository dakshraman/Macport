import SwiftUI
import Virtualization

/// Hosts a live guest framebuffer.
///
/// `VZVirtualMachineView` is AppKit-only, so it is bridged here. The engine
/// deliberately does not build this view — the hypervisor layer should not know
/// AppKit exists.
struct VMDisplayView: NSViewRepresentable {
    let machine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        // Without this, Command-Tab and friends are swallowed by the guest and
        // the user cannot leave the VM without the mouse.
        view.capturesSystemKeys = true
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        if nsView.virtualMachine !== machine {
            nsView.virtualMachine = machine
        }
    }
}
