#!/usr/bin/env bash
set -euo pipefail

tool_version=3.0.3
token=psmouse.synaptics_intertouch=0
conflict=psmouse.synaptics_intertouch=1
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
editor="$project_dir/scripts/t14-ps2-kernel-arg.py"
grub_entry_helper="$project_dir/scripts/t14-ps2-grub-entry.py"
machine_inventory_helper="$project_dir/scripts/t14-ps2-machine-inventory.py"
state_dir=/var/lib/t14-len2068-touchpad-patch
state_file=$state_dir/native-state
verbose=0
assume_yes=0
action=status
status_query=0
temporary_grub_mount=

cleanup() {
	local mount_point=${temporary_grub_mount:-} cleanup_status=0
	[[ -n "$mount_point" ]] || return 0
	temporary_grub_mount=
	if sudo_run umount -- "$mount_point"; then
		log "temporary GRUB filesystem unmounted: $mount_point"
	else
		printf '[native] ERROR: temporary GRUB filesystem could not be unmounted: %s\n' "$mount_point" >&2
		cleanup_status=1
	fi
	if sudo_run rmdir -- "$mount_point"; then
		log "temporary GRUB mount point removed: $mount_point"
	else
		printf '[native] ERROR: temporary GRUB mount point could not be removed: %s\n' "$mount_point" >&2
		cleanup_status=1
	fi
	return "$cleanup_status"
}

on_exit() {
	local status=$?
	trap - EXIT HUP INT TERM
	if ! cleanup && (( status == 0 )); then status=1; fi
	exit "$status"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
	cat <<EOF
Usage: $0 [--verbose] [--yes] [inventory|preflight|status|apply|verify|rollback-capability|rollback|complete-rollback]

Prefer the stock distribution kernel by managing psmouse.synaptics_intertouch=0
through the active boot manager. No kernel is compiled by this tool.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--verbose) verbose=1; shift ;;
		--yes) assume_yes=1; shift ;;
		-h|--help) usage; exit 0 ;;
		inventory|preflight|status|apply|verify|rollback-capability|rollback|complete-rollback) action=$1; shift ;;
		*) usage >&2; printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done

log() { if (( status_query )); then printf '[native] %s\n' "$*" >&2; else printf '[native] %s\n' "$*"; fi; }
detail() { (( ! verbose )) || { if (( status_query )); then printf '[native detail] %s\n' "$*" >&2; else printf '[native detail] %s\n' "$*"; fi; }; }
die() { printf '[native] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "required command not found: $1"; }
read_dmi() { [[ -r "/sys/class/dmi/id/$1" ]] && tr -d '\n' <"/sys/class/dmi/id/$1" || true; }

sudo_run() {
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then
		if [[ -n ${TOUCHPAD_PATCHER_TEST_SUDO_RUNNER:-} ]]; then "$TOUCHPAD_PATCHER_TEST_SUDO_RUNNER" "$@"; else "$@"; fi
	else
		sudo "$@"
	fi
}

privileged_path_status() {
	local path=$1 kind=${2:-any}
	sudo_run python3 -c '
import os, stat, sys
path, kind = sys.argv[1:]
try:
    mode = os.stat(path).st_mode
except FileNotFoundError:
    raise SystemExit(3)
except OSError as error:
    print(error, file=sys.stderr)
    raise SystemExit(4)
matches = kind == "any" or (kind == "file" and stat.S_ISREG(mode)) or (kind == "dir" and stat.S_ISDIR(mode))
raise SystemExit(0 if matches else 3)
' "$path" "$kind"
}

require_privileged_path() {
	local description=$1 path=$2 kind=${3:-any} status
	set +e
	privileged_path_status "$path" "$kind"
	status=$?
	set -e
	case "$status" in
		0) return 0 ;;
		3) die "$description is not present: $path" ;;
		*) die "$description could not be inspected with administrator privileges: $path" ;;
	esac
}

root_path() {
	local path=$1
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then printf '%s%s' "${TOUCHPAD_PATCHER_TEST_ROOT:?}" "$path"; else printf '%s' "$path"; fi
}

cmdline_value() {
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then cat "$(root_path /proc/cmdline)"; else cat /proc/cmdline; fi
}

input_devices_path() { root_path /proc/bus/input/devices; }

