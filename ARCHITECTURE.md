# Macport architecture

## The decision everything follows from

Macport has **two engines**, and which one a VM gets is decided by what the guest
needs rather than by preference.

```
VMEngine (protocol)
├── VZEngine      Virtualization.framework   arm64 Linux, lean, cannot boot Windows
└── QEMUEngine    QEMU on Hypervisor.framework   Windows, optical media, x86 emulation
```

The split is not a hedge. It is the answer to a question that was measured rather
than assumed.

### Virtualization.framework cannot host Windows, and the reason is specific

| | Virtualization.framework | QEMU |
| --- | --- | --- |
| arm64 guest at native speed | yes | yes (both end at Hypervisor.framework) |
| **Optical media** | **no — no CD-ROM device exists** | yes |
| macOS guests | yes (the only engine that can) | no |
| Virtual TPM 2.0 | no | needs `swtpm`, which Macport does not ship |
| Boot prompt handling | n/a | must be answered by the engine |
| Foreign-arch emulation (x86 guest) | no | yes (slow) |
| Snapshots | no | yes (qcow2) |
| DirectX 12 | no | experimental (DXMT) |

A Windows installation ISO is a pure El Torito image: it has no MBR, no GPT and no
EFI system partition, so a machine that is handed one as a *disk* has nothing to
boot. Firmware only consults the El Torito boot record on a device it identifies
as optical, and Virtualization.framework's entire storage menu is virtio-blk, NVMe
and USB mass storage. There is no optical device to attach, on any transport. That
single absence is why every Windows installer fails there, and it is the reason
`EngineCapabilities.opticalMedia` exists: it is the honest, machine-readable form
of the sentence above, and it is the field the registry routes on.

This is also why Macport does not pretend to be one thing. `EngineCapabilities`
publishes each engine's limits, and the UI is required to display them rather than
let a user discover them an hour into an install.

## The runtime is Macport's, not the user's problem

"A VM manager that needs QEMU installed by hand" is a VM manager that does not
work. Macport vendors its own runtime:

```
~/Library/Application Support/Macport/Runtime/QEMU/
  bin/     qemu-system-aarch64, qemu-img
  lib/     all 28 dependent libraries, links rewritten to @loader_path/../lib
  share/qemu/   firmware, keymaps, option ROMs
```

199 MB, produced by `QEMURuntimeBundler`, which copies the tool and its transitive
dependencies, rewrites install names, resolves symlinks (Homebrew's `share/qemu`
is a symlink, and a copied symlink points nowhere), and re-signs everything ad-hoc
with the entitlement the accelerator needs. The result runs from an unrelated
directory with no reference to `/opt/homebrew` anywhere in its dependency graph.

Resolution order, most self-contained first:

1. `MACPORT_QEMU_DIR` — an escape hatch for development.
2. The app bundle's `Contents/Resources/Runtime/QEMU` — a Macport.app that needs
   nothing else on the machine.
3. `~/Library/Application Support/Macport/Runtime/QEMU` — what `start` installs on
   demand if nothing else is found.
4. Homebrew, then `PATH` — a courtesy to developers who already have QEMU.

### The entitlement that has to be there

`com.apple.security.hypervisor`, on the QEMU executable. Without it, `-accel hvf`
dies at the first device that needs interrupt virtualisation:

```
-accel hvf: error creating platform VGIC
HV_NO_DEVICE (0xfae94006, at ../accel/hvf/hvf-all.c:221)
```

`com.apple.security.virtualization` (what `VZEngine` needs) and
`com.apple.security.hypervisor` (what `QEMUEngine` needs) are different grants for
different frameworks. See the correction under *Reverse-engineering notes* — the
two look interchangeable from the outside and are not.

## Device choices are the substance

Every device on the QEMU command line is picked for what the **guest** can drive
without a driver disk. A guest that cannot see its own disk cannot be installed at
all, and each of these was established by watching an install fail.

