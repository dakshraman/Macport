# Competitive analysis: how Parallels Desktop is actually built

Static package inspection of the shipping Parallels Desktop build, to answer one
question: **how does a commercial hypervisor deliver capabilities Apple's
Virtualization framework cannot?**

All findings come from observable package structure — entitlements, linked
libraries, Mach-O metadata, bundle layout. No proprietary code was decompiled, and
no licence or activation mechanism was examined.

## Evidence

| Target | SHA-256 | Evidence |
| --- | --- | --- |
| `prl_client_app` | `8aafd57766594be4120607f69e795966cd5615f02d0cd79563e05b57ef49527f` | `ev_7e99254ad99d643dd3e6f31d39ad1c654f71f79962a6dd64341c2928e1c453ae` (architectures), `ev_c0943b677d4eef485e9d49e4f0e411d8d8fe9d7fbd32ba719f1991ae39ca52eb` (signature) |
| UTM 5.0.8 `UTM` | `44432006665adef896a43f9b2ff52524f4f23d3b932158be78e228143fc27c9f` | `ev_b873817604db5e4e06f6e73c03c9c0be7ae0c44dc780ca876b601dda8c2b3d72` (signature), `ev_646f522b6f907aa0c1ededbabcc284a8ee250e74b046dd8af4eabdbe64f4d399` (Mach-O) |

Providers: `native-macos` (`list_architectures`, `inspect_macho`, `inspect_plist`,
`inspect_signature`), `rea-artifact-graph` (`trace_dylib_resolution`).
Confidence: **observed** — fields read out of the shipping binaries.
Authority: `shipped-artifact`.

---

## Finding 1 — The architecture is a layered process tree, and the GUI is not in it

Tracing `LC_LOAD_DYLIB` edges and testing each executable for framework linkages
gives the real topology:

| Process | Role | Links Hypervisor | Links Virtualization |
| --- | --- | --- | --- |
| `prl_client_app` | GUI (Qt 5.15.1) | **no** | no |
| `prl_disp_service` | dispatcher service | **yes** | no |
| `prl_vm_app` | **per-VM host process** | **yes** | no |
| `libMonitorArm.dylib` | ARM virtual machine monitor | **yes** | no |
| `libMonitorX86Emu.dylib` | x86 emulation monitor | **yes** | no |
| `prl_macvm_app` | macOS guest host | no | **yes** |
| `prl_macvm_helper` | macOS guest helper | no | **yes** |

Two things follow, and both are load-bearing.

**The GUI never loads the hypervisor.** `prl_client_app`'s entire load list is Qt,
`ParallelsVirtualizationSDK`, `libPrlSdkCommunication`, `libPrlGui`, `PDCocoaKit`,
`PDControlCenter`, `libPrlXmlModel`, `libAbstractTask` and system frameworks. It is
a UI process that speaks IPC. Every hypervisor call happens one or more processes
away.

> Correction: an earlier revision of this document claimed the GUI linked
> `Hypervisor.framework`. That was inferred from a truncated `otool` listing, not
> observed. The per-binary linkage survey above is the check, and it refutes it.

**The dependency chain is:**
`prl_client_app` → `libPrlSdkCommunication` → `prl_disp_service` / `prl_vm_app` →
`libMonitorArm` → `Hypervisor.framework` → CPU virtualisation extensions.

Each arrow is a deliberate boundary. `libPrlSdkCommunication` is the client half of
their IPC protocol; `libMonitorArm` is the actual VMM.

## Finding 2 — The VM runs in its own process, per VM

`Parallels VM.app/Contents/MacOS/prl_vm_app` is one process per running virtual
machine. It carries its own firmware — `Resources/SysBios.bin` and
`Resources/VgaBios.bin` — and its own nested `XPCServices/XPCMounter.xpc`.

This is the same structural answer UTM arrived at independently, where each VM is
hosted by `QEMUHelper.xpc`. Two unrelated products, one conclusion:

> **A virtual machine belongs in a process of its own, not in the GUI's.**

The consequences are the point: a GUI crash does not kill running VMs, an app
update does not kill running VMs, several VMs run at once, and the GUI's attack
surface stays small because it never maps guest memory.

`SysBios.bin` and `VgaBios.bin` are the other half of the story. Virtualising a
guest that expects a PC requires *firmware and a chipset* — the guest boots looking
for a BIOS, a VGA option ROM, a PS/2 controller. Shipping `.bin` files means
Parallels wrote and maintain that firmware. It is the concrete form of "they built
a device model by hand", and it is why the capability table below is not closable
by configuration.

## Finding 3 — macOS guests are the exception, and the exception is instructive