hardware_guard() {
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then
		[[ ${TOUCHPAD_PATCHER_TEST_HARDWARE_LOG:-0} != 1 ]] || log 'ThinkPad T14 Gen 1 with LEN2068 detected'
		return
	fi
	local vendor product version firmware_file firmware_id found=0
	vendor=$(read_dmi sys_vendor)
	product=$(read_dmi product_name)
	version=$(read_dmi product_version)
	[[ "$vendor" == LENOVO* ]] || die 'this guarded fix is only for Lenovo hardware'
	[[ "$product $version" == *'ThinkPad T14 Gen 1'* ]] || die "ThinkPad T14 Gen 1 was not detected (product='$product', version='$version')"
	for firmware_file in /sys/bus/serio/devices/*/firmware_id; do
		[[ -r "$firmware_file" ]] || continue
		firmware_id=$(<"$firmware_file")
		[[ "$firmware_id" == *LEN2068* ]] && { found=1; break; }
	done
	(( found )) || die 'LEN2068 was not found in readable serio firmware IDs'
	log 'ThinkPad T14 Gen 1 with LEN2068 detected'
}

kernel_supports_parameter() {
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then
		[[ -e "$(root_path /sys/module/psmouse/parameters/synaptics_intertouch)" ]]
		return
	fi
	[[ -e /sys/module/psmouse/parameters/synaptics_intertouch ]] && return 0
	modinfo -p psmouse 2>/dev/null | grep -q '^synaptics_intertouch:'
}

candidate_exists() { privileged_path_status "$(root_path "$1")" >/dev/null 2>&1; }

read_active_efi_entry() {
	[[ -n ${active_efi_loader_path:-} ]] && return 0
	need efibootmgr
	local output current line entry
	local file_pattern='File\(([^)]*)\)'
	local hd_pattern='HD\([^,]+,[Gg][Pp][Tt],([^,]+),'
	output=$(sudo_run efibootmgr -v 2>/dev/null) || die 'UEFI BootCurrent information could not be read with administrator privileges using efibootmgr'
	current=$(sed -n 's/^BootCurrent:[[:space:]]*//p' <<<"$output" | head -n1)
	[[ "$current" =~ ^[[:xdigit:]]{4}$ ]] || die 'UEFI BootCurrent is missing or invalid; the active boot chain is ambiguous'
	line=$(awk -v wanted="${current^^}" '
		match($0, /^Boot([[:xdigit:]]{4})/) {
			id = toupper(substr($0, RSTART + 4, 4))
			if (id == wanted) { print; exit }
		}
	' <<<"$output")
	[[ -n "$line" ]] || die "UEFI BootCurrent $current has no matching verbose boot entry"
	entry=${line#Boot????}
	entry=${entry#\*}
	entry=${entry# }
	active_efi_label=${entry%%HD(*}
	active_efi_label=${active_efi_label% }
	if [[ "$line" =~ $file_pattern ]]; then
		active_efi_loader_path=${BASH_REMATCH[1]}
	elif [[ "$line" == *')/\EFI\'* ]]; then
		# efibootmgr may render a filepath device node directly after HD(...)/
		# instead of wrapping it as File(...).
		active_efi_loader_path=${line#*)/}
		[[ "${active_efi_loader_path,,}" == \\efi\\*.efi ]] || \
			die "UEFI BootCurrent $current exposes an invalid direct EFI loader path"
	else
		die "UEFI BootCurrent $current does not expose an EFI loader path"
	fi
	if [[ "$line" =~ $hd_pattern ]]; then active_efi_partuuid=${BASH_REMATCH[1]}; else die "UEFI BootCurrent $current does not expose a GPT EFI partition UUID"; fi
	active_efi_loader_fs=${active_efi_loader_path//\\//}
	active_efi_loader_compare=${active_efi_loader_fs,,}
	if [[ "$active_efi_loader_compare" =~ /efi/([^/]+)/ ]]; then active_efi_vendor=${BASH_REMATCH[1]}; else die "UEFI loader path is outside a recognisable EFI vendor directory: $active_efi_loader_path"; fi
	active_efi_id=${current^^}
	detail "BootCurrent=$active_efi_id label='$active_efi_label' loader='$active_efi_loader_path' partuuid='$active_efi_partuuid' vendor='$active_efi_vendor'"
}

active_esp_mount() {
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then
		printf '%s\n' "$(root_path /boot/efi)"
		return
	fi
	local part_link device mount
	part_link="/dev/disk/by-partuuid/$active_efi_partuuid"
	require_privileged_path "active EFI partition $active_efi_partuuid" "$part_link"
	device=$(sudo_run readlink -f -- "$part_link") || die "active EFI partition link could not be resolved with administrator privileges: $part_link"
	mount=$(sudo_run findmnt -rn -S "$device" -o TARGET | head -n1)
	[[ -n "$mount" ]] || die "active EFI partition $active_efi_partuuid is not mounted; its GRUB chain cannot be verified"
	printf '%s\n' "$mount"
}

running_root_uuid() {
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then
		printf '%s\n' "${TOUCHPAD_PATCHER_TEST_ROOT_UUID:-test}"
		return
	fi
	local uuid
	uuid=$(sudo_run findmnt -rn -T / -o UUID | head -n1)
	[[ -n "$uuid" ]] || die 'the current root filesystem UUID could not be determined'
	printf '%s\n' "$uuid"
}

running_kernel() {
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then printf '%s\n' "${TOUCHPAD_PATCHER_TEST_UNAME_R:-$(uname -r)}"; else uname -r; fi
}

find_existing_mount() {
	local device=$1 output status
	set +e
	output=$(sudo_run findmnt -rn -S "$device" -o TARGET 2>/dev/null)
	status=$?
	set -e
	case "$status" in
		0)
			mount_dir=${output%%$'\n'*}
			[[ -n "$mount_dir" ]] || die "findmnt succeeded but returned no mount point for the active GRUB device: $device"
			log "active GRUB filesystem already mounted: $device → $mount_dir"
			;;
		1)
			mount_dir=
			log "active GRUB filesystem is not mounted: $device"
			;;
		*) die "findmnt failed while inspecting the active GRUB device $device (status $status)" ;;
	esac
}

resolve_grub_filesystem() {
	local uuid=$1 device mount_dir
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then
		if [[ ${TOUCHPAD_PATCHER_TEST_FORCE_TEMP_MOUNT:-0} == 1 ]]; then
			device=$(root_path "/devices/$uuid")
			require_privileged_path "test GRUB filesystem device (UUID=$uuid)" "$device" dir
			find_existing_mount "$device"
			if [[ -n "$mount_dir" ]]; then
				active_grub_mount=$mount_dir
			else
				temporary_grub_mount=$(root_path "/run/t14-len2068-touchpad-patch/grub-$uuid")
				sudo_run mkdir -p -- "$temporary_grub_mount"
				log "mounting active GRUB filesystem read-only: $device → $temporary_grub_mount"
				sudo_run mount -o ro -- "$device" "$temporary_grub_mount" || die "test GRUB filesystem could not be mounted read-only: UUID=$uuid"
				active_grub_mount=$temporary_grub_mount
			fi
			active_grub_is_local=0
			return
		fi
		active_grub_mount=$(root_path "/filesystems/$uuid")
		if privileged_path_status "$active_grub_mount" dir >/dev/null 2>&1; then active_grub_is_local=0; else active_grub_mount=$(root_path /); active_grub_is_local=1; fi
		return
	fi
	device="/dev/disk/by-uuid/$uuid"
	require_privileged_path "filesystem referenced by the active GRUB stub (UUID=$uuid)" "$device"
	device=$(sudo_run readlink -f -- "$device") || die "the active GRUB filesystem device could not be resolved with administrator privileges: UUID=$uuid"
	log "active GRUB filesystem resolved: UUID=$uuid → $device"
	find_existing_mount "$device"
	if [[ -n "$mount_dir" ]]; then
		active_grub_mount=$mount_dir
	else
		temporary_grub_mount="/run/t14-len2068-touchpad-patch/grub-${uuid,,}"
		sudo_run mkdir -p -- "$temporary_grub_mount"
		log "mounting active GRUB filesystem read-only: $device → $temporary_grub_mount"
		sudo_run mount -o ro -- "$device" "$temporary_grub_mount" || die "the filesystem referenced by the active GRUB stub could not be mounted read-only: UUID=$uuid"
		active_grub_mount=$temporary_grub_mount
	fi
	local root_uuid boot_uuid
	root_uuid=$(sudo_run findmnt -rn -T / -o UUID | head -n1)
	boot_uuid=$(sudo_run findmnt -rn -T /boot -o UUID | head -n1)
	if [[ "${uuid,,}" == "${root_uuid,,}" || "${uuid,,}" == "${boot_uuid,,}" ]]; then active_grub_is_local=1; else active_grub_is_local=0; fi
}

read_current_grub_entry() {
	local content result status key value
	if ! content=$(sudo_run cat -- "$grub_generated_config" 2>/dev/null); then
		die "the active downstream GRUB configuration could not be read with administrator privileges: $grub_generated_config"
	fi
	set +e
	result=$(python3 "$grub_entry_helper" "$current_root_uuid" "$current_kernel" "$token" "$(cmdline_value)" <<<"$content")
	status=$?
	set -e
	case "$status" in
		0) ;;
		2)
			if [[ ${active_efi_vendor:-} == fedora ]] && read_current_bls_entry; then return 0; fi
			die "the active GRUB configuration has no unique entry for root UUID $current_root_uuid and kernel $current_kernel: $grub_generated_config"
			;;
		3) die "the active GRUB configuration has multiple materially different entries for root UUID $current_root_uuid and kernel $current_kernel; the current-system boot target is ambiguous" ;;
		*) die 'the active GRUB entry could not be parsed safely' ;;
	esac
	current_grub_title=
	current_grub_menu_id=
	current_grub_equivalent_entries=1
	current_grub_os_prober=0
	current_grub_has_token=0
	while IFS='=' read -r key value; do
		case "$key" in
			title) current_grub_title=$value ;;
			menu_id) current_grub_menu_id=$value ;;
			equivalent_entries) current_grub_equivalent_entries=$value ;;
			os_prober) current_grub_os_prober=$value ;;
			token) current_grub_has_token=$value ;;
		esac
	done <<<"$result"
	[[ -n "$current_grub_title" ]] || die 'the active GRUB entry parser returned no menu title'
	if (( current_grub_equivalent_entries > 1 )); then
		log "collapsed $current_grub_equivalent_entries equivalent normal GRUB entries into one logical target${current_grub_menu_id:+ (menu ID $current_grub_menu_id)}"
	fi
}