| Device | Why this and not the obvious alternative |
| --- | --- |
| Root disk: **NVMe** | Windows carries `stornvme` in the box. virtio-blk produces "We couldn't find any drives" |
| Install media: **`usb-bot` + `scsi-cd`** | The only transport that satisfies both the firmware (needs optical to read El Torito) and Windows (needs an inbox driver). Measured alternatives in the table below |
| Display, Windows: **`ramfb`** | Windows has no virtio-gpu driver. `ramfb` is a linear framebuffer the firmware programs and Windows drives through its basic display path |
| Display, Linux: **`virtio-gpu-pci`** | Linux does have the driver, and it is the better device |
| USB: **`qemu-xhci`**, explicitly named | A device attached to a bus that does not exist yet is silently dropped. Naming both ends makes that impossible to get wrong |
| Clock: **`-rtc base=localtime`** | Windows reads the RTC as local time; the default shifts its clock |

### The install media transport, in full

Windows Setup has to read its own installation media. The firmware boots whatever
it is handed, so only the second requirement constrains the choice — and it rules
out everything except one option:

| Transport | Firmware | Windows |
| --- | --- | --- |
| `virtio-scsi-pci` + `scsi-cd` | boots | **no driver.** Setup stops at "Install driver to show hardware — a media driver your computer needs is missing" |
| `ich9-ahci` + `ide-cd` | **invisible** — `ArmVirtQemu` has no AHCI driver on `virt`, so no boot option is created at all | driverless |
| `usb-storage` | boots | QEMU materialises it as a `scsi-hd`, i.e. a hard disk, which can never be an optical disc |
| **`usb-bot` + `scsi-cd`** | **boots** | **driverless** — a genuine SCSI CD-ROM (peripheral type 5) behind bulk-only USB |
| `ide-cd` on `virt` | no IDE controller exists | — |

USB is what UTM converges on for optical media on Apple silicon for the same
reasons, and it is the one place where the trade is forced rather than chosen.

### The boot prompt nobody can see

Windows media draws "Press any key to boot from CD or DVD..." and gives it about
five seconds. Unanswered, the loader returns to the firmware, which reports the
boot option as failed and walks the rest of the boot order — on a fresh machine,
an empty disk and then the network:

```
BdsDxe: starting Boot0001 "UEFI QEMU QEMU USB HARDDRIVE 1"
Error: Image at 001BC344000 start failed: Time out
BdsDxe: failed to start Boot0001 ...: Time out
>>Start PXE over IPv4.
```

The engine answers it, and the timing is the whole problem. Pressing on a timer
does not work: QEMU holds keyboard reports until the guest collects them, so
presses sent before the firmware has attached its keyboard are delivered minutes
later, *inside Setup's dialogs* — measured here, a wall of early presses opened the
installer's language list and then restarted the machine. So the engine watches the
console the firmware is already writing to, waits for the line that announces a
boot attempt, and presses exactly once. Every press the prompt does not consume is
a keystroke in somebody's installer.

### A machine with no TPM still has to be installable

Windows 11 refuses to install where it sees no TPM 2.0 and no Secure Boot, and no
engine here can present one: Virtualization.framework has no virtual TPM, and
QEMU's needs an external `swtpm` process that is not part of the runtime Macport
ships. So the check is satisfied rather than the device supplied.

Setup reads an answer file named `autounattend.xml` from the root of any removable
media it can mount, and applies that file's `windowsPE` settings *before* it
evaluates the machine. Macport writes one — including the documented
`HKLM\SYSTEM\Setup\LabConfig` bypasses — onto a small FAT16 volume it generates
itself and attaches as removable media.

Generating it means writing a filesystem: `Fat16Volume` emits a partition table, a
boot sector, a root directory and file contents, with long-file-name entries
because `autounattend.xml` does not fit in 8.3. It is deliberately small, has one
fixed timestamp, and should not be allowed to grow into a general FAT
implementation. The media carries no boot file, so the firmware creates no boot
option for it and the boot order is exactly what it would have been without it.

### Windows driver media is generated, not redistributed

Windows Setup has no driver for the virtio network device and no useful display
driver for the Arm64 `virtio-gpu`. Macport builds a second USB CD-ROM, **Macport
Tools**, from a user-supplied `virtio-win` ISO: it stages only the Arm64 driver
trees and writes an `autounattend.xml` whose `<DriverPaths>` point at them. The
Tools disc carries the answer file when it is present, so the standalone FAT16
answer media is only the fallback. Macport never downloads or ships Microsoft's
signed driver package by itself; when no source ISO is available it writes
`tools-media-warning.txt` and the UI shows the exact path it looked for. This is
the driver media the install needs to finish with networking and a resizable
display.

