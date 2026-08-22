# ThinkPad T14 Gen 1 LEN2068 Touchpad Patcher

Keep the Synaptics TM3471-020 / LEN2068 touchpad on its reliable SynPS/2 path.
Version 2 prefers the stock distribution kernel by adding the supported Linux
parameter `psmouse.synaptics_intertouch=0`. It builds a separate source-patched
kernel only when that native route is unavailable or proves ineffective.

Stock distribution kernels are never removed by installation. The same
launcher verifies, retains, and rolls back either method.

## Install the stable v2 release

```bash
git clone --no-checkout https://github.com/RavenWearne/thinkpad-synaptics-patch.git "Touchpad Patcher"
cd "Touchpad Patcher"
git switch --create stable-v2.0.3 v2.0.3
./Run\ Touchpad\ Patcher.sh
```

Use `--verbose` for live command output. Every run retains a timestamped log
under `logs/`. Repository, cache, log, and configuration paths containing
spaces are supported; the documented `Touchpad Patcher` directory is covered
by the integration tests.

## How version 2 works

On every launch the patcher positively identifies a Lenovo ThinkPad T14 Gen 1
and dynamically finds `LEN2068` in the readable serio firmware IDs. It then
inspects the running kernel, current kernel command line, input devices, active
boot chain, existing patcher state, and installed custom kernels. Saved state is
metadata only: the patcher reconciles it against the real persistent boot
configuration before treating a native fix as configured.

The normal lifecycle is:

1. Confirm that the stock kernel exposes the Synaptics `intertouch` parameter.
2. Positively identify the active boot manager and its authoritative settings.
   On UEFI GRUB systems this includes matching `BootCurrent`, the EFI loader and
   vendor directory, the active EFI system partition, and the GRUB stub's
   filesystem UUID/prefix to the generated configuration.
3. Preserve all unrelated arguments and add only
   `psmouse.synaptics_intertouch=0`.
4. Regenerate and inspect the boot configuration.
5. Reboot normally and run the same launcher again.
6. Verify that the parameter reached `/proc/cmdline`, SynPS/2 is registered,
   and the native TM3471 RMI4 input device is absent.
7. Keep the verified fix by pressing Enter, or choose rollback in the same
   launcher.

If the kernel lacks the parameter, the launcher offers the existing guarded
custom-kernel build. If the parameter boots but does not produce the required
device state, the launcher offers to roll it back before starting that fallback.
Unexpected boot-configuration errors stop safely and do not silently trigger a
kernel build.

## Boot-manager support

The patcher detects what is active; it does not assume a boot manager from the
distribution name. This matters on distributions such as CachyOS, which offers
several choices.

- Fedora/RHEL GRUB/BLS: `grubby`
- Debian/Ubuntu/Mint GRUB: `/etc/default/grub` and `update-grub`
- Arch/openSUSE GRUB: the detected GRUB configuration and generator
- systemd-boot: `/etc/kernel/cmdline` and `kernel-install add-all`
- CachyOS systemd-boot: `/etc/sdboot-manage.conf` and `sdboot-manage gen`
- CachyOS Limine: `/etc/default/limine` and `limine-mkinitcpio`
- rEFInd: `/boot/refind_linux.conf`

If several installed boot managers make the active path ambiguous, or an active
UEFI entry belongs to a different GRUB installation, the patcher stops instead
of guessing or editing an inactive configuration. An unknown boot manager does
not automatically cause a kernel rebuild because custom-kernel installation
would face the same unsafe boot integration.

## Native rollback

After successful verification the launcher offers:

```text
Press Enter to keep the native fix, or R to roll it back
```

Rollback removes only the argument managed by this project, restores a
previous explicit `psmouse.synaptics_intertouch=1` when applicable, regenerates
the active boot configuration, and asks for one reboot. Run the launcher after
that reboot to verify the parameter is inactive and clear the managed state.

A safety copy of the edited configuration is created beside it with the suffix
`.touchpad-patcher-v2-backup`; ordinary rollback edits the current file rather
than replacing it wholesale, so unrelated changes made later are preserved.

## Custom-kernel fallback

The fallback retains the v1 source policy change:

1. Install adapter-specific build prerequisites.
2. Resolve the matching stable upstream Linux source release.
3. Benchmark trusted HTTPS kernel.org mirrors and verify the archive against
   kernel.org's published SHA-256.
4. Structurally locate `smbus_pnp_ids` and remove exactly one `LEN2068` entry.
5. Copy the running distribution configuration and build a kernel suffixed
   `-t14-len2068-touchpad-patch`.
6. Install its modules and initramfs alongside every stock kernel.
7. Update the supported boot manager and verify a stock fallback remains.

After booting that kernel, run the launcher again. It verifies SynPS/2 and
offers to keep the kernel or begin rollback. Because a running kernel cannot be
safely removed, rollback records the request, asks the user to boot any stock
kernel, and removes only the custom kernel on the following run.

Secure Boot is compatible with the preferred native route because the signed
distribution kernel remains in use. The fallback refuses to install an
unsigned custom kernel while Secure Boot is enabled.

## Safety properties

The patcher deliberately:

- refuses non-Lenovo, non-T14-Gen-1, non-LEN2068 hardware;
- requires positive kernel-parameter and active-boot-manager detection;
- preserves unrelated boot arguments and avoids duplicate parameters;
- makes native configuration changes idempotent and reversible;
- refuses ambiguous or unknown boot integration;
- never removes a running kernel;
- preserves at least one stock distribution kernel;
- validates downloaded kernel source before building; and
- refuses unknown Synaptics source layouts rather than patching heuristically.

## Advanced commands

The native manager can be audited directly:

```bash
./scripts/t14-ps2-native-manager.sh preflight
./scripts/t14-ps2-native-manager.sh status
./scripts/t14-ps2-native-manager.sh verify
./scripts/t14-ps2-native-manager.sh rollback
```

The custom fallback remains independently usable:

```bash
./scripts/t14-ps2-kernel-installer.sh --dry-run preflight
./scripts/t14-ps2-kernel-installer.sh all
./scripts/t14-ps2-kernel-installer.sh verify
```

The source-only operation remains narrow and idempotent:

```bash
./scripts/t14-ps2-patch-source.sh /path/to/linux
```

## Testing and reports

Fedora's custom-kernel route has been validated end to end. Version 2's native
boot-manager adapters are structurally tested but need broader physical testing
across distributions. Submit sanitized results using the repository's
[distribution test report](https://github.com/RavenWearne/thinkpad-synaptics-patch/issues/new?template=distro-test.yml).

Maintainers can run the regression suite with:

```bash
python3 -m unittest -v tests/test_kernel_arg.py tests/test_dependencies.py
./tests/test_native_manager.sh
./tests/test_launcher_integration.sh
```

See [CHANGELOG.md](CHANGELOG.md) for release changes.