read_current_bls_entry() {
	local directory candidate content version linux options root_match=0 matches=0 selected=''
	for directory in "$active_grub_mount/boot/loader/entries" "$active_grub_mount/loader/entries"; do
		if ! privileged_path_status "$directory" dir >/dev/null 2>&1; then continue; fi
		while IFS= read -r candidate; do
			content=$(sudo_run cat -- "$candidate") || die "Fedora BLS entry could not be read with administrator privileges: $candidate"
			version=$(sed -n 's/^version[[:space:]]\+//p' <<<"$content" | head -n1)
			linux=$(sed -n 's/^linux[[:space:]]\+//p' <<<"$content" | head -n1)
			options=$(sed -n 's/^options[[:space:]]\+//p' <<<"$content" | head -n1)
			[[ "$version" == "$current_kernel" || "${linux##*/}" == "vmlinuz-$current_kernel" ]] || continue
			root_match=0
			grep -Fqw "root=UUID=$current_root_uuid" <<<"$options" && root_match=1
			# Fedora BLS commonly uses root=UUID, but permit a unique kernel match when
			# the root is expressed through a mapper/device path.
			if (( root_match || matches == 0 )); then selected=$candidate; fi
			((matches += 1))
		done < <(sudo_run find "$directory" -maxdepth 1 -type f -name '*.conf' -print | sort)
	done
	(( matches == 1 )) || return 1
	content=$(sudo_run cat -- "$selected") || return 1
	options=$(sed -n 's/^options[[:space:]]\+//p' <<<"$content" | head -n1)
	current_grub_title=$(sed -n 's/^title[[:space:]]\+//p' <<<"$content" | head -n1)
	current_grub_title=${current_grub_title:-Fedora Linux $current_kernel}
	current_grub_menu_id=${selected##*/}
	current_grub_menu_id=${current_grub_menu_id%.conf}
	current_grub_equivalent_entries=1
	current_grub_os_prober=0
	current_grub_has_token=0
	grep -Fqw "$token" <<<"$options" && current_grub_has_token=1
	current_grub_is_bls=1
	log "current Fedora installation identified through BLS: $current_grub_menu_id"
	return 0
}

inspect_fedora_saved_entry() {
	[[ "$active_efi_vendor" == fedora ]] || return 0
	local grubenv content saved candidate status
	local -a grubenv_candidates=(
		"$(dirname "$grub_generated_config")/grubenv"
		"$active_grub_mount/boot/grub2/grubenv"
	)
	local -A checked=()
	for candidate in "${grubenv_candidates[@]}"; do
		[[ -z ${checked[$candidate]:-} ]] || continue
		checked[$candidate]=1
		set +e
		privileged_path_status "$candidate" file >/dev/null 2>&1
		status=$?
		set -e
		case "$status" in
			0) grubenv=$candidate; break ;;
			3) ;;
			*) die "Fedora GRUB environment could not be inspected with administrator privileges: $candidate" ;;
		esac
	done
	[[ -n ${grubenv:-} ]] || return 0
	content=$(sudo_run cat -- "$grubenv") || die "Fedora GRUB environment could not be read with administrator privileges: $grubenv"
	saved=$(sed -n 's/^saved_entry=//p' <<<"$content" | head -n1)
	[[ -n "$saved" ]] || return 0
	log "Fedora GRUB saved/default entry: $saved (independent of the current Mint entry)"
	local -a bls_candidates=(
		"$active_grub_mount/boot/loader/entries/$saved.conf"
		"$active_grub_mount/loader/entries/$saved.conf"
	)
	for candidate in "${bls_candidates[@]}"; do
		set +e
		privileged_path_status "$candidate" file >/dev/null 2>&1
		status=$?
		set -e
		case "$status" in
			0)
				log "Fedora saved entry is backed by BLS: $candidate"
				return 0
				;;
			3) ;;
			*) die "Fedora BLS entry could not be inspected with administrator privileges: $candidate" ;;
		esac
	done
	log 'Fedora saved entry is not a literal menuentry; leaving it intact because Fedora may resolve it through BLS/generated sources'
}

