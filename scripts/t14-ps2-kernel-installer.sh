#!/usr/bin/env bash
set -euo pipefail

tool_version=6
local_suffix=t14-len2068-touchpad-patch
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
patcher="$project_dir/scripts/t14-ps2-patch-source.sh"
work_dir=${XDG_CACHE_HOME:-$HOME/.cache}/t14-len2068-touchpad-patch
jobs=$(nproc)
assume_yes=0
keep_build=0
dry_run=0
verbose=0
source_dir=
kernel_version=
log_file=${TOUCHPAD_PATCHER_LOG:-}
action=all

usage() {
	cat <<EOF
Usage: $0 [options] [preflight|build|install|all|verify|uninstall]

Fallback builder: install a distinctly named Linux kernel that keeps LEN2068
on SynPS/2 when the preferred stock-kernel parameter is unavailable.

Options:
  --kernel VERSION   Upstream version to build (default: base of uname -r)
  --source DIR       Use an existing clean kernel source tree
  --work-dir DIR     Build/download directory (default: $work_dir)
  --jobs N           Parallel build jobs (default: $jobs)
  --log-file FILE    Append complete diagnostic output to FILE
  --verbose          Show detailed commands and command output interactively
  --yes              Accept the guarded hardware confirmation
  --keep-build       Retain build files after successful installation
  --dry-run          Show detected choices; do not build or install
  -h, --help         Show this help

Supported adapters: Fedora/RHEL, Debian/Ubuntu/Mint, Arch, openSUSE, and
generic systemd kernel-install. Stock kernels are never removed.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--kernel) kernel_version=${2:?}; shift 2 ;;
		--source) source_dir=$(readlink -f -- "${2:?}"); shift 2 ;;
		--work-dir) work_dir=$(readlink -m -- "${2:?}"); shift 2 ;;
		--jobs) jobs=${2:?}; shift 2 ;;
		--log-file) log_file=$(readlink -m -- "${2:?}"); shift 2 ;;
		--verbose) verbose=1; shift ;;
		--yes) assume_yes=1; shift ;;
		--keep-build) keep_build=1; shift ;;
		--dry-run) dry_run=1; shift ;;
		-h|--help) usage; exit 0 ;;
		preflight|build|install|all|verify|uninstall) action=$1; shift ;;
		*) usage >&2; printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { printf '%s\n' '--jobs must be a positive integer' >&2; exit 2; }

if [[ -z "$log_file" ]]; then
	mkdir -p "$project_dir/logs"
	log_file="$project_dir/logs/$(date +%Y%m%d-%H%M%S-%N)-installer.log"
else
	mkdir -p "$(dirname "$log_file")"
fi
touch "$log_file"

timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }

detail() {
	printf '[%s] %s\n' "$(timestamp)" "$*" >>"$log_file"
	if (( verbose )); then
		printf '[detail] %s\n' "$*"
	fi
}

status_ok() {
	printf '✓ %s\n' "$*"
	detail "OK: $*"
}

notice() {
	printf '%s\n' "$*"
	detail "$*"
}

warn() {
	printf '⚠ %s\n' "$*" >&2
	detail "WARNING: $*"
}

die() {
	local message=$1
	local status=${2:-1}
	printf '✗ %s\n' "$message" >&2
	detail "ERROR($status): $message"
	printf 'Full diagnostic log: %s\n' "$log_file" >&2
	exit "$status"
}

quote_command() {
	local argument quoted=
	for argument in "$@"; do
		printf -v argument '%q' "$argument"
		quoted+="${quoted:+ }$argument"
	done
	printf '%s' "$quoted"
}

run_logged() {
	local status command
	command=$(quote_command "$@")
	detail "+ $command"
	if (( dry_run )); then
		detail "dry run: skipped"
		return 0
	fi
	if (( verbose )); then
		set +e
		"$@" > >(tee -a "$log_file") 2> >(tee -a "$log_file" >&2)
		status=$?
		set -e
	else
		set +e
		"$@" >>"$log_file" 2>&1
		status=$?
		set -e
	fi
	detail "exit $status: $command"
	return "$status"
}

format_elapsed() {
	local total=$1
	printf '%02d:%02d:%02d' "$(( total / 3600 ))" "$(( total % 3600 / 60 ))" "$(( total % 60 ))"
}

run_activity() {
	local label=$1
	shift
	local child_pid elapsed frame spinner tick start status command
	command=$(quote_command "$@")
	detail "+ $command"
	if (( dry_run )); then
		detail "dry run: skipped $label"
		return 0
	fi
	if (( verbose )); then
		run_logged "$@"
		return
	fi
	"$@" >>"$log_file" 2>&1 &
	child_pid=$!
	start=$SECONDS
	spinner='|/-\'
	tick=0
	while kill -0 "$child_pid" 2>/dev/null; do
		elapsed=$(format_elapsed "$(( SECONDS - start ))")
		if [[ -t 0 ]]; then
			frame=${spinner:tick%4:1}
			printf '\r%s %s  %s' "$frame" "$label" "$elapsed"
		elif (( tick > 0 && tick % 30 == 0 )); then
			detail "$label still active after $elapsed"
		fi
		tick=$(( tick + 1 ))
		sleep 1
	done
	[[ ! -t 0 ]] || printf '\r\033[K'
	if wait "$child_pid"; then status=0; else status=$?; fi
	detail "exit $status: $command"
	return "$status"
}