`prl_macvm_app` and `prl_macvm_helper` link `Virtualization.framework` and *not*
`Hypervisor.framework`. Nothing else in the bundle links
`Virtualization.framework` at all.

The split falls exactly on a legal/technical line: Parallels cannot virtualise
macOS with their own VMM, so for macOS guests — and only those — they delegate to
Apple. Every other guest goes through `libMonitorArm`.

A codebase that used Apple's framework throughout would have no reason to contain
this seam.

## Finding 4 — The privileged work is in a setuid root binary

```
-rwsr-sr-x  1 root  accessibility  Parallels Service
```

Setuid **and** setgid root. Corroborated by entitlements: `prl_client_app` carries
only `com.apple.security.virtualization` among the VM-related grants, and
**neither** `com.apple.vm.networking` nor `com.apple.vm.device-access` — the two
restricted entitlements UTM requests. Parallels sidesteps the restricted-entitlement
path entirely by moving privileged work into a setuid binary, alongside
`/Library/Parallels` and LaunchDaemons.

Two valid routes to the same privilege:

| | setuid helper (Parallels) | restricted entitlements (UTM) |
| --- | --- | --- |
| Apple approval | not required | required (provisioning profile) |
| Attack surface | root-privileged binary on every machine | small, per-app grants |
| Distribution | direct only — inadmissible on the Mac App Store | App Store viable |

Macport uses neither today, which is why it is NAT-only. That is a deferral, and
Finding 6 says which route it should take.

## Finding 5 — Qt, unsandboxed, arm64-only, macOS 14+

`prl_client_app` links twelve Qt 5.15.1 frameworks. `list_architectures` reports a
single slice with `exhaustive: true`:

```json
{ "architectures": { "items": [ { "name": "arm64" } ], "total": 1, "exhaustive": true } }
```

Parallels has dropped Intel Macs. UTM still ships `[x86_64, arm64]`.

And the sandbox comparison reverses a common assumption:

| | `app-sandbox` | Compensating grants |
| --- | --- | --- |
| UTM 5.0.8 | **true** | `files.user-selected.read-write`, 1 app group |
| Parallels `prl_client_app` | **absent** | Apple Events, camera, address book, 3 app groups, keychain |

Parallels' camera and address-book entitlements are the integration layer made
visible: they exist so a Windows guest can use the Mac's webcam and contacts.

## Finding 6 — What this means for Macport

**1. Copy the process boundary; do not copy the hypervisor.** The lesson worth
taking is Finding 2 — isolate the VM. `ParallelsVirtualizationSDK` plus
`libMonitorArm` plus hand-written BIOS is years of work and is not the lesson.

**2. But do not take the process boundary yet, and here is the reason.** This is
the part that only becomes visible once both facts are held at once: Parallels can
isolate the VM because they own the display path. They ship `prl_disp_service` and
move frames out of the VM process themselves.

Apple's `VZVirtualMachineView` cannot do that. It renders by referencing a live
`VZVirtualMachine` **in the same process**. A VM hosted out-of-process therefore has
no display — the framework offers no cross-process framebuffer transport.

So for Macport on Virtualization.framework, in-process is not laziness; it is the
only option that produces a picture on screen. This is also precisely why UTM runs
its Virtualization-backend VMs in-process and only its QEMU-backend VMs out of
process. Both products agree again, from opposite directions.

The correct move is to build the **seam** now and take the split when a QEMU engine
arrives and needs it:

```
VMEngine (protocol)
├── VZEngine       in-process — required by VZVirtualMachineView for display
└── QEMUEngine     out-of-process (planned) — owns its own framebuffer, so it can
                   be isolated the way prl_vm_app and QEMUHelper.xpc are
```

**3. Take the restricted entitlements, not the setuid binary.** A root-privileged
binary shipped to every customer is the most dangerous component in Parallels'
design. `com.apple.vm.networking` and `com.apple.vm.device-access` are the smaller
risk, and they keep the Mac App Store open as an option.

**4. The integration layer is the undefended ground.** Parallels' camera and
address-book grants show where the product's value sits — plumbing Mac capabilities
into the guest — and unlike the hypervisor, that layer is not protected by a
framework they spent years writing.

### Unresolved

- The XPC protocol between `libPrlSdkCommunication` and `prl_disp_service`. Not
  examined; Macport is not reimplementing it.
- Whether `libMonitorArm` and `libMonitorX86Emu` are selected per guest
  architecture at VM start, or loaded together. The linkage shows both exist; the
  selection logic was not traced.
- `Parallels Mounter.app`, `Parallels Link.app` and the `prl_*` tool set were
  inventoried but not analysed individually.
