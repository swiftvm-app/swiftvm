# Windows GPU: deferred work and crash handoff

## Scope and decision

Windows GPU acceleration remains **experimental, enabled by default for new
Windows guests**. The user explicitly chose this policy and asked to finish
this PR without implementing the remaining fixes below. Default-on does not
mean stable, certified, or fully validated. Do not remove the experimental
warning on the strength of a working desktop or the focused test passes.

The app diff is based on `0dd22177e0fb5a4b6f1078469b886c671f23c953`.
This report accompanies the app diff despite the repository's existing
`.plans/` ignore rule. The supporting `windows-gpu-leftover/` candidate patches
remain local and are **not included in the PR**; their preserved locations are
listed below. Transfer those artifacts separately before attempting an
independent prototype reproduction. No driver submission or release was made.

### Included in the app changes

- The normal QEMU build includes DXMT and the existing signed Windows GPU
  package. `SWIFTVM_QEMU_DIRECT3D=0` explicitly leaves them out without disabling
  Linux acceleration.
- The existing setup/tools installer supplies the driver. A driver-ready guest
  selects `virtioGPU3D` on its next cold boot. Setup stays on the firmware
  framebuffer until then. Existing display-only guests are not silently
  migrated; explicitly updating guest tools can replace their display driver.
- Runtime/driver selection and framebuffer fallback have critical-path coverage.
- DXMT's shared-resource initialization fix addresses the observed missing-text
  race; the companion patch adds native texture regression cases.
- The SPICE input-lifetime fix prevents the observed use-after-free during QEMU
  shutdown. A separate QEMU blob-mapping patch and Windows agent fractional-DPI,
  exact-raster/retry changes are included.
- Public docs describe experimental default-on behavior, the build opt-out,
  fallback, crash/rendering risks, Retina limitations, and no accelerated
  suspend/live snapshots. `_dxmt.log` is ignored.

### Two different stacks: do not confuse them

The reproducible repository-pinned build still uses **wire protocol 1 / signed
v0.3 driver**, with the host fixes above. `Native/QEMU/sources.tsv` is unchanged:

| Component | Repository pin |
| --- | --- |
| virglrenderer | `5d26f605f50f8e22002ec6db5fb775e1992d4e96` |
| DXMT | `917b721c0f915c6524b416169fdce4427a39524f` |
| Driver ZIP | `osy/kvm-guest-drivers-windows`, `v0.3` |
| Driver ZIP SHA-256 | `af976d1fc6cbd1c8462ba06a45f860ae1638d9a6a007e2bfe95bb9b235251c5d` |

The now-deleted **Windows-GPU-Driver preview** used a manually assembled
**wire 2 / v0.4 stack with HostBridge5 native ARM64 user-mode changes**. Its
focused test results are not evidence that a clean repository build contains
that prototype. The broad crash reproduction below targets that precise stack,
which must now be recreated in a new disposable guest. Do not mix wire-1 and
wire-2 host/guest components.

The unintegrated synchronization prototype is preserved in
`windows-gpu-leftover/{mesa,host,dxmt}.patch`, with `bases.json`. The DXMT snapshot
already includes the initialization fix: do not blindly stack it on top of the
repository's initialization patch. The unsigned kernel proposal was moved out
of `Native/QEMU` into `windows-gpu-leftover/viogpu3d-fence-preemption.patch`; it
is not applied to or packaged as a fix for the downloaded signed binary.

## Final cleanup and persistent evidence

The user's final cleanup request superseded the earlier request to leave a
visual-check VM running. All six agent-created VMs were stopped and their
complete bundles **permanently deleted**, not moved to Trash:

| Deleted VM | UUID |
| --- | --- |
| Windows-GPU-Verification | `77C1A4DD-EAC2-4E2C-A72F-9A8541EE9B49` |
| Windows-GPU-Fresh | `00EC74AA-E278-4CC0-BD66-F8A505733BAB` |
| Windows-GPU-Setup | `5C634282-B9FC-4C0E-9BA6-8C4892BAC168` |
| Windows-GPU-Driver | `86874382-9CB7-4139-B35B-0093BB0E3CFB` |
| GPU Visual Demo | `12ECED0F-70ED-434A-80C8-AB2324C13BE9` |
| Rosetta Suspend Demo | `D5DCBB70-157D-4640-8290-D9702C805BC0` |