validate_active_grub_chain() {
	local distro_id=$1 distro_like=$2 esp loader stub stub_content chain uuid prefix
	candidate_exists /sys/firmware/efi || { detail 'legacy BIOS GRUB boot detected'; return 0; }
	read_active_efi_entry
	case "$active_efi_loader_compare" in
		*shim*.efi|*grub*.efi) ;;
		*) die "BootCurrent $active_efi_id uses '$active_efi_loader_path', not a recognised GRUB/shim loader" ;;
	esac
	esp=$(active_esp_mount)
	loader="$esp/${active_efi_loader_fs#/}"
	require_privileged_path 'active EFI loader' "$loader" file
	stub="$(dirname "$loader")/grub.cfg"
	require_privileged_path 'active EFI GRUB stub' "$stub" file
	if ! stub_content=$(sudo_run cat -- "$stub" 2>/dev/null); then die "active EFI GRUB stub could not be read with administrator privileges: $stub"; fi
	chain=$(python3 -c '
import re, sys
text = sys.stdin.read()
uuid = ""
for line in text.splitlines():
    if "search" in line and ("fs_uuid" in line or "fs-uuid" in line):
        matches = re.findall(r"(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b|\b[0-9a-f]{8,}\b", line)
        if matches:
            uuid = matches[-1]
            break
prefix = ""
match = re.search(r"(?m)^\s*set\s+prefix\s*=\s*.*?(/(?:boot/)?grub2?)(?:[\x27\x22\s]|$)", text)
if match:
    prefix = match.group(1)
if not uuid or not prefix:
    raise SystemExit(1)
print(f"{uuid}|{prefix}")
' <<<"$stub_content") || die "active EFI GRUB stub does not expose a verifiable filesystem UUID and GRUB prefix: $stub"
	IFS='|' read -r uuid prefix <<<"$chain"
	resolve_grub_filesystem "$uuid"
	grub_generated_config="$active_grub_mount$prefix/grub.cfg"
	require_privileged_path "active downstream GRUB configuration referenced by UUID=$uuid" "$grub_generated_config" file
	current_root_uuid=$(running_root_uuid)
	current_kernel=$(running_kernel)
	read_current_grub_entry
	inspect_fedora_saved_entry
	log "active EFI entry: $active_efi_label (BootCurrent $active_efi_id, EFI/$active_efi_vendor)"
	log "active GRUB chain traced: UUID=$uuid$prefix/grub.cfg"
	log "current installation entry: $current_grub_title (root UUID $current_root_uuid, kernel $current_kernel)"
	if [[ "$current_grub_os_prober" == 1 || "$active_grub_is_local" != 1 ]]; then
		grub_foreign_entry=1
		if [[ "$current_grub_os_prober" == 1 ]]; then
			log "current $distro_id installation is booted through $active_efi_label GRUB via an os-prober-generated entry"
		else
			log "current $distro_id installation is booted through a GRUB configuration owned by another filesystem"
		fi
	fi
}