need() { command -v "$1" >/dev/null || die "Required command is unavailable after dependency preparation: $1"; }
read_dmi() { [[ -r "/sys/class/dmi/id/$1" ]] && tr -d '\n' <"/sys/class/dmi/id/$1" || true; }

ensure_sudo() {
	need sudo
	if ! sudo -n true 2>/dev/null; then
		notice 'Administrator authentication is required to continue.'
		sudo -v || die 'Administrator authentication failed'
	fi
	detail 'sudo authentication available'
}

detect_platform() {
	[[ -r /etc/os-release ]] || die '/etc/os-release is unavailable'
	# shellcheck disable=SC1091
	. /etc/os-release
	distro_id=${ID:-unknown}
	distro_like=${ID_LIKE:-}
	distro_pretty=${PRETTY_NAME:-$distro_id}
	case " $distro_id $distro_like " in
		*fedora*|*rhel*) adapter=fedora; adapter_label='Fedora/RHEL' ;;
		*debian*|*ubuntu*) adapter=debian; adapter_label='Debian/Ubuntu/Linux Mint' ;;
		*arch*) adapter=arch; adapter_label='Arch Linux' ;;
		*suse*) adapter=suse; adapter_label='openSUSE' ;;
		*) adapter=generic; adapter_label='Generic systemd Linux' ;;
	esac
	detail "distribution id='$distro_id' id_like='$distro_like' adapter='$adapter'"
	if [[ "$adapter" == generic ]]; then
		warn "$distro_pretty uses the experimental generic adapter"
	else
		status_ok "$distro_pretty supported ($adapter_label adapter)"
	fi
}