The isolated library indexes are empty, and no `.swiftvm` bundle remains in
the preservation folder. The development app exited after its guests stopped;
no development app, QEMU or renderer process remains. The regular
`/Applications/SwiftVM.app` and user VMs were not modified or stopped.
`Checks/deleted-test-vms.json` records the allowlisted paths, UUID checks and
verified deletion. No VM disk backup or runnable preview guest was retained.

Unique source changes and diagnostic evidence were preserved outside `.build`
before deletion. The remaining locations are:

```text
~/Applications/SwiftVM GPU Preview.app          stopped prototype app
~/Library/Application Support/SwiftVM-GPU-Development/
    Home/                    empty isolated library, no VM disks
    Runtime/                 manually assembled wire-2 preview runtime
    DefaultRuntime/          repository-pinned wire-1 runtime
    Sources/mesa/            actual checkout, .git and local changes
    Sources/kvm-guest-drivers-windows/
    NativeBuild/             preserved native sources, archives and build tree
    Archive/                 logs, dumps, reviews, unsigned packages, old probes
    Checks/                  final checks, screenshots and cleanup manifest
    DeferredPatches/          copies of local, unapplied candidate patches
    relocation.json          historical move record, not current VM availability
    verified-artifacts.json  verified critical artifact SHA-256 values
```

The legacy demo's remaining archive contains diagnostic records, not VM disks.
Historical records retain their original `.build` paths and can describe guests
that no longer exist. `NativeBuild/` preserves sources and outputs, but generated
build files can contain old absolute paths; reconfigure rather than treating
the moved cache as portable. The preview app/runtime has no dylib load dependency
on `.build`. Deleting `.build` will not delete unique investigation material;
do not delete this preservation folder or the local candidate patches with it.

Before cleanup, the preview passed exact **2560×1440** desktop/output raster and
**200% Windows DPI** checks with automatic resizing disabled. The Mac session
exposed a **1920×1080, 1× display**, so physical Retina quality was not visually
verified. These are historical results, not an available visual-check VM.
Future test guests must use exactly **`username` / `password`** and an isolated
`SWIFTVM_HOME`. Stop all guests before quitting or replacing a development app.

## Main crash: Windows invalid completed-fence notification

### Observed failure

Six collected minidumps have the same bucket:

```text
VIDEO_SCHEDULER_INTERNAL_ERROR (0x119)
Arg1 = 1: The driver has reported an invalid fence ID.
0x119_1_DRIVER_REPORTED_INVALID_FENCE_ID_dxgmms2!VidSchiProcessIsrCompletedPacket
... dxgkrnl!DxgNotifyInterruptCB -> viogpu3d+0x8ff0
```

Example: `101826-2656-01.dmp` has `Arg2=0x25de`, `Arg3=0x25df`, with a
system uptime of approximately 82 seconds. Other dumps have different fence
values and the same failure class. A broader repeated graphics run completed
only **1 of 33 scheduled tests** before the guest connection was lost and
Windows bugchecked. This is not a 33-test pass or just a slow test timeout.

Environment of the prepared reproduction:

- Apple silicon, macOS 27; QEMU 11.1.2 with HVF and 4 KiB IPA granules;
  `virtio-ramfb-gl`, `blob=true`, 8 GiB host memory aperture, Neptune enabled.
- Windows 11 Pro for Arm, reported build `26300.9711`, 4 vCPUs / 8 GiB RAM.
- Original Microsoft-signed `viogpu3d.sys`, version `100.6.101.58000`, SHA-256
  `CFBC713754C7F0DCAE4803017AF3A0EBFC781D37FD57604F8EE8F2CFDAD306C4`.
- Driver Store path:
  `C:\Windows\System32\DriverStore\FileRepository\viogpu3d.inf_arm64_d990ba3bca64b8b0\viogpu3d.sys`.
- HostBridge5 native ARM64 `neptune_umd.dll`, SHA-256
  `A9E7EE3D91786DD81BFF388855C47DEDE5AABCA2FE5BED7C4405BA738E9A7301`;
  ARM64EC/wrapper payload still comes from the earlier development package.
- Preview machine's global TDR/preemption overrides were removed; Windows
  timeout/preemption defaults are in effect. Test scheduling is enabled only
  for the test process, not globally for the desktop.