detect_boot_manager() {
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 && -n ${TOUCHPAD_PATCHER_BOOT_MANAGER:-} ]]; then
		boot_manager=$TOUCHPAD_PATCHER_BOOT_MANAGER
	else
		local boot_status='' current_label=''
		if command -v bootctl >/dev/null; then boot_status=$(bootctl status 2>/dev/null || true); fi
		if grep -qi 'product:.*systemd-boot' <<<"$boot_status"; then
			boot_manager=systemd-boot
		elif command -v efibootmgr >/dev/null && candidate_exists /sys/firmware/efi; then
			read_active_efi_entry
			current_label=$active_efi_label
			case "${active_efi_loader_compare} ${current_label,,}" in
				*limine*) boot_manager=limine ;;
				*refind*) boot_manager=refind ;;
				*grub*|*shim*|*fedora*|*ubuntu*|*debian*|*opensuse*) boot_manager=grub ;;
			esac
		fi
	fi

	if [[ -z ${boot_manager:-} ]]; then
		local -a candidates=()
		(candidate_exists /etc/default/limine || candidate_exists /boot/limine.conf) && candidates+=(limine)
		(candidate_exists /boot/refind_linux.conf || candidate_exists /boot/efi/EFI/refind/refind.conf) && candidates+=(refind)
		(candidate_exists /etc/default/grub && (candidate_exists /boot/grub/grub.cfg || candidate_exists /boot/grub2/grub.cfg)) && candidates+=(grub)
		candidate_exists /boot/loader/loader.conf && candidates+=(systemd-boot)
		(( ${#candidates[@]} == 1 )) || die "active boot manager could not be identified unambiguously (candidates: ${candidates[*]:-none})"
		boot_manager=${candidates[0]}
	fi
	detail "active boot manager: $boot_manager"
}

detect_adapter() {
	detect_boot_manager
	local os_file distro_id='' distro_like='' distro_pretty=''
	os_file=$(root_path /etc/os-release)
	if [[ -r "$os_file" ]]; then
		# shellcheck disable=SC1090
		. "$os_file"
		distro_id=${ID:-}
		distro_like=${ID_LIKE:-}
		distro_pretty=${PRETTY_NAME:-$distro_id}
	fi
	running_os_pretty=${distro_pretty:-${distro_id:-Linux}}
	[[ -z "$distro_pretty" ]] || log "$distro_pretty detected"
	case "$boot_manager" in
		grub)
			adapter=grub; config_path=$(root_path /etc/default/grub); config_format=shell; config_variable=GRUB_CMDLINE_LINUX_DEFAULT
			;;
		systemd-boot)
			if [[ "$distro_id" == cachyos && -e "$(root_path /etc/sdboot-manage.conf)" ]]; then
				adapter=cachyos-systemd-boot; config_path=$(root_path /etc/sdboot-manage.conf); config_format=shell; config_variable=LINUX_OPTIONS
			else
				adapter=systemd-boot; config_path=$(root_path /etc/kernel/cmdline); config_format=raw; config_variable=
			fi
			;;
		limine) adapter=limine; config_path=$(root_path /etc/default/limine); config_format=shell; config_variable='KERNEL_CMDLINE[default]' ;;
		refind) adapter=refind; config_path=$(root_path /boot/refind_linux.conf); config_format=refind; config_variable= ;;
		*) die "unsupported active boot manager: $boot_manager" ;;
	esac
	[[ "$adapter" != grub ]] || require_privileged_path "authoritative $adapter configuration" "$config_path" file
	[[ "$adapter" != grub ]] || validate_active_grub_chain "$distro_id" "$distro_like"
	if [[ ${grub_foreign_entry:-0} == 1 ]]; then
		adapter=grub-foreign
		config_path=$grub_generated_config
		config_format=
		config_variable=
	elif [[ "$boot_manager" == grub ]] && command -v grubby >/dev/null && [[ " $distro_id $distro_like " == *fedora* || " $distro_id $distro_like " == *rhel* ]]; then
		adapter=grubby
		config_path=
		config_format=
		config_variable=
	fi
	log "active boot manager: $boot_manager ($adapter adapter)"
}

machine_inventory() {
	status_query=1
	hardware_guard
	detect_adapter
	if [[ "$boot_manager" != grub ]]; then
		python3 - "$running_os_pretty" "$(running_kernel)" "$token" <<'PY'
import json, sys
name, kernel, token = sys.argv[1:]
patched = any(value in kernel for value in ("t14-len2068-touchpad-patch", "t14ps2quirk1"))
active = token in open("/proc/cmdline", encoding="utf-8").read().split() if not __import__("os").environ.get("TOUCHPAD_PATCHER_TESTING") else False
state = "kernel-patched + native-active" if patched and active else "kernel-patched" if patched else "native-active" if active else "unconfigured"
json.dump({"bootloader_owner": "", "installations": [{"distribution": name, "kernel": kernel, "current": True, "boot_method": "active boot manager", "kernel_patched": patched, "native_configured": active, "remediation": state, "runtime": "current-live-evidence"}]}, sys.stdout, indent=2)
print()
PY
		return
	fi
	current_root_uuid=${current_root_uuid:-$(running_root_uuid)}
	current_kernel=${current_kernel:-$(running_kernel)}
	active_grub_mount=${active_grub_mount:-$(root_path /)}
	if [[ -z ${grub_generated_config:-} ]]; then
		if candidate_exists /boot/grub/grub.cfg; then
			grub_generated_config=$(root_path /boot/grub/grub.cfg)
		elif candidate_exists /boot/grub2/grub.cfg; then
			grub_generated_config=$(root_path /boot/grub2/grub.cfg)
		else
			die 'authoritative GRUB configuration was not found for machine inventory'
		fi
	fi
	local content bls_data='' bls_dir bls_file bls_status
	content=$(sudo_run cat -- "$grub_generated_config") || die "generated GRUB configuration could not be read with administrator privileges: $grub_generated_config"
	for bls_dir in "$active_grub_mount/boot/loader/entries" "$active_grub_mount/loader/entries"; do
		set +e
		privileged_path_status "$bls_dir" dir >/dev/null 2>&1
		bls_status=$?
		set -e
		case "$bls_status" in
			0)
				while IFS= read -r bls_file; do
					bls_data+="@@BLS ${bls_file##*/}"$'\n'
					bls_data+=$(sudo_run cat -- "$bls_file") || die "BLS entry could not be read for machine inventory: $bls_file"
					bls_data+=$'\n'
				done < <(sudo_run find "$bls_dir" -maxdepth 1 -type f -name '*.conf' -print | sort)
				break
				;;
			3) ;;
			*) die "BLS entry directory could not be inspected for machine inventory: $bls_dir" ;;
		esac
	done
	python3 "$machine_inventory_helper" \
		--token "$token" \
		--current-root "$current_root_uuid" \
		--current-kernel "$current_kernel" \
		--current-os "$running_os_pretty" \
		--owner "${active_efi_label:-GRUB}" \
		--bls-data "$bls_data" <<<"$content"
}