hardware_guard() {
	local vendor product version firmware firmware_file firmware_id matched_device
	local -a observed_firmware_ids
	vendor=$(read_dmi sys_vendor)
	product=$(read_dmi product_name)
	version=$(read_dmi product_version)
	firmware=$(journalctl -b -k --no-pager 2>/dev/null | sed -n 's/.*product: \(TM[^,]*\), fw id: \([0-9]*\).*/\1 fw=\2/p' | head -n1)
	detail "hardware vendor='$vendor' product='$product' version='$version' ${firmware:+sensor='$firmware'}"
	[[ "$vendor" == LENOVO* ]] || die 'This guarded patch is only for Lenovo hardware'
	[[ "$product $version" == *'ThinkPad T14 Gen 1'* ]] || die "ThinkPad T14 Gen 1 was not detected (product='$product', version='$version')"
	status_ok 'ThinkPad T14 Gen 1 detected'

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
	detail "serio firmware IDs: ${observed_firmware_ids[*]:-none readable}"
	if [[ -z "$matched_device" ]]; then
		if (( ${#observed_firmware_ids[@]} )); then
			die "LEN2068 was not found in readable serio firmware IDs: ${observed_firmware_ids[*]}"
		fi
		die 'LEN2068 was not found because no readable serio firmware_id files are available'
	fi
	if [[ -n "$firmware" ]]; then
		status_ok "Synaptics $firmware / LEN2068 detected"
	else
		status_ok "Synaptics LEN2068 detected at $matched_device"
	fi
	if (( ! assume_yes && ! dry_run )); then
		printf 'Build the custom LEN2068 SynPS/2 fallback kernel for this machine? [y/N] '
		read -r answer
		[[ "$answer" =~ ^[Yy]$ ]] || die 'Cancelled by user'
	fi
}

derive_version() {
	if [[ -z "$kernel_version" ]]; then
		local running=${1:-$(uname -r)}
		if [[ "$running" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
			kernel_version=${BASH_REMATCH[1]}
		else
			die "Cannot derive an upstream version from '$running'; use --kernel VERSION"
		fi
	fi
	[[ "$kernel_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Unsupported kernel version syntax: $kernel_version"
	local major=${kernel_version%%.*}
	(( major >= 4 )) || die 'Supported upstream source families begin at Linux 4.x'
	[[ "$(uname -m)" == x86_64 ]] || die 'Automated building currently supports x86-64 only'
	source_version=$kernel_version
	if [[ "$kernel_version" =~ ^([0-9]+\.[0-9]+)\.0$ ]]; then
		source_version=${BASH_REMATCH[1]}
	fi
	detail "running='$(uname -r)' kernel_version='$kernel_version' source_version='$source_version'"
}

find_config() {
	local candidate
	for candidate in "/boot/config-$(uname -r)" "/usr/lib/modules/$(uname -r)/config"; do
		[[ -r "$candidate" ]] && { config_source=$candidate; detail "kernel config: $config_source"; return; }
	done
	if [[ -r /proc/config.gz ]]; then
		config_source=/proc/config.gz
		detail "kernel config: $config_source"
		return
	fi
	die 'Running kernel configuration was not found in /boot, /usr/lib/modules, or /proc/config.gz'
}

config_has() {
	local expression=$1
	if [[ "$config_source" == /proc/config.gz ]]; then
		gzip -cd "$config_source" | grep -Eq "$expression"
	else
		grep -Eq "$expression" "$config_source"
	fi
}

dependency_packages_debian() {
	local compiler_package
	dependency_packages=(
		build-essential binutils bc bison flex gawk pkg-config perl python3
		coreutils findutils grep sed diffutils file
		tar xz-utils gzip bzip2 zstd lz4 lzop curl ca-certificates
		openssl libssl-dev libelf-dev libdw-dev zlib1g-dev libzstd-dev
		liblz4-dev liblzo2-dev libncurses-dev dwarves rsync cpio kmod
		initramfs-tools grub2-common mokutil
	)
	if config_has '^CONFIG_GCC_PLUGINS=y$'; then
		compiler_package=$(apt-cache depends gcc 2>/dev/null | sed -n 's/.*Depends: \(gcc-[0-9][0-9]*\)$/\1/p' | head -n 1)
		[[ -n "$compiler_package" ]] || die 'Could not resolve the Debian GCC plug-in development package required by this kernel configuration'
		dependency_packages+=("$compiler_package-plugin-dev")
	fi
	if config_has '^CONFIG_LTO_CLANG=y$|^CONFIG_CFI_CLANG=y$'; then
		dependency_packages+=(clang llvm lld)
	fi
	if config_has '^CONFIG_RUST=y$'; then
		dependency_packages+=(rustc rust-src bindgen clang libclang-dev llvm lld)
	fi
}

dependency_packages_fedora() {
	dependency_packages=(
		gcc gcc-c++ make binutils bc bison flex gawk pkgconf-pkg-config perl python3
		coreutils findutils grep sed diffutils file
		tar xz gzip bzip2 zstd lz4 lzop curl ca-certificates openssl openssl-devel
		elfutils-libelf-devel elfutils-devel zlib-devel libzstd-devel lz4-devel
		lzo-devel ncurses-devel dwarves rsync cpio kmod dracut grubby mokutil
	)
	config_has '^CONFIG_GCC_PLUGINS=y$' && dependency_packages+=(gcc-plugin-devel)
	config_has '^CONFIG_LTO_CLANG=y$|^CONFIG_CFI_CLANG=y$' && dependency_packages+=(clang llvm lld)
	if config_has '^CONFIG_RUST=y$'; then dependency_packages+=(rust cargo bindgen-cli clang llvm lld); fi
}

dependency_packages_arch() {
	dependency_packages=(
		base-devel bc bison flex gawk pkgconf perl python coreutils findutils grep sed diffutils file tar xz gzip bzip2 zstd lz4
		lzo curl ca-certificates openssl libelf zlib ncurses pahole rsync cpio
		kmod mkinitcpio grub mokutil
	)
	config_has '^CONFIG_LTO_CLANG=y$|^CONFIG_CFI_CLANG=y$' && dependency_packages+=(clang llvm lld)
	if config_has '^CONFIG_RUST=y$'; then dependency_packages+=(rust bindgen clang llvm lld); fi
}

dependency_packages_suse() {
	dependency_packages=(
		gcc gcc-c++ make binutils bc bison flex gawk pkg-config perl python3
		coreutils findutils grep sed diffutils file tar xz
		gzip bzip2 zstd lz4 lzo curl ca-certificates openssl libopenssl-devel
		libelf-devel libdw-devel zlib-devel libzstd-devel liblz4-devel
		liblzo2-devel ncurses-devel dwarves rsync cpio kmod dracut grub2 mokutil
	)
	config_has '^CONFIG_LTO_CLANG=y$|^CONFIG_CFI_CLANG=y$' && dependency_packages+=(clang llvm lld)
	if config_has '^CONFIG_RUST=y$'; then dependency_packages+=(rust cargo bindgen clang llvm lld); fi
}

package_installed() {
	local package=$1
	case "$adapter" in
		debian) dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed' ;;
		fedora|suse) rpm -q "$package" >/dev/null 2>&1 ;;
		arch) pacman -Q "$package" >/dev/null 2>&1 ;;
		*) return 1 ;;
	esac
}

install_dependency_packages() {
	local -a missing_packages=("$@")
	case "$adapter" in
		debian)
			run_logged sudo apt-get update || die 'APT package metadata refresh failed'
			run_logged sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}" || die 'APT dependency installation failed'
			;;
		fedora)
			run_logged sudo dnf -y makecache || die 'DNF package metadata refresh failed'
			run_logged sudo dnf install -y "${missing_packages[@]}" || die 'DNF dependency installation failed'
			;;
		arch)
			run_logged sudo pacman -Sy --needed --noconfirm "${missing_packages[@]}" || die 'pacman dependency installation failed'
			;;
		suse)
			run_logged sudo zypper --non-interactive refresh || die 'zypper package metadata refresh failed'
			run_logged sudo zypper --non-interactive install --no-recommends "${missing_packages[@]}" || die 'zypper dependency installation failed'
			;;
	esac
}