- The test VM had Secure Boot off because SwiftVM does not supply it;
  this is not a Secure Boot validation. Test-signing/code-integrity bypasses
  were not enabled to load the proposed fix.

### Reproduce after recreating the disposable environment

This sequence can crash Windows. The prepared guest has been permanently
deleted; the commands below record the failing run and do not prepare a clean
Windows installation. First recreate the environment listed above from the
preserved matching host/guest sources and artifacts, including Python at
`C:\BuildPython`, the Mesa checkout at `C:\Mesa` and its `build-arm64` test build.
No VM disk image is retained to shortcut that setup. These prototype artifacts
are local, not supplied by the app PR.

1. Cold-boot the recreated wire-2 guest with the matching HostBridge5 stack. Log in as
   `username`. Do not live-restart the display adapter or install the unsigned
   kernel candidate.
2. In the logged-in user's PowerShell session (**not SYSTEM / CLI `--root`**),
   run:

   ```powershell
   $ErrorActionPreference = 'Stop'
   $env:SWIFTVM_WDDM_SCHEDULE = '1'
   $env:NPT_TEST_UMD_SHA256 = 'A9E7EE3D91786DD81BFF388855C47DEDE5AABCA2FE5BED7C4405BA738E9A7301'
   & C:\BuildPython\python.exe -m mesonbuild.mesonmain test `
       -C C:\Mesa\build-arm64 --suite hardware --repeat 3 `
       --no-rebuild --print-errorlogs
   ```

   The suite schedules 33 checks. The recorded failing run stopped after its
   first presentation test. Exact timing/order is nondeterministic; a short
   pass does not establish stability. Session 0 can instead fail D3D creation
   with `0x887a0004`, which is not the kernel bug being reproduced.
3. After Windows restarts, inspect `C:\Windows\Minidump` and System event 1001.
   Save the guest Meson logs from `C:\Mesa\build-arm64\meson-logs` and the host
   QEMU log. Loss of the CLI connection alone is insufficient to identify the
   bugcheck.
4. Open the new minidump in WinDbg/CDB with Microsoft symbols and run
   `.symfix; .reload; !analyze -v; .bugcheck; kv`. Match `0x119`, parameter 1
   equal to 1, the failure bucket and `viogpu3d` in the interrupt stack.

Preserved evidence under `Archive/`:

- `windows-gpu-hostbridge5-hardware.log`: focused pass followed by interrupted
  repeated hardware run.
- `windows-gpu-kernel-cdb-latest-analysis.log` and
  `windows-gpu-kernel-cdb-analysis-recovered.log`: six dump analyses.
- `windows-gpu-kernel-dumps-framebuffer/`: collected dumps.
- `windows-gpu-kernel-fence-disassembly.log` and
  `windows-gpu-kernel-fence-context.log`: binary/source diagnosis.

### Diagnosis and suggested fix (deferred)

`PreemptAckLocked` promotes the preemption skip-window base into
`m_LastCompletedFenceId`, even though those packets were preempted/re-owned,
not executed. A later notification or `QueryCurrentFence` can therefore report
an invalid completed fence. Keep **actual completed DMA progress** separate
from **the skip window used to ignore stale packets**. Do not retire work just
because it was skipped or preempted.

The preserved candidate removes that promotion, retains the skip-window
behavior, and extracts the real production fence routines into `viogpu_fence.h`
so the regression test exercises the same code. It covers repeated preemption,
stale completions, later progress, deferred monitored-fence write ordering, and
reset cleanup. The baseline failed and the candidate passed the focused
sanitizer/release/native ARM64 checks. An ARM64 driver build also completed.
**The modified kernel has not been installed or hardware-validated.** This
candidate is not evidence that all scheduler defects or all crashes are fixed.

Next work, in order:

1. Rebuild the complete matching package from pinned sources, including native
   ARM64 and ARM64EC payloads; avoid mixing development binaries.
2. Review the candidate fence fix against the WDDM completion/preemption
   contract, including paging queues, reset and teardown (see the audit list).
3. Obtain a new legitimate Microsoft signature for the modified kernel/package,
   through SwiftVM's authorized Hardware Dashboard account or upstream. The
   original signature does not cover modified SYS/INF/CAT contents.
