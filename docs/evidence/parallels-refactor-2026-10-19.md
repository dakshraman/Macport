# Evidence ledger — Parallels Desktop 27.0.3, refactor pass

**Date** 2026-10-19
**Tooling** REA 6.7.0 (server 6.7.0, `rea-artifact-graph` + `native-macos`)
**Target** `/Applications/Parallels Desktop.app`, version 27.0.3, build 58680
**Main executable** `Contents/MacOS/prl_client_app`, arm64, SHA-256
`8aafd57766594be4120607f69e795966cd5615f02d0cd79563e05b57ef49527f`

**Scope boundary.** Package structure, code signatures, entitlements, Mach-O linkage,
shipped plists and shipped configuration were read. No proprietary code was
decompiled and no licence or activation logic was inspected. The IPC wire format was
not established; only the process/library boundaries are reported.

**Retention note.** Evidence IDs below were captured during the REA session. The session
was closed after this ledger was written, which clears REA's retained records. The
observations are reproducible with `open_binary`, `inspect_artifact`,
`inspect_signature` and `inspect_macho` on the installed app.

---

## 1. Process and privilege topology

| Observation | Evidence | Confidence |
|---|---|---|
| `prl_client_app` (GUI) links Qt 5 and `ParallelsVirtualizationSDK`/`libPrlSdkCommunication`; it does not link `Hypervisor.framework`. | `ev_47db4a19d347ac00d55b1ad428ef470a0a9058605e9d28edab46874f5ea5c2fb` (artifact graph), `ev_4a937b7a…`/`ev_2e0854c1…` (signatures) | observed |
| `prl_vm_app` (per-VM process) is a separate executable, `com.parallels.vm`, SHA-256 `79afaead95e143397c0e753ee9a2196fca6226eea74b635f855cb68539d786f3`; it links `Hypervisor.framework` and `vmnet.framework`, not `Virtualization.framework`. | `ev_b7bf0f56bbd0e0815e165f0405a62f522f3a12be8d1189d22fa795617cc05ff6` (Mach-O), `ev_cd06d00ee6b5ef1e1aace9cbd4814401c474ede57059b821155e0e21230aed16` (signature) | observed |
| `prl_disp_service` (dispatcher), `com.parallels.desktop.dispatcher`, SHA-256 `d9f2fff825b4e97400bfffb110b96b242d246d93aa3f4da05308f3e4319d6c26`, links `Hypervisor.framework` and `vmnet.framework`; its signature carries no Hypervisor/networking entitlement (one entitlement total). | `ev_4b31dfe160a3401f618f13bd2b9a2b5cfd06493865c07c6f5df4917230136c7c` (Mach-O), `ev_1e4b40223ac65607211f423d684ff352de397da40b362e637d6b979833c4fdff` (signature) | observed |
| `prl_macvm_app` (macOS guest), `com.parallels.macvm`, SHA-256 `32441ea3c898cedf8ca5bdd37852a59ed19259b3fbc9d93659bb5b9a509b3f12`, links `Virtualization.framework` and `vmnet.framework`. | `ev_378ec56969f44d0ce766263ae3a133a216807d3e2622503f732c353c039ba2de` (Mach-O), `ev_4a937b7a…` (signature) | observed |
| The setuid launcher is `Contents/MacOS/Parallels Service`, mode `-rwsr-sr-x root:accessibility`; it invokes `/Library/Parallels/Parallels Desktop/launchd_wrapper`, installed `root:wheel`. | filesystem `stat`; launchd plist `ev_1ae327532db2a6e1ac950815395386351e7468f9349ff31c85e28aba358bf3e5` | observed |
| The launch daemon is `com.parallels.desktop.launchdaemon`, `RunAtLoad`, `ProcessType=Interactive`, `ExitTimeOut=150`, program `/Library/Parallels/Parallels Desktop/launchd_wrapper`. | launchd plist `ev_1ae327532db2a6e1ac950815395386351e7468f9349ff31c85e28aba358bf3e5` | observed |
| The only XPC service in the bundle is `XPCMounter` (`com.parallels.xpcmounter`), an `Application`-type XPC service inside `Parallels VM.app`; it is for disk mounting, not VM lifecycle. | artifact graph `ev_47db4a19…`; plist `ev_25d766efea5ce0e97d4349db907750d89c44b8761c56a0bbcb490b5d42cbdb70` | observed |
| `Parallels VM.app` carries its own firmware resources, `SysBios.bin` and `VgaBios.bin`. | artifact graph `ev_47db4a19…` | observed |

## 2. Entitlement placement

| Binary | Virtualization | Hypervisor | `vm.networking` | `vm.device-access` | Sandbox |
|---|---:|---:|---:|---:|---:|
| `prl_client_app` (GUI) | yes | no | **no** | **no** | no |
| `prl_vm_app` (per-VM) | no | **yes** | **yes** | **yes** | no |
| `prl_disp_service` (dispatcher) | no | no | no | no | no |
| `prl_macvm_app` (macOS guest) | **yes** | no | **yes** | **yes** | no |

Evidence: `ev_2e0854c16bab67955d8ac5bc3b5e14a7e8cd0b14a25b20a8569b78f59868817e`
(GUI), `ev_cd06d00ee6b5ef1e1aace9cbd4814401c474ede57059b821155e0e21230aed16`
(per-VM), `ev_1e4b40223ac65607211f423d684ff352de397da40b362e637d6b979833c4fdff`
(dispatcher), `ev_4a937b7acdc0f566886cfce7910dda57e0b60c8d3ba99c3478666e2301c7ba52`
(macOS guest).

**Inference:** Parallels places the powerful entitlements on the process that owns the
guest, not on the UI. The dispatcher is deliberately unprivileged. A separate setuid
launcher handles installation/privileged host work. Presence of an entitlement is not
proof that the kernel granted it at runtime, but the placement is unambiguous.

## 3. VM bundle and tools

| Observation | Evidence | Confidence |
|---|---|---|
| The shipping app contains `Parallels VM.app`, `Parallels Service.app` and `Parallels Mac VM.app`; 972 package occurrences in the artifact graph. | `ev_47db4a19…` | observed |
| A user `.pvm` bundle on this Mac contains `config.pvs`, a `*.hdd` disk directory and a per-VM `VM.app` whose executable is `WinAppHelper` (`com.parallels.winapp.<hash>.VM`) — the shared-application integration helper, not the hypervisor. No `Snapshots` directory is present in this instance. | filesystem listing; `plutil` of the PVM's `VM.app/Contents/Info.plist` | observed, single instance |
| The bundle ships Arm64 tools media per guest: `prl-tools-win-arm.iso`, `prl-tools-lin-arm.iso`, `prl-tools-mac-arm.iso`, plus `prl-tools-win.tar.gz`. | `Contents/Resources/Tools` listing; see `docs/FEATURE-PARITY.md` §9 | observed |
| `Autounattend_arm64.xml` contains `<DriverPaths>` pointing at `E:\netkvm\arm64`; `netkvm/arm64` and `prl_tg/arm64` sit beside it. | shipped XML read directly; Tools listing | observed |

## 4. What this pass did not establish

- The `libPrlSdkCommunication` wire protocol, message schema, socket type or framing.
- How the dispatcher authenticates clients, or how a second GUI instance attaches.
- The on-disk snapshot format (no snapshot existed in the inspected VM).
- Whether the restricted entitlements are granted in every shipped configuration.
- The exact drive-letter assignment that makes `E:\netkvm\arm64` stable across Windows
  Setup builds.

These are deliberately left as unknowns. Macport's refactor copies the **boundaries**,
not the protocol or the code.