## Process model and control plane

QEMU is never run in the GUI process. A QEMU machine is owned by
`MacportVMHost`, one process per VM, and the app and `macportctl` are both clients
of it:

```
Macport.app ─┐
             ├─ Unix socket, NDJSON, one request/response per connection
macportctl ──┘         │
                       ▼
                 MacportVMHost (one per VM, holds the bundle flock)
                       │
                       ▼
                 qemu-system-aarch64 (HVF, child process)
```

Virtualization.framework machines stay in-process: VZ objects cannot be handed to
another process, and the engine protocol already isolates the difference behind
`VMEngine`. The registry chooses the boundary per engine, not per guest.

The host writes `runtime.json` (pid, socket path, start time) into the bundle so a
restarted app can adopt a guest that is still running. A second host for the same
bundle is refused twice: the advisory `flock` in the bundle and a listener check
on the socket path. The control socket lives in the per-user temporary directory,
not the bundle, because a bundle path under Application Support exceeds the
kernel's 104-byte Unix-socket limit.

The host's main thread must remain dispatch-serviced: every control handler and
engine call is main-actor isolated. It therefore keeps itself alive with an awaited
continuation rather than a blocking `CFRunLoopRun`. The raw run loop answered
malformed requests (written directly by the server queue) but never drained the
main queue, so a valid `status` hung until timeout — found in live testing, and
pinned by the host's readiness path.

QEMU snapshots use QMP `snapshot-save`/`snapshot-load`/`snapshot-delete`, not HMP
`savevm`. The root disk and the EFI variable store have stable block-node names,
and the root disk is named explicitly as the VM-state target. HMP `savevm` picks
the first writable qcow2 device implicitly; with a writable pflash varstore that
was the 64 MiB NVRAM image, so guest RAM was compressed into the wrong file. The
varstore is converted to qcow2 on the first start so it can participate in
rollback; legacy raw varstores still boot.

## Bundle format

A VM is a self-contained directory, which is what makes it portable:

```
~/Library/Application Support/Macport/VMs/
  <uuid>.macport/
    config.json          VMConfiguration — the only source of truth
    disk.qcow2           snapshot-capable root disk (new machines)
    disk.img             legacy sparse raw root disk; still boots
    efi-vars.qcow2       writable UEFI variable store — boot order and NVRAM
    efi-vars.fd          legacy raw varstore, converted on first start
    answer-media.img     removable media for Setup, when one is needed
    tools-media.iso      generated Windows driver disc, when a source ISO exists
    tools-media-warning.txt  why the driver disc was not built
    console.log          firmware console — the first place to look when a guest
                         will not boot
    qemu.log             engine output
    host.log             MacportVMHost readiness and lifecycle
    runtime.json         live host pid/socket, while it runs
```

Snapshots are internal qcow2 snapshots, so they live in the disk images rather
than in a separate directory. `.lock` is the host's advisory lock and is not part
of the machine's content.

`config.json` is the source of truth. Nothing about a VM lives in a database or in
`UserDefaults`; delete the file and the VM is gone, copy the directory and the VM
moves.

The monitor socket deliberately does **not** live here. A unix socket path is
capped at 104 bytes by the kernel, and a bundle under Application Support passes
that as soon as the account name is more than a few characters — QEMU then refuses
to start with "UNIX socket path is too long" and nothing else. It lives in the
per-user temporary directory, keyed by machine identifier.

## Reverse-engineering notes

Macport's packaging decisions come from analysing shipping implementations with
REA — the "learn from a mature product without reading its source" loop. It has
both caught mistakes and, twice, taught something that only a running VM could
contradict.

**Target:** `/Applications/UTM.app` (5.0.8, build 128)
**SHA-256:** `44432006665adef896a43f9b2ff52524f4f23d3b932158be78e228143fc27c9f`

