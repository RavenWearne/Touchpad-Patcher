# ThinkPad T14 Gen 1 LEN2068 Touchpad Patcher

Build and install a distinctly named Linux kernel that keeps the Synaptics
TM3471-020 / LEN2068 touchpad on its reliable SynPS/2 path instead of handing
it to RMI4/SMBus. Stock distribution kernels and their boot entries are always
preserved as fallbacks.

The repository contains only the portable launcher, source patcher, and
installer. Kernel sources and build products are downloaded or created locally
and are never stored in Git.

## Clone the stable release and run

```bash
git clone --no-checkout https://github.com/RavenWearne/thinkpad-synaptics-patch.git "Touchpad Patcher"
cd "Touchpad Patcher"
git switch --create stable-v1.1.0 v1.1.0
./Run\ Touchpad\ Patcher.sh
```

This checks out the known `v1.1.0` release on a normal local branch rather than
using the unreleased `main` branch or a detached HEAD. Published versions are
available from [GitHub Releases](https://github.com/RavenWearne/thinkpad-synaptics-patch/releases).

For full live command and package-manager output, run:

```bash
./Run\ Touchpad\ Patcher.sh --verbose
```

Normal and verbose mode perform exactly the same operations. Normal mode shows
concise installer statuses and elapsed time for long operations. Verbose mode
also streams commands, package-manager output, downloads, compiler output, and
bootloader operations. Every run keeps a complete timestamped diagnostic log
in `logs/`; failed builds also identify the meaningful compiler error and keep
a dedicated `*-kernel-build.log`.

## What the launcher does

The guarded workflow is:

1. Positively identify a Lenovo ThinkPad T14 Gen 1 and dynamically find
   `LEN2068` in the readable serio firmware IDs.
2. Detect the distribution adapter and running kernel configuration.
3. Determine and install missing build, development-header, compression,
   initramfs, and bootloader prerequisites before any source is downloaded.
4. Resolve the matching upstream kernel source name. Distribution release
   `X.Y.0-build-flavour` correctly maps to kernel.org's `linux-X.Y.tar.xz`.
5. Benchmark a curated set of trusted HTTPS kernel.org mirrors for the exact
   archive, use the fastest available source, and retain `cdn.kernel.org` as
   the authoritative fallback.
6. Validate cached/downloaded source against the SHA-256 published by
   kernel.org, extract it atomically, apply the narrowly scoped Synaptics
   policy change, and copy the running distribution kernel configuration.
7. Build and install the distinctly suffixed kernel, modules, and initramfs.
8. Update the supported bootloader, verify the patched entry, and safely select
   it for the next boot where this can be verified without hard-coded menu
   indexes. If selection cannot be proven safe, the patcher says so instead of
   guessing.
9. Confirm the patched kernel, module tree, initramfs, bootloader entry, and at
   least one stock fallback kernel all exist.

Sudo authentication remains interactive. The launcher keeps the authenticated
timestamp alive during the long build so it should not ask again near the end.

## Dependency preparation

Dependencies are adapter-specific. On Debian, Ubuntu, and Linux Mint the
installer refreshes APT metadata only when packages are missing, then installs
the complete audited kernel build/install set before touching source. This
includes the compiler toolchain, `bc`, `bison`, `flex`, Perl, Python,
`pkg-config`, OpenSSL, ELF/DWARF, zlib/zstd/lz4/lzo and ncurses development
headers, `dwarves`/`pahole`, compression tools, `rsync`, `cpio`, `kmod`,
initramfs tooling, GRUB tooling, and configuration-dependent GCC plug-in,
Clang/LTO, or Rust requirements.

The specific Mint failures involving `libssl-dev`, `libelf-dev`, `dwarves`,
`zlib1g-dev`, `libzstd-dev`, and `libdw-dev` (`dwarf.h`) are covered. After
installation, the patcher verifies important commands and headers—including
`dwarf.h`, libdw, libelf, OpenSSL, zlib, zstd, and `pahole` when BTF is enabled—
and stops before download if any requirement is still unavailable.

Installed packages are not reinstalled. Detailed APT/DNF/pacman/zypper output
is written to the run log and is shown interactively only with `--verbose`.

## Boot and fallback behaviour

On Debian, Ubuntu, and Linux Mint GRUB systems, the installer runs
`update-grub`, confirms the generated configuration contains both the patched
kernel and a stock fallback, resolves the generated GRUB entry IDs, and uses a
verified one-time next-boot selection. It does not write numeric menu indexes,
replace `/etc/default/grub`, or overwrite unrelated GRUB customisations.

Fedora uses `kernel-install` and `grubby` with verification. Other adapters
update supported boot tooling conservatively and report when automatic
selection is not safe. No path removes or silently replaces a distribution
kernel.

After reboot, run the launcher again. If already running the patched kernel it
verifies that `SynPS/2 Synaptics TouchPad` is registered and that the native
TM3471 RMI4 input device is absent.

## Safety boundary

The installer deliberately:

- refuses non-Lenovo, non-T14-Gen-1, non-LEN2068, non-x86-64, unsupported
  source-layout, and Secure-Boot-enabled installations;
- inspects `smbus_pnp_ids`, modifies exactly the `LEN2068` policy entry,
  recognizes already-patched trees, and fails rather than patching an unknown
  driver layout;
- copies the running kernel configuration, clears unavailable
  distribution-private signing-key paths, and retains enabled build features
  by preparing their host dependencies;
- validates downloads before accepting them as cache and never promotes an
  incomplete `.part` download;
- gives custom kernels the descriptive
  `-t14-len2068-touchpad-patch` suffix;
- refuses to overwrite or uninstall the running kernel; and
- requires an installed stock kernel to remain available after installation.

Kernel updates do not inherit an out-of-tree source change. Re-run the release
for the desired new upstream series, keep a stock kernel as fallback, and test
the new build before removing any older custom build.

## Advanced use

The installer can be run directly:

```bash
./scripts/t14-ps2-kernel-installer.sh all
./scripts/t14-ps2-kernel-installer.sh --verbose all
./scripts/t14-ps2-kernel-installer.sh verify
```

Use `--kernel X.Y.Z` if the distribution release does not map to the desired
upstream version, or `--source DIR` for a pre-downloaded clean kernel tree. The
source-only policy operation is separately auditable and idempotent:

```bash
./scripts/t14-ps2-patch-source.sh /path/to/linux
```

The source patch supports stable upstream Linux 4.x and newer on x86-64 when
the expected Synaptics table structure is present. Packaging, initramfs,
Secure Boot, UKI, encrypted-boot, and bootloader arrangements vary between
distributions, so uncommon custom boot setups may still require manual
integration.

## Distribution testing

Fedora is validated end-to-end. Linux Mint 22.3 testing is in progress for
v1.1.0; Debian/Ubuntu, Arch, openSUSE, and generic adapters need broader
physical testing. Submit results with the repository's
[distribution test report](https://github.com/RavenWearne/thinkpad-synaptics-patch/issues/new?template=distro-test.yml)
so hardware detection, dependencies, build, boot, and SynPS/2 verification are
comparable.
