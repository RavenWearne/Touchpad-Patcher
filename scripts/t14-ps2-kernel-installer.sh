#!/usr/bin/env bash
set -euo pipefail

tool_version=4
local_suffix=t14-len2068-touchpad-patch
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
patcher="$project_dir/scripts/t14-ps2-patch-source.sh"
work_dir=${XDG_CACHE_HOME:-$HOME/.cache}/t14-len2068-touchpad-patch
jobs=$(nproc)
assume_yes=0
keep_build=0
dry_run=0
source_dir=
kernel_version=
action=all

usage() {
	cat <<EOF
Usage: $0 [options] [preflight|build|install|all|verify|uninstall]

Build and install a distinctly named Linux kernel that keeps LEN2068 on the
native SynPS/2 path instead of automatically handing it to RMI4/SMBus.

Options:
  --kernel VERSION   Upstream version to build (default: base of uname -r)
  --source DIR       Use an existing clean kernel source tree
  --work-dir DIR     Build/download directory (default: $work_dir)
  --jobs N           Parallel build jobs (default: $jobs)
  --yes              Accept the guarded hardware confirmation
  --keep-build       Retain build files after successful installation
  --dry-run          Show detected choices; do not build or install
  -h, --help         Show this help

Supported adapters: Fedora/RHEL, Debian/Ubuntu, Arch, openSUSE, and generic
systemd kernel-install. Stock kernels are never removed.
EOF
}

log() { printf '[t14-patch] %s\n' "$*"; }
phase() { printf '\n[t14-patch] === %s ===\n' "$*"; }
die() { printf '[t14-patch] ERROR: %s\n' "$*" >&2; exit 1; }
run() { log "+ $*"; (( dry_run )) || "$@"; }
need() { command -v "$1" >/dev/null || die "required command not found: $1"; }
read_dmi() { [[ -r "/sys/class/dmi/id/$1" ]] && tr -d '\n' <"/sys/class/dmi/id/$1" || true; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--kernel) kernel_version=${2:?}; shift 2 ;;
		--source) source_dir=$(readlink -f -- "${2:?}"); shift 2 ;;
		--work-dir) work_dir=$(readlink -m -- "${2:?}"); shift 2 ;;
		--jobs) jobs=${2:?}; shift 2 ;;
		--yes) assume_yes=1; shift ;;
		--keep-build) keep_build=1; shift ;;
		--dry-run) dry_run=1; shift ;;
		-h|--help) usage; exit 0 ;;
		preflight|build|install|all|verify|uninstall) action=$1; shift ;;
		*) usage >&2; die "unknown argument: $1" ;;
	esac
done
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"

detect_platform() {
	[[ -r /etc/os-release ]] || die "/etc/os-release is unavailable"
	# shellcheck disable=SC1091
	. /etc/os-release
	distro_id=${ID:-unknown}
	distro_like=${ID_LIKE:-}
	case " $distro_id $distro_like " in
		*fedora*|*rhel*) adapter=fedora ;;
		*debian*|*ubuntu*) adapter=debian ;;
		*arch*) adapter=arch ;;
		*suse*|*opensuse*) adapter=suse ;;
		*) adapter=generic ;;
	esac
}

hardware_guard() {
	local vendor product version firmware firmware_file firmware_id matched_device
	local -a observed_firmware_ids
	vendor=$(read_dmi sys_vendor)
	product=$(read_dmi product_name)
	version=$(read_dmi product_version)
	firmware=$(journalctl -b -k --no-pager 2>/dev/null | sed -n 's/.*product: \(TM[^,]*\), fw id: \([0-9]*\).*/\1 fw=\2/p' | head -n1)
	observed_firmware_ids=()
	firmware_id=
	matched_device=
	for firmware_file in /sys/bus/serio/devices/*/firmware_id; do
		[[ -r "$firmware_file" ]] || continue
		firmware_id=$(<"$firmware_file")
		observed_firmware_ids+=("${firmware_file%/firmware_id}='${firmware_id:-<empty>}'")
		if [[ "$firmware_id" == *LEN2068* ]]; then
			matched_device=${firmware_file%/firmware_id}
			break
		fi
	done
	log "hardware: vendor='$vendor' product='$product' version='$version' ${firmware:+sensor='$firmware'}"
	[[ "$vendor" == LENOVO* ]] || die "this guarded patch is only for Lenovo hardware"
	if [[ -z "$matched_device" ]]; then
		if (( ${#observed_firmware_ids[@]} )); then
			die "LEN2068 was not found in any readable serio firmware ID (observed: ${observed_firmware_ids[*]}); refusing kernel modification"
		fi
		die "LEN2068 was not found because no readable /sys/bus/serio/devices/*/firmware_id files are available; refusing kernel modification"
	fi
	log "touchpad: found LEN2068 at $matched_device (firmware ID: '$firmware_id')"
	if (( ! assume_yes && ! dry_run )); then
		printf 'Build the LEN2068 SynPS/2 policy kernel for this machine? [y/N] '
		read -r answer
		[[ "$answer" =~ ^[Yy]$ ]] || die "cancelled"
	fi
}