verify_build_requirements() {
	local command header
	local -a missing_commands missing_headers
	local -a required_commands=(
		bash make gcc ld as objcopy bc bison flex awk gawk perl python3
		find grep sed sort head tr diff file tar xz gzip bzip2 zstd lz4 lzop curl
		openssl pkg-config rsync cpio depmod sha256sum
	)
	local -a required_headers=(
		/usr/include/openssl/ssl.h /usr/include/elf.h /usr/include/libelf.h
		/usr/include/elfutils/libdw.h /usr/include/dwarf.h /usr/include/zlib.h
		/usr/include/zstd.h
	)
	config_has '^CONFIG_DEBUG_INFO_BTF=y$' && required_commands+=(pahole)
	config_has '^CONFIG_KERNEL_LZ4=y$|^CONFIG_MODULE_COMPRESS_LZ4=y$' && required_headers+=(/usr/include/lz4.h)
	config_has '^CONFIG_KERNEL_LZO=y$|^CONFIG_RD_LZO=y$' && required_headers+=(/usr/include/lzo/lzo1x.h)
	config_has '^CONFIG_RUST=y$' && required_commands+=(rustc bindgen clang)
	config_has '^CONFIG_LTO_CLANG=y$|^CONFIG_CFI_CLANG=y$' && required_commands+=(clang ld.lld)
	case "$adapter" in
		debian) required_commands+=(update-initramfs update-grub grub-reboot grub-editenv) ;;
		fedora) required_commands+=(dracut kernel-install grubby) ;;
		arch) required_commands+=(mkinitcpio) ;;
		suse) required_commands+=(dracut grub2-mkconfig) ;;
		generic) required_commands+=(dracut kernel-install) ;;
	esac
	missing_commands=()
	missing_headers=()
	for command in "${required_commands[@]}"; do command -v "$command" >/dev/null || missing_commands+=("$command"); done
	for header in "${required_headers[@]}"; do [[ -e "$header" ]] || missing_headers+=("$header"); done
	(( ! ${#missing_commands[@]} )) || die "Required tools remain unavailable: ${missing_commands[*]}"
	(( ! ${#missing_headers[@]} )) || die "Required development headers remain unavailable: ${missing_headers[*]}"
	pkg-config --exists libdw libelf openssl zlib libzstd || die 'Development-library metadata remains incomplete for libdw, libelf, OpenSSL, zlib, or zstd'
	detail "verified commands: ${required_commands[*]}"
	detail "verified headers: ${required_headers[*]}"
	detail "verified development libraries: $(pkg-config --modversion libdw libelf openssl zlib libzstd 2>&1 | tr '\n' ' ')"
}

ensure_dependencies() {
	local package
	local -a missing_packages
	notice 'Checking system requirements...'
	case "$adapter" in
		debian) need apt-get; need apt-cache; need dpkg-query; dependency_packages_debian ;;
		fedora) need dnf; need rpm; dependency_packages_fedora ;;
		arch) need pacman; dependency_packages_arch ;;
		suse) need zypper; need rpm; dependency_packages_suse ;;
		generic) dependency_packages=() ;;
	esac
	missing_packages=()
	declare -A package_seen=()
	for package in "${dependency_packages[@]}"; do
		[[ -z "${package_seen[$package]:-}" ]] || continue
		package_seen[$package]=1
		package_installed "$package" || missing_packages+=("$package")
	done
	if (( ${#missing_packages[@]} )); then
		detail "missing packages: ${missing_packages[*]}"
		if (( dry_run )); then
			notice "Would install required packages: ${missing_packages[*]}"
		else
			notice 'Installing required build dependencies...'
			ensure_sudo
			install_dependency_packages "${missing_packages[@]}"
		fi
	else
		detail 'all adapter packages already installed'
	fi
	(( dry_run )) || verify_build_requirements
	status_ok 'All build requirements ready'
}

preflight() {
	detect_platform
	hardware_guard
	derive_version
	find_config
	ensure_dependencies
	local available_kb
	available_kb=$(df -Pk "$(dirname "$work_dir")" 2>/dev/null | awk 'NR==2 {print $4}' || true)
	[[ -z "$available_kb" || "$available_kb" -ge 10485760 ]] || die "At least 10 GiB free is required in $(dirname "$work_dir")"
	if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
		die 'Secure Boot is enabled. Enrol a signing key or disable Secure Boot before installing an unsigned custom kernel'
	fi
	detail "preflight adapter=$adapter kernel=$kernel_version source=$source_version config=$config_source work=$work_dir jobs=$jobs"
}

fetch_expected_sha256() {
	local manifest_url manifest
	manifest_url="https://cdn.kernel.org/pub/linux/kernel/v${source_version%%.*}.x/sha256sums.asc"
	detail "authoritative checksum manifest: $manifest_url"
	if ! manifest=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 30 "$manifest_url" 2>>"$log_file"); then
		die 'Unable to retrieve the authoritative kernel.org checksum manifest'
	fi
	expected_sha256=$(awk -v file="linux-$source_version.tar.xz" '$2 == file {print $1; exit}' <<<"$manifest")
	[[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || die "No SHA-256 entry exists for linux-$source_version.tar.xz"
	detail "expected SHA-256: $expected_sha256"
}

archive_valid() {
	local file=$1 actual
	[[ -f "$file" ]] || return 1
	actual=$(sha256sum "$file" | awk '{print $1}')
	detail "cache SHA-256 file='$file' actual='$actual' expected='$expected_sha256'"
	[[ "$actual" == "$expected_sha256" ]]
}

source_tree_valid() {
	local tree=$1
	[[ -f "$tree/Makefile" && -f "$tree/drivers/input/mouse/synaptics.c" && -f "$tree/.touchpad-source-sha256" ]] || return 1
	[[ "$(<"$tree/.touchpad-source-sha256")" == "$expected_sha256" ]]
}

benchmark_mirror() {
	local name=$1 base=$2 relative=$3 result code size speed
	local url="$base/$relative"
	detail "mirror probe start name='$name' url='$url'"
	result=$(curl --silent --show-error --location --proto '=https' --tlsv1.2 \
		--range 0-524287 --max-time 15 --max-filesize 524288 --output /dev/null \
		--write-out '%{http_code} %{size_download} %{speed_download}' "$url" 2>>"$log_file" || true)
	read -r code size speed <<<"$result"
	detail "mirror probe result name='$name' http='${code:-none}' bytes='${size:-0}' speed='${speed:-0}'"
	[[ "$code" == 206 && "${size%.*}" -eq 524288 && "${speed%.*}" -gt 0 ]] || return 1
	printf '%s|%s|%s\n' "${speed%.*}" "$name" "$url"
}

select_download_sources() {
	local relative="v${source_version%%.*}.x/linux-$source_version.tar.xz"
	local result
	local -a results
	results=()
	if result=$(benchmark_mirror 'kernel.org edge' 'https://mirrors.edge.kernel.org/pub/linux/kernel' "$relative"); then results+=("$result"); fi
	if result=$(benchmark_mirror 'JAIST kernel.org mirror' 'https://ftp.jaist.ac.jp/pub/Linux/kernel.org/linux/kernel' "$relative"); then results+=("$result"); fi
	mapfile -t ranked_sources < <(printf '%s\n' "${results[@]}" | sed '/^$/d' | sort -t'|' -k1,1nr)
	if (( ${#ranked_sources[@]} )); then
		IFS='|' read -r selected_speed selected_name selected_url <<<"${ranked_sources[0]}"
		status_ok "Fastest trusted source selected: $selected_name"
		detail "selected mirror speed=${selected_speed}B/s url='$selected_url'"
	else
		warn 'Trusted mirror performance tests failed; using authoritative kernel.org fallback'
	fi
	ranked_sources+=("0|kernel.org authoritative fallback|https://cdn.kernel.org/pub/linux/kernel/$relative")
}

download_archive() {
	local entry speed name url temporary actual
	local download_ok=0
	select_download_sources
	for entry in "${ranked_sources[@]}"; do
		IFS='|' read -r speed name url <<<"$entry"
		temporary="$archive.part.$$"
		rm -f -- "$temporary"
		detail "download attempt source='$name' url='$url'"
		if run_activity "Downloading Linux $source_version source" curl --fail --location --proto '=https' --tlsv1.2 \
			--retry 2 --connect-timeout 15 --output "$temporary" "$url"; then
			actual=$(sha256sum "$temporary" | awk '{print $1}')
			detail "download SHA-256 source='$name' actual='$actual' expected='$expected_sha256'"
			if [[ "$actual" == "$expected_sha256" ]]; then
				mv -f -- "$temporary" "$archive"
				download_ok=1
				break
			fi
			warn "Integrity verification failed for $name; trying another trusted source"
		else
			warn "Download failed from $name; trying another trusted source"
		fi
		rm -f -- "$temporary"
	done
	(( download_ok )) || die 'Every trusted kernel source failed download or integrity verification'
	status_ok 'Linux source downloaded and SHA-256 verified'
}

prepare_source_tree() {
	local extract_dir extracted_tree
	fetch_expected_sha256
	build_source="$work_dir/linux-$source_version"
	archive="$work_dir/linux-$source_version.tar.xz"
	mkdir -p "$work_dir"
	if source_tree_valid "$build_source"; then
		status_ok 'Valid cached Linux source reused'
		return
	fi
	if [[ -e "$build_source" ]]; then
		detail "removing unverified source cache: $build_source"
		[[ "$build_source" == "$work_dir"/linux-* ]] || die 'Refusing unsafe source-cache removal target'
		rm -rf -- "$build_source"
	fi
	if archive_valid "$archive"; then
		status_ok 'Valid cached source archive reused'
	else
		[[ ! -e "$archive" ]] || { detail "removing invalid archive cache: $archive"; rm -f -- "$archive"; }
		download_archive
	fi
	extract_dir="$work_dir/.extract-$source_version-$$"
	rm -rf -- "$extract_dir"
	mkdir -p "$extract_dir"
	run_activity "Extracting Linux $source_version source" tar -C "$extract_dir" -xf "$archive" || die 'Linux source extraction failed'
	extracted_tree="$extract_dir/linux-$source_version"
	[[ -f "$extracted_tree/Makefile" && -f "$extracted_tree/drivers/input/mouse/synaptics.c" ]] || die 'Extracted archive does not contain the expected Linux source tree'
	printf '%s\n' "$expected_sha256" >"$extracted_tree/.touchpad-source-sha256"
	mv -- "$extracted_tree" "$build_source"
	rm -rf -- "$extract_dir"
	status_ok 'Linux source extracted'
}

prepare_source() {
	if (( dry_run )); then
		build_source=${source_dir:-$work_dir/linux-$source_version}
		notice "Would prepare, verify, patch, and configure $build_source"
		return
	fi
	if [[ -n "$source_dir" ]]; then
		build_source=$source_dir
		detail "using user-supplied source tree: $build_source"
	else
		prepare_source_tree
	fi
	run_logged "$patcher" "$build_source" || die 'Touchpad source patch failed'
	status_ok 'Touchpad patch applied'
	if [[ "$config_source" == /proc/config.gz ]]; then
		run_logged bash -c 'gzip -cd "$1" >"$2"' _ "$config_source" "$build_source/.config" || die 'Kernel configuration copy failed'
	else
		run_logged cp -- "$config_source" "$build_source/.config" || die 'Kernel configuration copy failed'
	fi
	if [[ -x "$build_source/scripts/config" ]]; then
		run_logged "$build_source/scripts/config" --file "$build_source/.config" \
			--set-str SYSTEM_TRUSTED_KEYS '' --set-str SYSTEM_REVOCATION_KEYS '' || die 'Kernel certificate configuration failed'
	fi
	printf '%s\n' "-$local_suffix" >"$build_source/localversion.10-t14-touchpad-patch"
	run_logged make -C "$build_source" olddefconfig || die 'Kernel olddefconfig failed'
	status_ok 'Kernel source configured'
}

extract_compiler_error() {
	local errors
	errors=$(sed 's/\x1b\[[0-9;]*m//g' "$compiler_log" | grep -E 'fatal error:|(^|[^[:alpha:]])error:|undefined reference|No rule to make target|BTF:.*FAILED|FAILED:' | grep -vE '^make(\[[0-9]+\])?: \*\*\*' | head -n 8 || true)
	if [[ -z "$errors" ]]; then
		errors=$(tail -n 20 "$compiler_log")
	fi
	printf '%s\n' "$errors"
}

compile_kernel() {
	local build_pid build_status elapsed frame spinner tick start
	compiler_log="$project_dir/logs/$(date +%Y%m%d-%H%M%S-%N)-kernel-build.log"
	mkdir -p "$(dirname "$compiler_log")"
	detail "compiler log: $compiler_log"
	detail "+ make -C $(printf %q "$build_source") -j $(printf %q "$jobs")"
	if (( verbose )); then
		make -C "$build_source" -j "$jobs" > >(tee -a "$compiler_log") 2> >(tee -a "$compiler_log" >&2) &
	else
		make -C "$build_source" -j "$jobs" >"$compiler_log" 2>&1 &
	fi
	build_pid=$!
	start=$SECONDS
	spinner='|/-\'
	tick=0
	while kill -0 "$build_pid" 2>/dev/null; do
		elapsed=$(format_elapsed "$(( SECONDS - start ))")
		if [[ -t 0 ]] && (( ! verbose )); then
			frame=${spinner:tick%4:1}
			printf '\r%s Building patched kernel... %s' "$frame" "$elapsed"
		elif [[ ! -t 0 && $tick -gt 0 && $(( tick % 30 )) -eq 0 ]]; then
			detail "kernel compilation still active after $elapsed"
		fi
		tick=$(( tick + 1 ))
		sleep 1
	done
	if [[ -t 0 ]] && (( ! verbose )); then
		printf '\r\033[K'
	fi
	if wait "$build_pid"; then build_status=0; else build_status=$?; fi
	elapsed=$(format_elapsed "$(( SECONDS - start ))")
	{
		printf '\n[%s] ===== compiler output =====\n' "$(timestamp)"
		cat "$compiler_log"
		printf '[%s] ===== end compiler output (status %s) =====\n' "$(timestamp)" "$build_status"
	} >>"$log_file"
	if (( build_status != 0 )); then
		printf '\n✗ Kernel build failed\n\nCompiler error:\n' >&2
		extract_compiler_error >&2
		printf '\n' >&2
		die "Kernel compilation failed after $elapsed" "$build_status"
	fi
	detail "kernel compilation completed in $elapsed"
	status_ok "Kernel built successfully in $elapsed"
}

build_kernel() {
	prepare_source
	(( dry_run )) && { notice "Would patch and build $build_source"; return; }
	compile_kernel
	built_release=$(make -s -C "$build_source" kernelrelease)
	[[ "$built_release" == *"-$local_suffix" ]] || die "Unexpected kernel release: $built_release"
	[[ -f "$build_source/arch/x86/boot/bzImage" ]] || die 'x86 kernel image was not produced'
	printf '%s\n' "$build_source" >"$work_dir/.last-source"
	printf '%s\n' "$built_release" >"$work_dir/.last-release"
	detail "built release: $built_release"
}

load_build_state() {
	[[ -n "$source_dir" ]] && build_source=$source_dir
	[[ -n "${build_source:-}" && -d "$build_source" ]] || build_source=$(cat "$work_dir/.last-source" 2>/dev/null || true)
	[[ -d "${build_source:-}" ]] || die 'No completed build was found; run build first'
	built_release=$(make -s -C "$build_source" kernelrelease)
	[[ "$built_release" == *"-$local_suffix" ]] || die "Refusing unexpected release: $built_release"
}

generate_initramfs() {
	case "$adapter" in
		fedora|suse) run_logged sudo dracut --force "/boot/initramfs-$built_release.img" "$built_release" ;;
		debian) run_logged sudo update-initramfs -c -k "$built_release" ;;
		arch) run_logged sudo mkinitcpio -k "$built_release" -g "/boot/initramfs-$built_release.img" ;;
		generic) run_logged sudo dracut --force "/boot/initramfs-$built_release.img" "$built_release" ;;
	esac || die 'Initramfs generation failed'
	status_ok 'Initramfs generated'
}

find_grub_config() {
	local candidate
	for candidate in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
		if sudo test -r "$candidate"; then grub_config=$candidate; return 0; fi
	done
	return 1
}

grub_entry_identifier() {
	local config_copy="$work_dir/.grub-config-$$"
	# sudo is intentionally limited to reading the protected GRUB file; the
	# redirected audit copy belongs to the invoking user in the quoted work dir.
	# shellcheck disable=SC2024
	sudo cat "$grub_config" >"$config_copy" || return 1
	python3 - "$config_copy" "$built_release" <<'PY'
import shlex
import sys

path, release = sys.argv[1:]
depth = 0
submenus = []

def parsed_entry(line):
    try:
        tokens = shlex.split(line, posix=True)
    except ValueError:
        return None, None
    if len(tokens) < 2:
        return None, None
    title = tokens[1]
    identifier = title
    if "$menuentry_id_option" in tokens:
        index = tokens.index("$menuentry_id_option")
        if index + 1 < len(tokens):
            identifier = tokens[index + 1]
    return title, identifier

with open(path, encoding="utf-8", errors="replace") as handle:
    for line in handle:
        stripped = line.lstrip()
        while submenus and depth < submenus[-1][0]:
            submenus.pop()
        if stripped.startswith("submenu "):
            _, identifier = parsed_entry(stripped)
            if identifier:
                submenus.append((depth + 1, identifier))
        elif stripped.startswith("menuentry ") and release in stripped:
            _, identifier = parsed_entry(stripped)
            if identifier:
                print(">".join([item[1] for item in submenus] + [identifier]))
                raise SystemExit(0)
        depth += line.count("{") - line.count("}")
raise SystemExit(1)
PY
	local status=$?
	rm -f -- "$config_copy"
	return "$status"
}

configure_debian_grub() {
	run_logged sudo update-grub || die 'GRUB configuration update failed'
	find_grub_config || die 'Generated GRUB configuration was not found'
	sudo grep -Fq "$built_release" "$grub_config" || die 'Patched kernel is absent from the generated GRUB configuration'
	detail "patched kernel found in GRUB config: $grub_config"
	local entry environment
	if ! sudo grep -Fq 'next_entry' "$grub_config"; then
		warn 'Patched kernel is in GRUB, but this configuration does not consume a one-time next_entry; no default was guessed'
		return 0
	fi
	if entry=$(grub_entry_identifier); then
		detail "generated GRUB next-boot entry: $entry"
		if run_logged sudo grub-reboot "$entry"; then
			environment=$(sudo grub-editenv list 2>>"$log_file" || true)
			detail "grub environment after grub-reboot: $environment"
			if grep -Fq "next_entry=$entry" <<<"$environment"; then
				status_ok 'Patched kernel selected for next boot'
				return
			fi
		fi
	fi
	warn 'Patched kernel is in GRUB, but automatic next-boot selection could not be safely verified; select it from Advanced options'
}

refresh_bootloader() {
	case "$adapter" in
		debian) configure_debian_grub ;;
		fedora)
			run_logged sudo kernel-install add "$built_release" "/boot/vmlinuz-$built_release" || die 'kernel-install failed'
			run_logged sudo grubby --set-default "/boot/vmlinuz-$built_release" || die 'grubby default selection failed'
			[[ "$(sudo grubby --default-kernel 2>>"$log_file")" == "/boot/vmlinuz-$built_release" ]] || die 'grubby did not retain the patched kernel as default'
			status_ok 'Patched kernel selected for next boot'
			;;
		suse)
			run_logged sudo kernel-install add "$built_release" "/boot/vmlinuz-$built_release" || die 'kernel-install failed'
			run_logged sudo grub2-mkconfig -o /boot/grub2/grub.cfg || die 'GRUB2 update failed'
			warn 'Bootloader updated, but automatic next-boot selection is not yet safely implemented for openSUSE'
			;;
		arch)
			if command -v sdboot-manage >/dev/null && [[ -f /etc/sdboot-manage.conf ]]; then
				run_logged sudo sdboot-manage gen || die 'CachyOS systemd-boot entry generation failed'
			elif command -v limine-mkinitcpio >/dev/null && [[ -f /etc/default/limine ]]; then
				run_logged sudo limine-mkinitcpio || die 'CachyOS Limine entry generation failed'
			elif command -v grub-mkconfig >/dev/null && [[ -d /boot/grub ]]; then
				run_logged sudo grub-mkconfig -o /boot/grub/grub.cfg || die 'GRUB update failed'
			elif [[ -f /boot/refind_linux.conf ]]; then
				warn 'rEFInd detected; verify that its automatic kernel scan exposes the custom kernel'
			else
				die 'No supported Arch/CachyOS boot-manager integration was detected for the custom kernel'
			fi
			warn 'Boot files installed; select and verify the custom Arch/CachyOS boot entry'
			;;
		generic)
			run_logged sudo kernel-install add "$built_release" "/boot/vmlinuz-$built_release" || die 'kernel-install failed'
			warn 'Boot files installed; the generic adapter cannot safely select a default entry'
			;;
	esac
	status_ok 'Bootloader updated'
}