4. Install only that correctly signed package in a disposable guest, keeping
   integrity enforcement and Windows GPU recovery enabled. Repeat the exact
   stress reproduction, then broaden lifecycle/graphics testing.
5. Only after those gates, integrate/version the matching host and guest
   protocol and consider changing the experimental status.

### Signing material, not a signed fix

Existing upstream signed drivers need **no new SwiftVM signing enrollment** to
use. New signing is needed only to distribute/load the modified kernel package
without weakening Windows integrity. Signing does not itself fix correctness.
No account was created, agreement accepted, certificate bought, or package
submitted. Enrollment was paused at the user's request.

`Archive/windows-gpu-arm64-validation-unsigned.cab`:

- CAB SHA-256: `236579cdb0bd9b9a64ae5a6c30fe8de218480673dc3a51bb980efa0ee44b7565`.
- Candidate SYS SHA-256: `C3D8E52FCDFCBA414760DE9AFEE9B33086FDA4B48648D6DBD27C9F273B06823A`.
- Candidate SYS and regenerated CAT are **unsigned**.
- `Inf2Cat /os:10_GE_ARM64` reported no signability errors/warnings. This is not
  certification of the installed Windows preview build, WHCP/HLK approval, or
  successful driver loading.
- Manifest, PDB/build evidence, original unsigned ZIP and owner checklist are
  preserved in `Archive/`; see `windows-gpu-signing-setup.md` and
  `windows-gpu-handoff-client-cab.log`.
- Desktop ARM64 attestation is a testing route; production certification and
  retail Windows Update have separate WHCP/HLK requirements. Recheck Microsoft's
  current [signing offerings](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/driver-signing-offerings)
  and [registration requirements](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/hardware-program-register)
  before submitting.

## Additional confirmed host crash in the normal pinned build

During finalization on 2026-10-18, the normal default build was rebuilt with
`SWIFTVM_QEMU_DIRECT3D` unset. The manually edited DXMT and virglrenderer trees
were reconstructed from the repository's pinned inputs first; this was not
the HostBridge5 prototype runtime. The bundle contains the v0.3 driver ZIP
with the checksum above and DXMT.

`Windows-GPU-Verification` booted with `virtioGPU3D`. A normal-user
`D3D11CreateDevice` call using `D3D_DRIVER_TYPE_HARDWARE` succeeded with feature
level **0xB000 (11_0)**, wire **0x00000001**, and the display driver reported
**Status OK / Code 0**. Windows Display Settings opened, and a screenshot was
saved. However, the subsequent graceful `swiftvm stop` ended in a host QEMU
abort, not a successful lifecycle check:

```text
Assertion failed: (isv), function hvf_handle_exception, file hvf.c, line 2464.
EXC_CRASH / SIGABRT; Abort trap: 6
... __assert_rtn -> hvf_arch_vcpu_exec ...
```

The CLI reported that QEMU stopped unexpectedly. The guest then appeared
stopped and no QEMU process remained. This reproduces the previously observed
HVF assertion class with the **normal pinned experimental default**, not just
the newer prototype. It is distinct from the Windows kernel 0x119 crash and
from the fixed SPICE input use-after-free. The new abort was recorded rather
than debugged or patched, as requested.

Recorded sequence (not a minimized or repeatedly validated reproducer):

The original `Windows-GPU-Verification` guest is now deleted. To repeat this
sequence, first create a disposable wire-1 Windows guest using the pinned
runtime and signed v0.3 package; use the preserved configuration as a reference.
The configuration and probe are not a VM disk image or an unattended rebuild.

1. Stop any other development guests and quit their app. Launch the preserved
   `Archive/SwiftVM Pinned Default Check.app` with an isolated `SWIFTVM_HOME`.
   **Do not start any wire-2 guest in this app.**
2. Start and wait for the recreated wire-1 guest. In its logged-in normal-user
   session, run `Checks/pinned-default-smoke.ps1` from the host
   preservation folder via `swiftvm exec` / PowerShell `-EncodedCommand`. The
   preserved source contains the exact hardware-device probe and opens Display
   Settings. Running as SYSTEM is not equivalent.
3. Capture the screen, then issue `swiftvm stop <guest-name>`; the recorded run
   used `Windows-GPU-Verification`.