derive_version() {
	if [[ -z "$kernel_version" ]]; then
		local running=${1:-$(uname -r)}
		if [[ "$running" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
			kernel_version=${BASH_REMATCH[1]}
		else
			die "cannot derive an upstream version from '$running'; use --kernel VERSION"
		fi
	fi
	[[ "$kernel_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || \
		die "supported upstream stable versions use X.Y or X.Y.Z (got '$kernel_version')"
	local major=${kernel_version%%.*}
	(( major >= 4 )) || die "supported kernel source families begin at Linux 4.x"
	[[ "$(uname -m)" == x86_64 ]] || die "the automated installer currently supports x86-64 kernels"
	source_version=$kernel_version
	if [[ "$kernel_version" =~ ^([0-9]+\.[0-9]+)\.0$ ]]; then
		source_version=${BASH_REMATCH[1]}
	fi
}

find_config() {
	local candidate
	for candidate in "/boot/config-$(uname -r)" "/usr/lib/modules/$(uname -r)/config"; do
		[[ -r "$candidate" ]] && { config_source=$candidate; return; }
	done
	if [[ -r /proc/config.gz ]]; then
		config_source=/proc/config.gz
		return
	fi
	die "running kernel configuration not found in /boot, /usr/lib/modules, or /proc/config.gz"
}

check_tools() {
	local command
	for command in bash make gcc bc bison flex perl python3 tar xz curl openssl; do need "$command"; done
	[[ -d /usr/include/openssl ]] || die "OpenSSL development headers are missing"
	[[ -e /usr/include/elf.h ]] || die "ELF development headers are missing"
}

ensure_debian_dependencies() {
	local package
	local -a packages missing_packages
	packages=(build-essential bc bison flex libssl-dev libelf-dev dwarves)
	missing_packages=()
	need apt-get
	need dpkg-query
	for package in "${packages[@]}"; do
		if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
			missing_packages+=("$package")
		fi
	done
	if (( ! ${#missing_packages[@]} )); then
		log "Debian/Ubuntu build dependencies are already installed"
		return
	fi
	log "missing Debian/Ubuntu build packages: ${missing_packages[*]}"
	if (( dry_run )); then
		log "dry run: would refresh package metadata and install the missing packages"
		return
	fi
	log "refreshing APT package metadata"
	sudo apt-get update
	log "installing required kernel-build packages"
	sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"
}

ensure_dependencies() {
	case "$adapter" in
		debian) ensure_debian_dependencies ;;
	esac
}

preflight() {
	detect_platform
	hardware_guard
	derive_version
	ensure_dependencies
	find_config
	check_tools
	local available_kb
	available_kb=$(df -Pk "$(dirname "$work_dir")" 2>/dev/null | awk 'NR==2 {print $4}' || true)
	[[ -z "$available_kb" || "$available_kb" -ge 10485760 ]] || die "at least 10 GiB free is required in $(dirname "$work_dir")"
	if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
		die "Secure Boot is enabled. Enrol a signing key or disable Secure Boot before installing an unsigned custom kernel"
	fi
	log "adapter=$adapter kernel=$kernel_version source=$source_version config=$config_source work=$work_dir jobs=$jobs"
}

prepare_source() {
	if [[ -n "$source_dir" ]]; then
		build_source=$source_dir
	else
		build_source="$work_dir/linux-$source_version"
		archive="$work_dir/linux-$source_version.tar.xz"
		if [[ ! -d "$build_source" ]]; then
			run mkdir -p "$work_dir"
			if [[ "$source_version" != "$kernel_version" ]]; then
				log "kernel $kernel_version uses upstream source archive version $source_version"
			fi
			log "downloading Linux $source_version source"
			run curl --fail --location --proto '=https' --tlsv1.2 \
				-o "$archive" "https://cdn.kernel.org/pub/linux/kernel/v${source_version%%.*}.x/linux-$source_version.tar.xz"
			log "extracting Linux $source_version source"
			run tar -C "$work_dir" -xf "$archive"
		else
			log "reusing existing source tree: $build_source"
		fi
	fi
	(( dry_run )) && return
	"$patcher" "$build_source"
	if [[ "$config_source" == /proc/config.gz ]]; then
		gzip -cd "$config_source" >"$build_source/.config"
	else
		cp -- "$config_source" "$build_source/.config"
	fi
	# Distribution configs may name private certificate files that are absent
	# from an upstream tarball. The custom kernel remains unsigned, and Secure
	# Boot was already refused in preflight.
	if [[ -x "$build_source/scripts/config" ]]; then
		"$build_source/scripts/config" --file "$build_source/.config" \
			--set-str SYSTEM_TRUSTED_KEYS "" \
			--set-str SYSTEM_REVOCATION_KEYS ""
		if grep -q '^CONFIG_DEBUG_INFO_BTF=y' "$build_source/.config" && ! command -v pahole >/dev/null; then
			log "pahole is unavailable; disabling optional BTF debug metadata"
			"$build_source/scripts/config" --file "$build_source/.config" --disable DEBUG_INFO_BTF
		fi
	fi
	printf '%s\n' "-$local_suffix" >"$build_source/localversion.10-t14-touchpad-patch"
	make -C "$build_source" olddefconfig
}

format_elapsed() {
	local total=$1
	printf '%02d:%02d:%02d' "$(( total / 3600 ))" "$(( total % 3600 / 60 ))" "$(( total % 60 ))"
}

compile_kernel() {
	local build_pid build_status elapsed frame spinner tick start
	local log_dir="$project_dir/logs"
	local build_log="$log_dir/$(date +%Y%m%d-%H%M%S)-kernel-build.log"
	mkdir -p "$log_dir"
	log "full compiler output: $build_log"
	make -C "$build_source" -j "$jobs" >"$build_log" 2>&1 &
	build_pid=$!
	start=$SECONDS
	spinner='|/-\'
	tick=0
	if [[ -t 0 ]]; then
		while kill -0 "$build_pid" 2>/dev/null; do
			frame=${spinner:tick%4:1}
			elapsed=$(format_elapsed "$(( SECONDS - start ))")
			printf '\r[t14-patch] %s compiling kernel — elapsed %s' "$frame" "$elapsed"
			tick=$(( tick + 1 ))
			sleep 1
		done
		printf '\r\033[K'
	else
		while kill -0 "$build_pid" 2>/dev/null; do
			sleep 1
			tick=$(( tick + 1 ))
			if (( tick % 30 == 0 )); then
				elapsed=$(format_elapsed "$(( SECONDS - start ))")
				log "kernel compilation still active — elapsed $elapsed"
			fi
		done
	fi
	if wait "$build_pid"; then
		build_status=0
	else
		build_status=$?
	fi
	elapsed=$(format_elapsed "$(( SECONDS - start ))")
	if (( build_status != 0 )); then
		printf '[t14-patch] Last 40 compiler-output lines:\n' >&2
		tail -n 40 "$build_log" >&2 || true
		die "kernel compilation failed after $elapsed (status $build_status); full output: $build_log"
	fi
	log "kernel compilation completed in $elapsed"
	log "compiler output retained at $build_log"
}

build_kernel() {
	phase "Source download, patch and configuration"
	prepare_source
	(( dry_run )) && { log "would patch and build $build_source"; return; }
	phase "Kernel and module compilation"
	compile_kernel
	built_release=$(make -s -C "$build_source" kernelrelease)
	[[ "$built_release" == *"-$local_suffix" ]] || die "unexpected kernel release: $built_release"
	[[ -f "$build_source/arch/x86/boot/bzImage" ]] || die "x86 kernel image was not produced"
	printf '%s\n' "$build_source" >"$work_dir/.last-source"
	printf '%s\n' "$built_release" >"$work_dir/.last-release"
	log "built $built_release"
}

load_build_state() {
	[[ -n "$source_dir" ]] && build_source=$source_dir
	[[ -n "${build_source:-}" && -d "$build_source" ]] || build_source=$(cat "$work_dir/.last-source" 2>/dev/null || true)
	[[ -d "${build_source:-}" ]] || die "no completed build found; run build first"
	built_release=$(make -s -C "$build_source" kernelrelease)
	[[ "$built_release" == *"-$local_suffix" ]] || die "refusing unexpected release: $built_release"
}

generate_initramfs() {
	case "$adapter" in
		fedora|suse) need dracut; run sudo dracut --force "/boot/initramfs-$built_release.img" "$built_release" ;;
		debian) need update-initramfs; run sudo update-initramfs -c -k "$built_release" ;;
		arch) need mkinitcpio; run sudo mkinitcpio -k "$built_release" -g "/boot/initramfs-$built_release.img" ;;
		generic)
			if command -v dracut >/dev/null; then run sudo dracut --force "/boot/initramfs-$built_release.img" "$built_release"
			else die "generic adapter needs dracut; create an initramfs manually"; fi ;;
	esac
}

refresh_bootloader() {
	if command -v kernel-install >/dev/null; then
		run sudo kernel-install add "$built_release" "/boot/vmlinuz-$built_release"
	fi
	if command -v update-grub >/dev/null; then run sudo update-grub
	elif command -v grub2-mkconfig >/dev/null && [[ -d /boot/grub2 ]]; then run sudo grub2-mkconfig -o /boot/grub2/grub.cfg
	elif command -v grub-mkconfig >/dev/null && [[ -d /boot/grub ]]; then run sudo grub-mkconfig -o /boot/grub/grub.cfg
	fi
	if command -v grubby >/dev/null; then
		run sudo grubby --set-default "/boot/vmlinuz-$built_release"
		[[ "$(sudo grubby --default-kernel)" == "/boot/vmlinuz-$built_release" ]] || die "grubby did not retain the requested default"
	else
		log "boot files were installed, but this adapter cannot safely prove default selection; select '$built_release' once in your boot menu"
	fi
}

install_kernel() {
	detect_platform
	load_build_state
	[[ "$(uname -r)" != "$built_release" ]] || die "refusing to overwrite the running kernel"
	phase "Kernel and module installation"
	run sudo make -C "$build_source" modules_install INSTALL_MOD_STRIP=1
	run sudo install -m 0644 "$build_source/arch/x86/boot/bzImage" "/boot/vmlinuz-$built_release"
	run sudo install -m 0644 "$build_source/System.map" "/boot/System.map-$built_release"
	run sudo install -m 0644 "$build_source/.config" "/boot/config-$built_release"
	phase "Initramfs generation"
	generate_initramfs
	phase "Bootloader configuration"
	refresh_bootloader
	log "installed $built_release; stock kernels were not removed"
	if (( ! keep_build )) && [[ "$build_source" == "$work_dir"/* ]]; then
		log "build retained until post-reboot verification; run uninstall or remove $build_source when satisfied"
	fi
}

verify_kernel() {
	local running
	running=$(uname -r)
	if [[ "$running" != *"-$local_suffix" && "$running" != *-t14ps2quirk1 ]]; then
		die "running '$running', not a recognized T14 LEN2068 touchpad patch kernel"
	fi
	grep -q 'SynPS/2 Synaptics TouchPad' /proc/bus/input/devices || die "SynPS/2 touchpad is not registered"
	if grep -q 'Synaptics TM3471' /proc/bus/input/devices; then die "native RMI4 input device is still registered"; fi
	log "verified $running with SynPS/2 and no native TM3471 RMI4 input device"
}

uninstall_kernel() {
	local release=${kernel_version:-}
	[[ -n "$release" ]] || release=$(cat "$work_dir/.last-release" 2>/dev/null || true)
	[[ "$release" == *"-$local_suffix" ]] || die "use --kernel with the complete custom release, or retain .last-release"
	[[ "$(uname -r)" != "$release" ]] || die "boot a stock kernel before uninstalling the currently running kernel"
	if command -v kernel-install >/dev/null; then run sudo kernel-install remove "$release"; fi
	if [[ "$adapter" == debian ]] && command -v update-initramfs >/dev/null; then run sudo update-initramfs -d -k "$release" || true; fi
	for path in "/boot/vmlinuz-$release" "/boot/initramfs-$release.img" "/boot/initrd.img-$release" "/boot/System.map-$release" "/boot/config-$release"; do
		[[ ! -e "$path" ]] || run sudo rm -f -- "$path"
	done
	[[ ! -d "/lib/modules/$release" ]] || run sudo rm -rf -- "/lib/modules/$release"
	log "removed only $release; stock kernels were untouched"
}

case "$action" in
	preflight) phase "Safety and compatibility checks"; preflight ;;
	build) phase "Safety and compatibility checks"; preflight; build_kernel ;;
	install) detect_platform; install_kernel ;;
	all) phase "Safety and compatibility checks"; preflight; build_kernel; install_kernel ;;
	verify) phase "Post-reboot SynPS/2 verification"; verify_kernel ;;
	uninstall) detect_platform; uninstall_kernel ;;
esac
