# ThinkPad T14 Gen 1 LEN2068 Touchpad Patcher

Build and install a distinctly named Linux kernel that keeps the Synaptics
LEN2068 touchpad on its reliable SynPS/2 path instead of automatically handing
it to RMI4/SMBus. Stock distribution kernels remain installed as fallbacks.

The repository contains only the portable launcher and patching tools. Kernel
sources and build products are downloaded or created locally and are never
stored in Git.

## Reusable cross-distribution installer

`scripts/t14-ps2-kernel-installer.sh` reproduces the validated source policy
change on a fresh installation without adding a permanent kernel command-line
option. It has adapters for Fedora/RHEL, Debian/Ubuntu, Arch and openSUSE, plus
a conservative `kernel-install` fallback.

### Clone and run

Clone the Fedora-validated `v1.0.0` release on the target machine, then run the
executable top-level launcher:

```bash
git clone --no-checkout https://github.com/RavenWearne/thinkpad-synaptics-patch.git "Touchpad Patcher"
cd "Touchpad Patcher"
git switch --create stable-v1.0.0 v1.0.0
./Run\ Touchpad\ Patcher.sh
```

This sequence never checks out `main`. It creates a normal local branch from
the known-good `v1.0.0` release, avoiding detached-HEAD warnings. Other
published versions are available from
[GitHub Releases](https://github.com/RavenWearne/thinkpad-synaptics-patch/releases).

The following command is only for contributors who intentionally want the
latest unreleased development version from `main`:

```bash
git clone https://github.com/RavenWearne/thinkpad-synaptics-patch.git "Touchpad Patcher Development"
```

It requests sudo once, keeps that authentication alive during compilation,
derives the current upstream kernel series, and checks for both the matching
custom kernel image and module tree. If the current series is already patched,
it reports completion, restores that image as the default where `grubby` can
verify it, and verifies SynPS/2 when already booted into it. Otherwise it calls
the guarded installer to perform the complete build and installation. An older
patched kernel does not suppress rebuilding after a later kernel-series update.
When opened from a graphical file manager, the same file relaunches itself in
Konsole, GNOME Terminal or `x-terminal-emulator` so sudo can request a password.
Both the already-patched and newly-installed success paths finish with an
explicit success message and wait for a keypress before closing the terminal.
After sudo authentication, the launcher reports the detected distribution,
selected adapter, expected compatibility likelihood and missing adapter tools.
Output is captured temporarily while the launcher runs. Successful and
already-patched outcomes discard that capture and do not mention logging.
Failures retain the capture as a timestamped file in `logs/`, display its exact
path and wait for a keypress, making the report straightforward to return for
investigation.

To build and install after reviewing the detected hardware, source version,
kernel configuration and boot tooling:

```bash
./scripts/t14-ps2-kernel-installer.sh all
```

After rebooting into the distinctly suffixed kernel, verify the transport:

```bash
./scripts/t14-ps2-kernel-installer.sh verify
```

The installer deliberately:

- dynamically searches readable serio firmware IDs for `LEN2068`, reports the
  matched device, and refuses non-Lenovo or unmatched machines before building;
- structurally inspects `smbus_pnp_ids`, patches exactly one `LEN2068` entry,
  recognizes previously patched trees, and treats kernels that never forced
  that ID as already safe;
- refuses unsigned installation while Secure Boot is enabled;
- copies the running distribution kernel configuration;
- clears unavailable distribution-private certificate paths and disables only
  optional BTF metadata when `pahole` is absent;
- gives new kernels the descriptive, unnumbered
  `-t14-len2068-touchpad-patch` suffix;
- never removes a distribution kernel;
- stops short of claiming default selection when the active bootloader cannot
  be verified safely; and
- refuses to uninstall the currently running kernel.

Use `--kernel X.Y.Z` when the running distribution release does not map to the
desired upstream source version. Use `--source DIR` for a pre-downloaded kernel
tree. The source-only operation is separately auditable and idempotent:

```bash
./scripts/t14-ps2-patch-source.sh /path/to/linux
```

The automated build supports stable upstream Linux 4.x and newer on x86-64
when the source retains the Synaptics `smbus_pnp_ids` structure. This is tested
by inspecting the supplied source, not by hard-coding one kernel release. An
unknown driver layout is refused rather than modified heuristically.

Kernel updates do not inherit an out-of-tree source change. Re-run the tool for
the desired new upstream version, keep at least one stock kernel as fallback,
and test the new build before removing an older custom build.

### Portability boundary

The patch is kernel-source portable. Kernel packaging is not: distributions
vary in compiler dependencies, config deltas, initramfs generators, Secure Boot
signing and bootloaders. The adapters perform automatic safety checks, but a
retained stock kernel remains mandatory. Exotic UKI-only,
encrypted-boot or custom bootloader setups may require manual integration.

## Distribution testing

Fedora is validated end-to-end. The Debian/Ubuntu, Arch, openSUSE and generic
adapters need broader physical testing. Please use the repository's
[distribution test report](https://github.com/RavenWearne/thinkpad-synaptics-patch/issues/new?template=distro-test.yml)
form so hardware detection, build, boot and SynPS/2 verification
results remain comparable.
