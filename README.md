# ThinkPad T14 Gen 1 LEN2068 Touchpad Patcher

Keep the Synaptics TM3471-020 / LEN2068 touchpad on its reliable SynPS/2 path.
Version 3 is machine-aware: it inventories the Linux installations represented
by the authoritative boot environment. It prefers the stock kernel by adding
parameter `psmouse.synaptics_intertouch=0`. It builds a separate source-patched
kernel only when that native route is unavailable or proves ineffective.

Stock distribution kernels are never removed by installation. The same
launcher verifies, retains, and rolls back either method.

## Current validation status

Version 3.2.0 is physically validated end to end on the target hardware with:

- **Fedora Linux 44** — Fedora BLS/grubby native patching, the separate custom
  kernel fallback, SynPS/2 verification, and preservation of stock kernels.
- **Linux Mint 22.3** with kernel `6.14.0-37-generic` — stock-kernel native
  patching, reboot activation, and SynPS/2 verification.
- **Fedora 44 + Linux Mint 22.3 multi-boot** — Fedora-owned EFI/GRUB, Mint
  launched through Fedora's os-prober path, persistent cross-OS remediation,
  generated-entry verification, and verification state shared across Fedora
  and Mint boots.

Debian/Ubuntu, RHEL-family, Arch/openSUSE GRUB, systemd-boot, CachyOS, Limine,
and rEFInd adapters are implemented and regression-tested, but are not yet all
physically confirmed. Unknown or ambiguous boot arrangements stop without
changing configuration.

## Install the stable v3 release

```bash
git clone --no-checkout https://github.com/RavenWearne/thinkpad-synaptics-patch.git "Touchpad Patcher"
cd "Touchpad Patcher"
git switch --create stable-v3.2.0 v3.2.0
./Run\ Touchpad\ Patcher.sh
```

Normal runs show a concise, installation-grouped summary and automatically
apply the native patch once the complete safety preflight succeeds. Use
`--verbose` or `--debug` for the live EFI/GRUB/BLS trace. Every run retains a
timestamped log under `logs/`. Repository, cache, log, and configuration paths
containing spaces are supported; the documented `Touchpad Patcher` directory
is covered by the integration tests.

The routine native patch is automatic only after the patcher proves the
hardware, kernel support, authoritative boot path, persistent configuration
source, affected scope, regeneration method, and generated result. A custom
kernel build remains an explicit, confirmed fallback and never starts because
an otherwise-supported native operation failed unexpectedly.

## Normal user workflow

Run the launcher once in each installed Linux system when asked. It reports:

- the currently running OS and kernel;
- whether a kernel-level or native touchpad patch is active;
- whether live SynPS/2 behavior is verified;
- installation-level status for other detected Linux systems; and
- only the reboot or verification work that genuinely remains.

If everything is patched and verified, no configuration is rewritten. On a
multi-boot machine, successful runtime verification is remembered across boots
so Fedora does not keep asking for Mint verification, or vice versa.

## Detection and remediation model

On every launch the patcher positively identifies a Lenovo ThinkPad T14 Gen 1
and dynamically finds `LEN2068` in the readable serio firmware IDs. It then
inspects the running kernel, current kernel command line, input devices, active
boot chain, existing patcher state, and installed custom kernels. Saved state is
metadata only: the patcher reconciles it against the real persistent boot
configuration before treating a native fix as configured. It also inventories
normal GRUB, os-prober, and Fedora BLS targets using root UUIDs, kernels,
arguments, menu IDs, and live current-system evidence.

Remediation is tracked per installation. A Fedora kernel can be
`kernel-patched` while a Mint os-prober target remains `unconfigured`; a
patched kernel and `psmouse.synaptics_intertouch=0` are compatible. Finding a
patched running kernel records that state and continues machine inspection.

The normal lifecycle is:

1. Confirm that the stock kernel exposes the Synaptics `intertouch` parameter.
2. Positively identify the active boot manager and its authoritative settings.
   On UEFI GRUB systems this includes `BootCurrent`, the EFI loader and active
   EFI system partition, the GRUB stub's filesystem UUID/prefix, and the unique
   generated menu entry matching the running root UUID and kernel.