regenerate() {
	case "$adapter" in
		grubby) return ;;
		grub)
			if command -v update-grub >/dev/null; then
				grub_generated_config=$(root_path /boot/grub/grub.cfg)
				sudo_run update-grub
			elif command -v grub2-mkconfig >/dev/null && candidate_exists /boot/grub2; then
				grub_generated_config=$(root_path /boot/grub2/grub.cfg)
				sudo_run grub2-mkconfig -o "$grub_generated_config"
			elif command -v grub-mkconfig >/dev/null && candidate_exists /boot/grub; then
				grub_generated_config=$(root_path /boot/grub/grub.cfg)
				sudo_run grub-mkconfig -o "$grub_generated_config"
			else die 'the active GRUB installation has no supported regeneration command'; fi
			log 'GRUB configuration updated'
			;;
		cachyos-systemd-boot) need sdboot-manage; sudo_run sdboot-manage gen ;;
		systemd-boot)
			need kernel-install
			if kernel-install --help 2>&1 | grep -q 'add-all'; then sudo_run kernel-install add-all
			else die 'systemd-boot is active but kernel-install add-all is unavailable'; fi
			;;
		limine) need limine-mkinitcpio; sudo_run limine-mkinitcpio ;;
		refind) : ;;
	esac
}

state_write() {
	local prior_conflict=$1 ownership=${2:-local}
	state_dir=$(root_path /var/lib/t14-len2068-touchpad-patch)
	state_file=$state_dir/native-state
	sudo_run mkdir -p "$state_dir"
	printf 'method=native\nadapter=%q\nboot_manager=%q\nconfig_path=%q\nprior_conflict=%q\nownership=%q\nstatus=pending-verification\n' \
		"$adapter" "$boot_manager" "$config_path" "$prior_conflict" "$ownership" | sudo_run tee "$state_file" >/dev/null
}

load_state() {
	local state_content state_status
	state_file=$(root_path /var/lib/t14-len2068-touchpad-patch/native-state)
	set +e
	privileged_path_status "$state_file" file >/dev/null 2>&1
	state_status=$?
	set -e
	case "$state_status" in
		0) ;;
		3) return 1 ;;
		*) die "patcher state could not be inspected with administrator privileges: $state_file" ;;
	esac
	state_content=$(sudo_run cat -- "$state_file") || die "patcher state could not be read with administrator privileges: $state_file"
	# State is generated by this tool and restricted to simple values.
	# shellcheck disable=SC1091
	. /dev/stdin <<<"$state_content"
}

config_contains_token() {
	if [[ "$adapter" == grubby ]]; then
		sudo_run grubby --info=ALL 2>/dev/null | grep -Fq "$token"
	elif [[ "$adapter" == grub-foreign ]]; then
		read_current_grub_entry
		[[ "$current_grub_has_token" == 1 ]]
	else
		local -a command=(python3 "$editor" check "$config_format" "$config_path")
		[[ -z "$config_variable" ]] || command+=("$config_variable")
		sudo_run "${command[@]}"
	fi
}

grub_generated_token_status() {
	local candidate content path_status
	local found_config=0 unreadable=0
	local -A checked=()
	local -a candidates=()
	[[ -z ${grub_generated_config:-} ]] || candidates+=("$grub_generated_config")
	candidates+=(
		"$(root_path /boot/grub/grub.cfg)"
		"$(root_path /boot/grub2/grub.cfg)"
		"$(root_path /etc/grub2.cfg)"
		"$(root_path /etc/grub2-efi.cfg)"
	)
	grub_checked_paths=
	grub_unreadable_paths=
	for candidate in "${candidates[@]}"; do
		[[ -n "$candidate" && -z ${checked[$candidate]:-} ]] || continue
		checked[$candidate]=1
		grub_checked_paths+="${grub_checked_paths:+, }$candidate"
		set +e
		privileged_path_status "$candidate" file >/dev/null 2>&1
		path_status=$?
		set -e
		if (( path_status == 3 )); then continue; fi
		if (( path_status != 0 )); then
			unreadable=1
			grub_unreadable_paths+="${grub_unreadable_paths:+, }$candidate (inspection failed)"
			continue
		fi
		found_config=1
		if ! content=$(sudo_run cat -- "$candidate" 2>/dev/null); then
			unreadable=1
			grub_unreadable_paths+="${grub_unreadable_paths:+, }$candidate"
			continue
		fi
		if awk -v required="$token" '
			/^[[:space:]]*(linux|linuxefi|linux16)[[:space:]]/ {
				for (field = 1; field <= NF; field++)
					if ($field == required) found = 1
			}
			END { exit(found ? 0 : 1) }
		' <<<"$content"; then
			grub_verified_path=$candidate
			return 0
		fi
	done
	(( found_config )) || return 3
	(( ! unreadable )) || return 2
	return 1
}