4. Inspect the QEMU log and macOS DiagnosticReports. The observed finalization
   abort is `qemu-system-aarch64-2026-10-18-095408.ips`.

Evidence is preserved under `Checks/`: `pinned-default-guest.log`,
`pinned-default-config.json`, `pinned-default-guest.png`,
`pinned-default-qemu.log`, the exact PowerShell smoke source, and the `.ips`
report. The matching bundled app and `DefaultRuntime/` were retained outside
`.build`. The separate wire-2 visual preview was restored for a final check,
then all test guests were deleted and the development app stopped as requested.

Suggested follow-up: reproduce the HVF MMIO/data-abort path with registers and
syndrome captured at `ISV=0`, and determine the correct emulation/guest-abort
behavior rather than merely removing the assertion. Review the already
preserved candidate against QEMU/HVF semantics before considering it. No
claim is made that that candidate fixes this crash.

## Other deferred work

| Priority | Leftover / evidence | Suggested next step; not implemented here |
| --- | --- | --- |
| High | Signed v0.3 **and** v0.4 INF packages set global `EnablePreemption=0` and `TdrDebugMode=1`. The original signed packages are unchanged. Only the Driver preview had those overrides removed manually. | Publish a newly signed INF without these settings, then design a migration that preserves user-owned registry values. Do not silently remove arbitrary existing values. |
| High | Prototype Mesa/virglrenderer/DXMT scheduling is not part of the normal build; the desktop does not globally opt into `SWIFTVM_WDDM_SCHEDULE`. | Finish one versioned host/guest protocol and build/package the matching components together. Update both host `libvirglrenderer.1.dylib` and the statically linked `virgl_render_server`. |
| High | Clean ARM64EC source build failed (`VsDevCmd` architecture handling / Meson `LNK1392`). The preview mixes new native ARM64 with older wrapper/EC payloads; no x86 candidate was produced. | Fix the supported toolchain/build definition, not generated Ninja flags; validate the whole advertised application-architecture matrix. |
| High | Scheduler audit is incomplete: paging-fence ID reuse/skip-window behavior, 256-entry overflow/early retirement, reset watermarks, teardown/global completion, OOM early-success paths, and Present timeout retirement. These are audit risks, not all separately reproduced crashes. | Audit ownership and real-completion invariants with targeted failure/lifecycle tests after the primary bugcheck fix. |
| High | Host/device-loss and protocol hardening remain incomplete: `GetDeviceRemovedReason` can return a stub `S_OK`; SHM ownership/aliasing, atomic initialization, partial submission/cancellation and capability negotiation need review. Capability bit 8 can be advertised without the required DXMT export, although BIND checks it. | Fail closed on missing capabilities/device loss; complete the guest-to-host trust/lifetime audit before calling the stack stable. |
| High | Host HVF assertion was observed: `Assertion failed: (isv), function hvf_handle_exception, file hvf.c, line 2464`, syndrome `0x92000046`, `gpex_mmio_window` (PC `0x7ffb355ed528`, VA `0x247535201c4`, IPA `0x81004011c4`). | Reproduce and investigate the MMIO/data-abort path. `Archive/windows-gpu-hvf-data-abort-candidate.patch` is an unproven proposal, not an applied fix. |
| Medium | Arbitrary display modes fail: 2614×1578, 2600×1576 and 2796×1696 can be substituted by 1920×1440; a 1280×780 window request also failed. Supported 2560×1440 and 1920×1440 at 200% passed. | Reproduce with the archived Retina probes; investigate KMD mode enumeration/notification. `UpdateChildStatus` deduplicates TRUE→TRUE and `ConfigChanged` may update modes without notifying Windows. These are suspected causes, not a completed diagnosis. Verify exact source and target rasters on real 1×/2× displays. |
| Medium | Missing-text initialization regression is fixed in the host patch and focused A8/RGBA tests, but general text/rendering correctness is not proven. Settings screenshot/OCR checks are limited evidence. | Test real DWM/DirectComposition content and resource lifetime under sustained load after synchronization is sound. Do not claim screenshot success proves all rendering correct. |
| Medium | Live display-adapter restart with HostBridge3 caused DWM/SearchHost/ShellExperienceHost/WidgetBoard `0xc0000005` failures (native offset `0xa744`). | Use cold boots for recreated test guests. Validate adapter reset/device-loss recovery later; do not reuse the old `windows-gpu-restore-original.ps1` blindly. |
| Medium | SPICE input use-after-free is fixed and hardware shutdown/restart passed, but `surface 0 is NULL`, double primary-surface destruction and thread-ID warnings remain. Renderer logs also mention a missing `dxmt_open_existing_heap_from_fd` export and unimplemented calls. | Separate and reproduce remaining display teardown/export-contract issues; preserve the current lifecycle regression test. |
| Medium | Agent reports accelerated-driver capability from Driver Store INF presence, not successful UMD loading or wire/runtime health. | Add a versioned guest/host health handshake before stronger automatic driver migration or capability guarantees. |
| Medium | No full upstream/fork provenance and security audit was completed. The Windows Neptune/Triton stack is a Mesa-derived fork, **not simply unmodified upstream Mesa** at `gitlab.freedesktop.org/mesa/mesa`. Star counts do not establish provenance or quality. | Trace exact source/binary ancestry, licenses and local changes; decide maintenance ownership from that audit, not repository popularity. VMPal license/source inspection did not copy or execute VMPal binaries. |
| Medium | Linux GPU hardware regression and the full graphics/lifecycle matrix remain incomplete. | Check Linux's existing default acceleration, Windows install/tools upgrade/fallback, shutdown/reboot, display changes, application architectures and long-running graphics before graduation from experimental. |
| Low | The full SwiftVMKit test run intermittently failed the unchanged RFB disconnect timeout at `ProtocolTests.swift:349`, while the focused rerun passed. | Track separately; do not change unrelated RFB code as part of this GPU finalization. |

