# Changelog

## Unreleased

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