verify_generated_contains_token() {
	case "$adapter" in
		grubby) sudo_run grubby --info=ALL 2>/dev/null | grep -Fq "$token" || die 'generated boot entries do not contain the native parameter' ;;
		grub-foreign)
			read_current_grub_entry
			[[ "$current_grub_has_token" == 1 ]] || die "the active GRUB entry for '$current_grub_title' does not contain the exact argument '$token'"
			log "active GRUB entry verified: $current_grub_title"
			;;
		grub)
			local status
			if [[ -n ${current_root_uuid:-} ]]; then
				read_current_grub_entry
				[[ "$current_grub_has_token" == 1 ]] || die "the active GRUB entry for '$current_grub_title' does not contain the exact argument '$token'"
				log "active GRUB entry verified: $current_grub_title"
				return 0
			fi
			if grub_generated_token_status; then status=0; else status=$?; fi
			case "$status" in
				0) log "generated GRUB kernel entries verified: $grub_verified_path" ;;
				1) die "generated GRUB kernel command lines do not contain the exact argument '$token' (checked: $grub_checked_paths)" ;;
				2) die "generated GRUB configuration could not be read with administrator privileges: $grub_unreadable_paths" ;;
				3) die "generated GRUB configuration was not found (checked: $grub_checked_paths)" ;;
			esac
			;;
		cachyos-systemd-boot|systemd-boot) sudo_run grep -RFq "$token" "$(root_path /boot/loader/entries)" 2>/dev/null || die 'generated boot entries do not contain the native parameter' ;;
		limine) sudo_run grep -Fq "$token" "$(root_path /boot/limine.conf)" 2>/dev/null || die 'generated boot entries do not contain the native parameter' ;;
		refind) sudo_run grep -Fq "$token" "$config_path" || die 'generated boot entries do not contain the native parameter' ;;
	esac
}

verify_generated_absent_token() {
	case "$adapter" in
		grubby)
			if sudo_run grubby --info=ALL 2>/dev/null | grep -Fq "$token"; then die 'generated boot entries still contain the native parameter after rollback'; fi
			return 0
			;;
		cachyos-systemd-boot|systemd-boot)
			if sudo_run grep -RFq "$token" "$(root_path /boot/loader/entries)" 2>/dev/null; then die 'generated boot entries still contain the native parameter after rollback'; fi
			return 0
			;;
		limine)
			if sudo_run grep -Fq "$token" "$(root_path /boot/limine.conf)" 2>/dev/null; then die 'generated boot entries still contain the native parameter after rollback'; fi
			return 0
			;;
		refind)
			if sudo_run grep -Fq "$token" "$config_path"; then die 'generated boot entries still contain the native parameter after rollback'; fi
			return 0
			;;
		grub-foreign)
			read_current_grub_entry
			[[ "$current_grub_has_token" != 1 ]] || die "the active GRUB entry for '$current_grub_title' still contains the native parameter"
			log "active GRUB entry verified without the native parameter: $current_grub_title"
			return 0
			;;
	esac
	if [[ "$adapter" == grub && -n ${current_root_uuid:-} ]]; then
		read_current_grub_entry
		[[ "$current_grub_has_token" != 1 ]] || die "the active GRUB entry for '$current_grub_title' still contains the native parameter after rollback"
		log "active GRUB entry verified without the native parameter: $current_grub_title"
		return 0
	fi
	local status
	if grub_generated_token_status; then status=0; else status=$?; fi
	case "$status" in
		0) die 'generated GRUB kernel entries still contain the native parameter after rollback' ;;
		1) log 'generated GRUB kernel entries verified without the native parameter' ;;
		2) die "generated GRUB configuration could not be read with administrator privileges: $grub_unreadable_paths" ;;
		3) die "generated GRUB configuration was not found (checked: $grub_checked_paths)" ;;
	esac
}

apply_native() {
	hardware_guard
	detect_adapter
	kernel_supports_parameter || return 20
	log 'stock kernel supports the native touchpad parameter'
	if [[ "$adapter" == grub-foreign ]]; then
		local source_note=''
		[[ "$current_grub_os_prober" != 1 ]] || source_note=' and generated by os-prober'
		die "the active entry '$current_grub_title' in $grub_generated_config is owned by $active_efi_label GRUB$source_note; its persistent source cannot be modified safely from the running installation. Boot this installation through its own GRUB entry, or configure '$token' in the bootloader-owning OS and regenerate that GRUB configuration"
	fi
	if config_contains_token; then
		verify_generated_contains_token
		state_write 0
		log 'existing native parameter adopted for verification; reboot if it is not active yet'
		return 0
	fi
	if (( ! assume_yes )) && [[ ${TOUCHPAD_PATCHER_TESTING:-0} != 1 ]]; then
		printf 'Apply %s to the stock-kernel boot configuration? [y/N] ' "$token"
		read -r answer
		[[ "$answer" =~ ^[Yy]$ ]] || die 'cancelled by user'
	fi
	local prior_conflict=0
	if [[ "$adapter" == grubby ]]; then
		sudo_run grubby --info=ALL 2>/dev/null | grep -Fq "$conflict" && prior_conflict=1
		sudo_run grubby --update-kernel=ALL --remove-args="$conflict" --args="$token"
	else
		sudo_run grep -Fq "$conflict" "$config_path" && prior_conflict=1
		local backup="${config_path}.touchpad-patcher-v2-backup"
		local backup_status
		set +e
		privileged_path_status "$backup" >/dev/null 2>&1
		backup_status=$?
		set -e
		case "$backup_status" in
			0) ;;
			3) sudo_run cp -a -- "$config_path" "$backup" ;;
			*) die "boot configuration backup could not be inspected with administrator privileges: $backup" ;;
		esac
		local -a command=(python3 "$editor" add "$config_format" "$config_path")
		[[ -z "$config_variable" ]] || command+=("$config_variable")
		sudo_run "${command[@]}"
	fi
	log 'native touchpad parameter configured'
	regenerate
	config_contains_token || die 'boot configuration regeneration did not retain the native parameter'
	verify_generated_contains_token
	state_write "$prior_conflict"
	log 'native parameter installed and verified in boot configuration; reboot required'
}