verify_installation() {
	local initramfs stock_kernel stock_release
	[[ -f "/boot/vmlinuz-$built_release" ]] || die 'Installed patched kernel image is missing'
	[[ -d "/lib/modules/$built_release" ]] || die 'Installed patched module tree is missing'
	case "$adapter" in
		debian) initramfs="/boot/initrd.img-$built_release" ;;
		*) initramfs="/boot/initramfs-$built_release.img" ;;
	esac
	[[ -f "$initramfs" ]] || die "Installed initramfs is missing: $initramfs"
	stock_kernel=
	for candidate in /boot/vmlinuz-*; do
		[[ -f "$candidate" ]] || continue
		[[ "$candidate" == "/boot/vmlinuz-$built_release" ]] && continue
		[[ "$candidate" == *"-$local_suffix" ]] && continue
		stock_kernel=$candidate
		break
	done
	[[ -n "$stock_kernel" ]] || die 'No stock distribution kernel remains available as a fallback'
	stock_release=${stock_kernel#/boot/vmlinuz-}
	detail "verified kernel='/boot/vmlinuz-$built_release' modules='/lib/modules/$built_release' initramfs='$initramfs' stock_fallback='$stock_kernel'"
	if [[ "$adapter" == debian ]]; then
		find_grub_config || die 'GRUB configuration is unavailable during final validation'
		sudo grep -Fq "$built_release" "$grub_config" || die 'GRUB does not contain the patched kernel'
		sudo grep -Fq "$stock_release" "$grub_config" || die 'GRUB does not contain the stock fallback kernel'
	fi
	status_ok 'Kernel installed'
	status_ok 'Bootloader contains patched kernel'
	status_ok 'Stock kernels preserved'
}