## Verification boundaries

Before finalization, the recorded checks included:

- Native shared-import, scheduler/failure and real presentation checks: **3/3
  passed**, including 64 blt and 64 flip frames across swapchain recreation.
  The scheduler tests cover 46 fault cases. The broader 33-check run crashed.
- SPICE ASan/UBSan channel tests **2/2** and lifetime/leak cases **4/4** passed;
  a real GPU shutdown/restart produced no new QEMU crash report.
- Exact fixed 2560×1440 source/output raster and 200% DPI passed. Automatic
  arbitrary resizing and physical Retina visual quality remain unverified.
- App/CLI/agent builds passed; app tests **40/40** passed. Focused QEMU/RFB
  tests **24/24** passed; the full kit run had the RFB timeout described above.
- Kernel candidate's focused regression and build passed, **not** signed-driver
  loading, corrected-driver hardware stress, or production certification.

Finalization checks on 2026-10-18:

- Normal pinned QEMU build, with no Direct3D override: **passed**; DXMT and the
  pinned signed v0.3 ZIP are present in the bundled app. Native dependency builds
  still emit upstream/environment warnings (including a missing Homebrew Ruby
  library search path); they were not addressed here.
- App, CLI and guest-agent Swift builds: **passed**, without Swift warnings.
  Bundle code-signature verification: **passed**.
- Focused critical-path checks: **24/24 passed**. App tests: **40/40 passed**.
  Full SwiftVMKit run: **370 tests across 11 test-target summaries passed**.
  The earlier RFB timeout remains a recorded intermittent failure, not a failure
  of this final run.
- Matching wire-1 Windows guest: GPU adapter selection, driver health, and a
  real hardware D3D11 device **passed**. Shutdown **failed with the HVF abort**
  above. A fresh unattended Windows installation was not rerun in this final
  pass, and this is not a successful end-to-end lifecycle/stress result.
- Before cleanup, the separate wire-2 `Windows-GPU-Driver` preview was restored
  with a healthy GPU, fixed 2560×1440 display and Display Settings open. The
  relocated preview passed the exact source/output raster and 200% DPI query;
  its active processes had no open files mapped from `.build`.
- Final cleanup: all six agent-created VM bundles were permanently deleted,
  isolated library indexes are empty, and no development process remains.
  Logs, screenshots, sources and unsigned candidate artifacts were retained,
  not VM disks. The regular installed app and its user VMs were left alone.

Logs and screenshots are in the persistent `Checks/` directory. The final
review is against an immutable patch, with any later documentation additions
reviewed separately. Do not reinterpret these bounded checks as an all-green
stability result. No visual preview VM or stress reproduction is left running,
and recreating a guest is required for any further hardware validation.