verify_native() {
	hardware_guard
	grep -Fqw "$token" <<<"$(cmdline_value)" || die 'the running kernel command line does not contain the native parameter'
	grep -q 'SynPS/2 Synaptics TouchPad' "$(input_devices_path)" || die 'SynPS/2 touchpad is not registered'
	if grep -q 'Synaptics TM3471' "$(input_devices_path)"; then die 'native TM3471 RMI4 input device is still registered'; fi
	local had_state=0 state_adapter='' state_config_path=''
	if load_state; then
		had_state=1
		state_adapter=$adapter
		state_config_path=$config_path
	fi
	detect_adapter
	config_contains_token || die 'native parameter is active but the exact current boot entry has no persistent native parameter'
	if [[ "$adapter" == grub-foreign ]]; then
		state_write 0 external
		sudo_run sed -i 's/^status=.*/status=verified/' "$state_file"
		log "native stock-kernel fix verified for $running_os_pretty: active entry '$current_grub_title', /proc/cmdline, SynPS/2, and TM3471 state all agree"
		log "persistent configuration is externally managed by $active_efi_label GRUB; recognition is complete, but rollback must be performed from the bootloader-owning installation"
		return 0
	fi
	if (( had_state )); then
		[[ "$adapter" == "$state_adapter" && "$config_path" == "$state_config_path" ]] || \
			die "active boot configuration changed since installation (was $state_adapter, now $adapter); refusing to claim managed verification"
	else
		state_write 0
	fi
	sudo_run sed -i 's/^status=.*/status=verified/' "$state_file"
	log 'native stock-kernel fix verified: active boot entry confirmed, SynPS/2 active, and native TM3471 RMI4 absent'
}

rollback_native() {
	hardware_guard
	load_state || die 'no native Touchpad Patcher state was found'
	[[ ${ownership:-local} != external ]] || die 'this verified native configuration is owned by another installation; rollback must be run from the authoritative bootloader owner'
	local state_adapter=$adapter state_config_path=$config_path
	detect_adapter
	[[ "$adapter" == "$state_adapter" && "$config_path" == "$state_config_path" ]] || \
		die "active boot configuration changed since installation (was $state_adapter, now $adapter); refusing automatic rollback"
	local restore_flag=()
	[[ ${prior_conflict:-0} == 1 ]] && restore_flag=(--restore-conflict)
	if [[ "$adapter" == grubby ]]; then
		sudo_run grubby --update-kernel=ALL --remove-args="$token"
		(( ${#restore_flag[@]} == 0 )) || sudo_run grubby --update-kernel=ALL --args="$conflict"
	else
		local -a command=(python3 "$editor" remove "$config_format" "$config_path")
		[[ -z "$config_variable" ]] || command+=("$config_variable")
		command+=("${restore_flag[@]}")
		sudo_run "${command[@]}"
	fi
	regenerate
	config_contains_token && die 'rollback did not remove the native parameter from boot configuration'
	verify_generated_absent_token
	sudo_run sed -i 's/^status=.*/status=rollback-pending-reboot/' "$state_file"
	log 'native parameter removed from boot configuration; reboot required to complete rollback'
}

rollback_capability() {
	if load_state && [[ ${ownership:-local} == external ]]; then
		printf 'external\n'
		return 20
	fi
	printf 'local\n'
}

native_status() {
	if grep -Fqw "$token" <<<"$(cmdline_value)"; then printf 'native-active\n'; return 0; fi
	if load_state; then
		if [[ ${status:-} != rollback-pending-reboot ]]; then
			status_query=1
			detect_adapter
			if config_contains_token; then
				verify_generated_contains_token
			else
				sudo_run rm -f -- "$state_file"
				printf '[native] stale native state cleared because the active persistent boot configuration no longer contains %s\n' "$token" >&2
				printf 'not-managed\n'
				return 20
			fi
		fi
		printf '%s\n' "${status:-native-configured}"
		return 10
	fi
	printf 'not-managed\n'
	return 20
}

complete_rollback() {
	load_state || return 0
	[[ ${status:-} == rollback-pending-reboot ]] || die 'native rollback is not pending'
	grep -Fqw "$token" <<<"$(cmdline_value)" && die 'the native parameter is still active; reboot is required'
	sudo_run rm -f -- "$state_file"
	log 'native rollback verified and patcher state cleared'
}

detail "native manager version=$tool_version action=$action"
case "$action" in
	inventory) machine_inventory ;;
	preflight) hardware_guard; detect_adapter; kernel_supports_parameter || exit 20; log 'native route supported' ;;
	status) native_status ;;
	apply) apply_native ;;
	verify) verify_native ;;
	rollback-capability) rollback_capability ;;
	rollback) rollback_native ;;
	complete-rollback) complete_rollback ;;
esac