install_kernel() {
	detect_platform
	load_build_state
	[[ "$(uname -r)" != "$built_release" ]] || die 'Refusing to overwrite the running kernel'
	ensure_sudo
	run_logged sudo make -C "$build_source" modules_install INSTALL_MOD_STRIP=1 || die 'Module installation failed'
	run_logged sudo install -m 0644 "$build_source/arch/x86/boot/bzImage" "/boot/vmlinuz-$built_release" || die 'Kernel image installation failed'
	run_logged sudo install -m 0644 "$build_source/System.map" "/boot/System.map-$built_release" || die 'System.map installation failed'
	run_logged sudo install -m 0644 "$build_source/.config" "/boot/config-$built_release" || die 'Kernel config installation failed'
	generate_initramfs
	refresh_bootloader
	verify_installation
	detail "installed $built_release; build_source=$build_source"
}

verify_kernel() {
	local running
	running=$(uname -r)
	if [[ "$running" != *"-$local_suffix" && "$running" != *-t14ps2quirk1 ]]; then
		die "Running '$running', not a recognized T14 LEN2068 touchpad patch kernel"
	fi
	grep -q 'SynPS/2 Synaptics TouchPad' /proc/bus/input/devices || die 'SynPS/2 touchpad is not registered'
	if grep -q 'Synaptics TM3471' /proc/bus/input/devices; then die 'Native RMI4 input device is still registered'; fi
	status_ok "Already running patched kernel $running"
	status_ok 'SynPS/2 verified; native TM3471 RMI4 input absent'
}

