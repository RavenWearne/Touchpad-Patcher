# Changelog

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