3. Enumerate logical Linux targets, collapse equivalent normal entries, and
   exclude recovery/rescue entries during a normal boot.
4. Preserve all unrelated arguments and add only
   `psmouse.synaptics_intertouch=0`.
5. Regenerate and inspect the authoritative boot configuration.
6. Apply the proven-safe native patch automatically, then reboot the patched
   installation and run the same launcher again.
7. Verify that the parameter reached `/proc/cmdline`, SynPS/2 is registered,
   and the native TM3471 RMI4 input device is absent.
8. Report configuration and runtime verification separately for each logical
   Linux installation.

Successful runtime verification is recorded per installation in shared machine
state on the active EFI system partition. This lets Fedora remember a verified
Mint boot and Mint remember a verified Fedora boot. The record is metadata
only: it is accepted only while the root UUID, distribution, kernel,
remediation method, active boot chain, and effective boot-target fingerprint
still match. Live evidence for the running system and the authoritative
generated entry for other systems always take priority. A changed kernel,
replaced installation, altered boot entry, changed bootloader chain, or removed
parameter automatically returns that installation to pending or required.

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

The list above describes implemented adapters, not equal levels of physical
validation. Fedora 44 and Linux Mint 22.3 are the confirmed reference systems;
reports from other distributions remain welcome.

The EFI vendor and running distribution may legitimately differ. For example,
Mint can be started by an os-prober entry generated by Fedora's GRUB. The
patcher traces and reports that chain instead of assuming the vendor name is an
error. Equivalent generic/version-specific entries are collapsed by root UUID,
kernel, effective arguments, and menu ID evidence; recovery entries are ignored
unless the current boot is itself a recovery boot. Fedora `saved_entry`/BLS
state is reported separately from the Mint entry that produced the running
system. Because an os-prober menu entry is generated output owned by the other
installation, the patcher never edits it or Mint's inactive GRUB settings.
Fedora's supported `grubby` operation is scoped to Fedora/BLS kernels; it is
not treated as changing foreign os-prober entries. When Fedora owns the
authoritative GRUB, the patcher handles a positively identified Mint target as
separate remediation work: it installs a patcher-owned persistent generator in
`/etc/grub.d`, adds only Mint's filesystem UUID to GRUB's os-prober skip list,
regenerates the authoritative Fedora configuration, and verifies every matching
Mint entry by root UUID and kernel. Generated `grub.cfg` is never edited
directly. Mint is reported as patched only after its effective generated Linux
lines contain the exact argument. Runtime verification remains pending until
Mint is booted. Ambiguous chains and entries stop safely and never trigger an
automatic kernel build.

When a foreign authoritative GRUB entry already contains the parameter, the
booted installation can adopt and verify that result using its exact generated
entry, `/proc/cmdline`, and touchpad devices. The patcher records it as
externally managed: recognition succeeds on Mint, while modification and
rollback remain restricted to the Fedora/bootloader-owning installation.

## Native rollback

Rollback remains available through the native manager's `rollback` action. It
removes only the argument managed by this project, restores a previous explicit
`psmouse.synaptics_intertouch=1` when applicable, regenerates the active boot
configuration, and asks for one reboot. Run the launcher after that reboot to
verify the parameter is inactive and clear the managed state.

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

An OS is reported as **patched** only after its authoritative effective boot
target contains the required remediation. It is reported as runtime-verified
only after that OS has actually booted and live input evidence confirms SynPS/2
with the native TM3471 RMI4 input absent. Cached state is never allowed to
override either result.

## Advanced commands

The native manager and machine inventory can be audited directly:

```bash
./scripts/t14-ps2-native-manager.sh preflight
./scripts/t14-ps2-native-manager.sh inventory
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

Submit sanitized results from additional distributions using the repository's
[distribution test report](https://github.com/RavenWearne/thinkpad-synaptics-patch/issues/new?template=distro-test.yml).

Maintainers can run the regression suite with:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
./tests/test_native_manager.sh
./tests/test_launcher_integration.sh
```

See [CHANGELOG.md](CHANGELOG.md) for release changes.