uninstall_kernel() {
	local release=${kernel_version:-}
	[[ -n "$release" ]] || release=$(cat "$work_dir/.last-release" 2>/dev/null || true)
	[[ "$release" == *"-$local_suffix" ]] || die 'Use --kernel with the complete custom release, or retain .last-release'
	[[ "$(uname -r)" != "$release" ]] || die 'Boot a stock kernel before uninstalling the currently running kernel'
	ensure_sudo
	if command -v kernel-install >/dev/null; then run_logged sudo kernel-install remove "$release"; fi
	if [[ "$adapter" == debian ]] && command -v update-initramfs >/dev/null; then run_logged sudo update-initramfs -d -k "$release" || true; fi
	for path in "/boot/vmlinuz-$release" "/boot/initramfs-$release.img" "/boot/initrd.img-$release" "/boot/System.map-$release" "/boot/config-$release"; do
		[[ ! -e "$path" ]] || run_logged sudo rm -f -- "$path"
	done
	[[ ! -d "/lib/modules/$release" ]] || run_logged sudo rm -rf -- "/lib/modules/$release"
	status_ok "Removed only $release; stock kernels were untouched"
}

detail "installer version=$tool_version action=$action verbose=$verbose dry_run=$dry_run keep_build=$keep_build"
case "$action" in
	preflight) preflight ;;
	build) preflight; build_kernel ;;
	install) detect_platform; install_kernel ;;
	all)
		preflight
		build_kernel
		if (( dry_run )); then notice 'Would install the patched kernel, generate its initramfs, update the bootloader, and verify stock fallback entries'; else install_kernel; fi
		;;
	verify) verify_kernel ;;
	uninstall) detect_platform; uninstall_kernel ;;
esac
