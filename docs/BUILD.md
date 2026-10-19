# Building Macport

Macport has no Swift package dependencies and no downloaded toolchain. Xcode plus
[XcodeGen](https://github.com/yonaskolb/XcodeGen) is the whole build system.

## Generate and build

```sh
cd ~/Projects/Macport
xcodegen generate                       # writes Macport.xcodeproj from project.yml

# Compile check: no signing, no entitlements applied. Fastest, used by CI.
xcodebuild -project Macport.xcodeproj -scheme Macport \
  -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Macport.xcodeproj -scheme MacportCtl \
  -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO

# Unit tests (no guest boots, no runtime required).
xcodebuild -project Macport.xcodeproj -scheme Macport \
  -configuration Debug -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

`Macport.xcodeproj` is generated and git-ignored. Re-run `xcodegen generate` after
adding or moving source files, changing `project.yml`, or checking out a branch
that did either.

## Running a VM locally

`CODE_SIGNING_ALLOWED=NO` builds cannot boot guests: `com.apple.security.virtualization`
is not applied to an unsigned binary. For a runnable local build, sign ad-hoc with
the shipping entitlements (which are deliberately identical to the development set
for everything Virtualization.framework needs):

```sh
xcodebuild -project Macport.xcodeproj -scheme Macport \
  -configuration Debug -destination 'platform=macOS' \
  build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES
```

Do **not** sign with `--deep`, and do not re-sign the embedded QEMU runtime: those
binaries already carry `com.apple.security.hypervisor`, and a blind deep sign strips
it, which turns every QEMU boot into a hypervisor failure.

The per-VM QEMU host (Workstream C) will carry the restricted
`com.apple.vm.networking` / `com.apple.vm.device-access` grants once Apple issues
them. Those keys live, commented out, in `Support/MacportVMHost.entitlements`; a
signing failure after uncommenting them means the grant is missing, not that the
file is malformed.

## The QEMU runtime

Macport does not require Homebrew and does not expect the user to install QEMU.
The runtime is vendored into the user's managed directory:

```
~/Library/Application Support/Macport/Runtime/QEMU/
  bin/qemu-system-aarch64, bin/qemu-img
  lib/…                (28 dylibs, rewritten to @rpath)
  share/qemu/…         (EDK2 firmware, data files)
```

Resolution order at runtime is `MACPORT_QEMU_DIR` → app bundle
`Contents/Resources/Runtime/QEMU` → the managed Application Support path →
Homebrew → `PATH`. The app can install a runtime itself; `macportctl runtime install`
does the same from the terminal.

At build time, `scripts/vendor-runtime.sh` copies a locally managed runtime into the
built app and verifies the hypervisor entitlement survived. It exits 0 when no
runtime is present, so a source-only clone still builds. The copy is skipped unless
the source binary actually changed.

## Entitlements by process

The refactor plan separates privilege the way shipping Parallels does; see
`docs/REFACTOR-PLAN.md` §3.2 and `docs/evidence/parallels-refactor-2026-10-19.md`.

| File | Process | Contents |
| --- | --- | --- |
| `Macport/Resources/Macport.entitlements` | GUI | `virtualization`, ordinary networking, audio input |
| `Support/Macport-dev.entitlements` | GUI, local dev | same set, commented for reviewers |
| `MacportCtl/MacportCtl.entitlements` | CLI | no VM grants; it is a control-plane client |
| `Support/MacportVMHost.entitlements` | per-VM host (future) | `hypervisor`; restricted networking/device grants commented until granted |

## Parallel worktrees (refactor workflow)

The Phase 2 refactor is executed in git worktrees so several workstreams can land
without fighting over files:

```sh
git worktree add ../Macport-core-runtime -b core-runtime
git worktree add ../Macport-qemu-control -b qemu-control
git worktree add ../Macport-tools-media  -b tools-media
```

Each worktree needs its own `xcodegen generate` before building. Merge order is
`core-runtime` → `qemu-control` → `tools-media`, with `main` owning `project.yml`
and the entitlement files. After a merge, re-run `xcodegen generate` and the test
command above.