| Finding | Evidence | Consequence for Macport |
| --- | --- | --- |
| Entitlement set | `ev_b873817604db5e4e06f6e73c03c9c0be7ae0c44dc780ca876b601dda8c2b3d72` | `com.apple.vm.networking` and `com.apple.vm.device-access` are restricted and need an Apple-issued profile — a distribution constraint, recorded rather than discovered later |
| Mach-O: universal, arm64 slice 11.11 MB, min OS 12.0 | `ev_646f522b6f907aa0c1ededbabcc284a8ee250e74b046dd8af4eabdbe64f4d399` | macOS-only target; no universal build needed for local development |
| QEMU ships as **frameworks**, one per target (`qemu-<target>-softmmu.framework`) | bundle layout | UTM executes them in `QEMUClients/QEMUHelper.xpc` — a **separate process per VM**. The framework form is UTM's packaging for web distribution; the isolation is the pattern, and it is the pattern Macport follows with a child process |
| Device strings: `scsi-cd`, `ide-cd`, `scsi-hd`, `ide-hd`, `nvme`, `ramfb`, `virtio-gpu-pci` | `strings` on the main binary | A drive's *interface* is a first-class choice in UTM, which is the same conclusion the transport table above reaches from the other direction |
| UTM's own EDK2 pair: 64 MB code, **329 KB** variables | bundle contents | Not usable by Macport: stock QEMU requires a matched 64 MB variable store for the `virt` flash layout and refuses the combination outright. UTM can only ship that pairing because it ships a patched QEMU. Macport keeps Homebrew's matched pair |

### Two corrections worth keeping

**The hypervisor entitlement.** The first reading was that UTM does not request
`com.apple.security.hypervisor`, therefore neither should Macport — and the
entitlement was removed on that basis. That was wrong, and only a running machine
said so: with it removed, `-accel hvf` failed at VGIC creation. Both readings are
true, because they are about different frameworks.
`com.apple.security.virtualization` grants Virtualization.framework;
`com.apple.security.hypervisor` grants Hypervisor.framework, which is what QEMU
uses. UTM requests the first because `VZEngine`-style guests are its default; the
sentence "UTM does not need it" was never the same as "QEMU does not need it".

**The execution model.** UTM shipping QEMU as dylibs rather than executables first
read as "UTM runs QEMU in-process, so Macport's child-process model is wrong". The
opposite is true: the framework form is a packaging choice, and the actual
execution happens in an XPC service — one per VM. Separate processes per VM are
what every shipping implementation does, and for good reason: a wedged hypervisor
in an in-process engine takes the user's whole app with it.

## Roadmap

**Phase 1 — two engines and a runtime.** VM model, bundle format, engine protocol
and registry, Virtualization.framework engine, QEMU engine with a self-contained
runtime that installs itself on demand. **Done.**

**Phase 2 — runtime boundary and parity core.** Per-VM background host, control
plane, multi-VM registry with admission control, pause/resume, snapshots, clone,
import, machine settings, menu bar extra, `macportctl` parity. **Done for the
matrix recorded in `docs/verification/2026-10-20-phase2.md`.** The remaining
honest gaps are listed there: a real vTPM, a live Windows driver-media install,
and a QEMU bridged-network path.

**Phase 3 — an install that finishes.** The current state is an installer that
boots and runs; an install that completes unattended is the next milestone, and
the answer media is the first piece of it. Beyond that: a vTPM, so the bypass stops
being necessary — that means vendoring `swtpm` the same way QEMU is vendored.

**Phase 4 — integration.** The differentiator, and the part UTM does not do:
publish guest applications as Mac applications. Dock and Launchpad entries, Finder
file associations, clipboard and drag-and-drop, per-app windows. This requires a
guest agent inside Windows speaking a host protocol, which is the single largest
piece of work in the project.

## Non-goals

- Native x86 execution. Impossible on arm64 silicon; no design achieves it.
- A zero-footprint Windows VM. A second OS costs RAM and disk.
- Competing with Parallels on polish. Phase 4 is the bet, not parity.
- Reimplementing licensed code. Macport learns from shipping products by observing
  their structure; it does not decompile their algorithms or touch their licensing.
