# Changelog

## 3.0.0

- Add a machine inventory covering the authoritative GRUB environment,
  os-prober targets, and Fedora BLS entries instead of stopping at the current
  operating system.
- Track kernel remediation, native configuration, and runtime evidence per
  logical installation; non-running systems remain pending verification.
- Treat a LEN2068-patched kernel and `psmouse.synaptics_intertouch=0` as
  compatible layers, preserve existing kernels, and continue inspection when
  the current Fedora kernel is already patched.
- Identify a running Fedora BLS target even when it has no literal `menuentry`
  in generated `grub.cfg`.
- Keep Fedora `grubby` changes scoped to Fedora/BLS kernels and never claim
  they also change generated Mint/os-prober entries.
- Preserve v2.0.8 BootCurrent tracing, privileged ESP access, EFI path case,
  read-only temporary mounts, equivalent-entry collapsing, recovery exclusion,
  stale-state reconciliation, rollback, and guarded fallback semantics.
- Add machine-level regressions for Fedora BLS plus Mint os-prober, equivalent
  and materially different entries, recovery exclusion, exact argument
  matching, and patched-kernel/native coexistence.

## 2.0.8

- Collapse generic and version-specific GRUB menu entries into one logical
  current-system target when root UUID, kernel, and effective kernel arguments
  are equivalent, using shared menu IDs as supporting evidence.
- Exclude recovery/rescue entries during a normal boot and select them only
  when the running command line indicates recovery mode.
- Preserve ambiguity failures for matching entries with materially different
  kernel arguments.
- Read Fedora `grubenv` saved/default state separately from current-system entry
  identification and recognise saved entries backed by BLS files without
  requiring a literal `menuentry` in `grub.cfg`.
- Expand the physical Fedora-GRUB-booting-Mint fixture to include duplicate
  normal entries, a recovery entry, and an independent Fedora BLS saved target.

## 2.0.7

- Handle `findmnt` status 1 as the expected “valid active GRUB filesystem is
  not currently mounted” result instead of allowing `set -e`/`pipefail` to
  terminate boot-chain tracing.
- Reuse an existing mount when present; otherwise create a controlled mount
  under `/run/t14-len2068-touchpad-patch`, mount the traced device read-only,
  and inspect the downstream GRUB configuration there.
- Treat genuine `findmnt` errors and read-only mount failures as explicit fatal
  native-route errors without starting the custom-kernel fallback.
- Preserve the original process status while cleaning temporary mounts on
  success, failure, HUP, INT, and TERM, and report unmount/mount-point cleanup.
- Extend the Fedora-GRUB-booting-Mint fixture with mounted, unmounted,
  mount-failure, `findmnt`-failure, and signal-cleanup regressions.

## 2.0.6

- Perform ESP traversal, EFI loader/stub checks, GRUB filesystem discovery,
  downstream configuration checks, and bootloader reads through the privileged
  execution path established at launcher startup.
- Use privileged checks and reads consistently for `/etc` boot settings,
  generated boot entries, backups, `grubby`, and patcher state under `/var/lib`.
- Distinguish a genuinely absent privileged path from a path that could not be
  inspected with administrator privileges.
- Add restrictive-ESP and root-only GRUB fixtures proving that an ordinary user
  cannot traverse the chain while privileged tracing succeeds.
- Exercise privileged read-only mount/unmount handling through the permanent
  Fedora-GRUB-booting-Mint fixture and retain stale-state/no-fallback checks.

## 2.0.5

- Preserve the exact case of the EFI loader path reported by `efibootmgr` when
  accessing the EFI system partition; use a separate lowercase value only for
  boot-manager classification and vendor comparisons.
- Fix physical tracing of `/EFI/fedora/shimx64.efi` and its neighboring
  `grub.cfg` on case-sensitive EFI mount views.
- Audit the UEFI/GRUB tracer so case-folded filesystem paths are never used for
  real file access.
- Extend the permanent Fedora-GRUB-booting-Mint fixture with uppercase and
  mixed-case EFI path components while retaining the full UUID, os-prober,
  root/kernel, stale-state, and no-fallback checks.

## 2.0.4

- Trace UEFI GRUB through `BootCurrent`, the active EFI loader/stub, its
  filesystem UUID and prefix, and the downstream `grub.cfg` instead of assuming
  that the EFI vendor owns the running distribution.
- Identify the exact generated menu entry for the running root filesystem UUID
  and kernel, including Mint booted through Fedora GRUB and the inverse
  cross-distribution arrangement.
- Recognise os-prober-generated entries as legitimate active boot paths while
  refusing to edit generated foreign configuration or an inactive local
  `/etc/default/grub`; report how to remediate it in the bootloader-owning OS.
- Reconcile pending native state against the exact active entry, so a token in
  another GRUB installation cannot preserve stale state or pass verification.
- Add the physically reproduced Fedora-GRUB-to-Mint chain as a permanent test
  fixture, plus entry ambiguity, wrong-root/token, inverse ownership, and
  no-fallback safety coverage.

## 2.0.3

- Reconcile saved native state with the authoritative persistent boot
  configuration, clearing stale pending/configured metadata when the managed
  argument has been removed outside the patcher.
- On UEFI GRUB systems, bind installation and generated-config verification to
  the current firmware boot entry, EFI loader/vendor, active EFI system
  partition, and the GRUB stub's filesystem UUID and prefix.
- Stop safely before modifying GRUB when `BootCurrent` is missing, ambiguous,
  belongs to another distribution's GRUB installation, or cannot be traced to
  the generated configuration; never start the kernel fallback for these
  native-route errors.
- Add physical-flow regressions for stale-state recovery, multiple EFI GRUB
  installations, inactive generated configurations, ambiguous boot chains,
  and successful install/post-reboot verification through the correct chain.

## 2.0.2

- Verify generated GRUB kernel command lines through an administrator-readable
  configuration stream, fixing false failures when Mint protects
  `/boot/grub/grub.cfg` from ordinary users.
- Distinguish missing GRUB output, privileged read failures, and readable
  output that lacks the exact `psmouse.synaptics_intertouch=0` kernel argument.
- Add regressions for root-only GRUB configuration, exact generated `linux`
  argument matching, and fail-closed verification errors.

## 2.0.1

- Fix native-manager execution when the repository path contains spaces,
  including the documented `Touchpad Patcher` clone directory.
- Add physical-flow regression coverage for Linux Mint 22.3 with GRUB:
  native application, existing native state, rollback, unsupported fallback,
  and unexpected application failure without automatic fallback.
- Lock down fallback-only dependency gating and require `gawk` plus the audited
  archive/build command set before reporting build readiness.

## 2.0.0

- Prefer the stock distribution kernel with
  `psmouse.synaptics_intertouch=0`; no compilation is needed when supported.
- Detect the active boot manager rather than inferring it from the distribution.
- Add guarded adapters for GRUB/grubby, systemd-boot, CachyOS
  `sdboot-manage`, Limine, and rEFInd.
- Verify the active method on the next run and offer an integrated rollback.
- Retain the source-patched custom kernel as a fallback when the running kernel
  does not expose the native parameter or native verification fails.
- Add reboot-spanning custom-kernel removal through the same launcher.
- Preserve unrelated boot arguments and remember a displaced explicit
  `psmouse.synaptics_intertouch=1` for rollback.

## 1.1.1

- Completed dependency preparation, verified kernel.org downloads, improved
  GRUB integration, diagnostics, and release checkout instructions.
