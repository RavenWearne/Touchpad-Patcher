#!/usr/bin/env bash
set -euo pipefail

tool_version=2.0.3
token=psmouse.synaptics_intertouch=0
conflict=psmouse.synaptics_intertouch=1
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
editor="$project_dir/scripts/t14-ps2-kernel-arg.py"
state_dir=/var/lib/t14-len2068-touchpad-patch
state_file=$state_dir/native-state
verbose=0
assume_yes=0
action=status
status_query=0

usage() {
	cat <<EOF
Usage: $0 [--verbose] [--yes] [preflight|status|apply|verify|rollback|complete-rollback]

Prefer the stock distribution kernel by managing psmouse.synaptics_intertouch=0
through the active boot manager. No kernel is compiled by this tool.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--verbose) verbose=1; shift ;;
		--yes) assume_yes=1; shift ;;
		-h|--help) usage; exit 0 ;;
		preflight|status|apply|verify|rollback|complete-rollback) action=$1; shift ;;
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

root_path() {
	local path=$1
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then printf '%s%s' "${TOUCHPAD_PATCHER_TEST_ROOT:?}" "$path"; else printf '%s' "$path"; fi
}

cmdline_value() {
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then cat "$(root_path /proc/cmdline)"; else cat /proc/cmdline; fi
}

input_devices_path() { root_path /proc/bus/input/devices; }

hardware_guard() {
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then return; fi
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

candidate_exists() { [[ -e "$(root_path "$1")" ]]; }

read_active_efi_entry() {
	[[ -n ${active_efi_loader_path:-} ]] && return 0
	need efibootmgr
	local output current line entry
	local file_pattern='File\(([^)]*)\)'
	local hd_pattern='HD\([^,]+,[Gg][Pp][Tt],([^,]+),'
	output=$(efibootmgr -v 2>/dev/null) || die 'UEFI BootCurrent information could not be read with efibootmgr'
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
	if [[ "$line" =~ $file_pattern ]]; then active_efi_loader_path=${BASH_REMATCH[1]}; else die "UEFI BootCurrent $current does not expose an EFI loader path"; fi
	if [[ "$line" =~ $hd_pattern ]]; then active_efi_partuuid=${BASH_REMATCH[1]}; else die "UEFI BootCurrent $current does not expose a GPT EFI partition UUID"; fi
	active_efi_loader_normalized=${active_efi_loader_path//\\//}
	active_efi_loader_normalized=${active_efi_loader_normalized,,}
	if [[ "$active_efi_loader_normalized" =~ /efi/([^/]+)/ ]]; then active_efi_vendor=${BASH_REMATCH[1]}; else die "UEFI loader path is outside a recognisable EFI vendor directory: $active_efi_loader_path"; fi
	active_efi_id=${current^^}
	detail "BootCurrent=$active_efi_id label='$active_efi_label' loader='$active_efi_loader_path' partuuid='$active_efi_partuuid' vendor='$active_efi_vendor'"
}

expected_efi_vendor() {
	local distro_id=$1 distro_like=$2
	case " $distro_id $distro_like " in
		*linuxmint*|*ubuntu*) printf 'ubuntu\n' ;;
		*debian*) printf 'debian\n' ;;
		*fedora*) printf 'fedora\n' ;;
		*rhel*|*centos*|*rocky*|*almalinux*) printf 'redhat\n' ;;
		*opensuse*|*suse*) printf 'opensuse\n' ;;
		*) return 1 ;;
	esac
}

active_esp_mount() {
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then
		printf '%s\n' "$(root_path /boot/efi)"
		return
	fi
	local part_link device mount
	part_link="/dev/disk/by-partuuid/${active_efi_partuuid,,}"
	[[ -e "$part_link" ]] || die "active EFI partition $active_efi_partuuid is not available under /dev/disk/by-partuuid"
	device=$(readlink -f -- "$part_link")
	mount=$(findmnt -rn -S "$device" -o TARGET | head -n1)
	[[ -n "$mount" ]] || die "active EFI partition $active_efi_partuuid is not mounted; its GRUB chain cannot be verified"
	printf '%s\n' "$mount"
}

validate_active_grub_chain() {
	local distro_id=$1 distro_like=$2 expected_vendor esp loader stub stub_content chain uuid prefix target_uuid
	candidate_exists /sys/firmware/efi || { detail 'legacy BIOS GRUB boot detected'; return 0; }
	read_active_efi_entry
	case "$active_efi_loader_normalized" in
		*shim*.efi|*grub*.efi) ;;
		*) die "BootCurrent $active_efi_id uses '$active_efi_loader_path', not a recognised GRUB/shim loader" ;;
	esac
	expected_vendor=$(expected_efi_vendor "$distro_id" "$distro_like") || \
		die "the expected EFI GRUB vendor directory for this distribution cannot be determined safely"
	[[ "$active_efi_vendor" == "$expected_vendor" ]] || \
		die "active EFI boot chain mismatch: BootCurrent $active_efi_id loads '$active_efi_loader_path' ($active_efi_label), but this system's GRUB configuration belongs to EFI/$expected_vendor"
	esp=$(active_esp_mount)
	loader="$esp/${active_efi_loader_normalized#/}"
	[[ -e "$loader" ]] || die "active EFI loader is not present on the mounted BootCurrent partition: $loader"
	stub="$(dirname "$loader")/grub.cfg"
	[[ -e "$stub" ]] || die "active EFI GRUB stub was not found beside the BootCurrent loader: $stub"
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
match = re.search(r"(?m)^\s*set\s+prefix\s*=\s*.*?(/boot/grub2?)(?:[\x27\x22\s]|$)", text)
if match:
    prefix = match.group(1)
if not uuid or not prefix:
    raise SystemExit(1)
print(f"{uuid}|{prefix}")
' <<<"$stub_content") || die "active EFI GRUB stub does not expose a verifiable filesystem UUID and /boot/grub prefix: $stub"
	IFS='|' read -r uuid prefix <<<"$chain"
	grub_generated_config=$(root_path "$prefix/grub.cfg")
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then
		target_uuid=${TOUCHPAD_PATCHER_TEST_GRUB_UUID:-}
	else
		target_uuid=$(findmnt -rn -T "$grub_generated_config" -o UUID | head -n1)
		[[ -n "$target_uuid" ]] || target_uuid=$(grub-probe --target=fs_uuid "$grub_generated_config" 2>/dev/null || true)
	fi
	[[ -n "$target_uuid" ]] || die "filesystem UUID for the generated GRUB configuration could not be determined: $grub_generated_config"
	[[ "${uuid,,}" == "${target_uuid,,}" ]] || \
		die "active EFI GRUB stub points to filesystem UUID $uuid, but $grub_generated_config is on $target_uuid"
	log "active EFI GRUB chain verified: BootCurrent $active_efi_id → EFI/$active_efi_vendor → $grub_generated_config"
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
			case "${active_efi_loader_normalized} ${current_label,,}" in
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
	local os_file distro_id='' distro_like=''
	os_file=$(root_path /etc/os-release)
	if [[ -r "$os_file" ]]; then
		# shellcheck disable=SC1090
		. "$os_file"
		distro_id=${ID:-}
		distro_like=${ID_LIKE:-}
	fi
	case "$boot_manager" in
		grub)
			if command -v grubby >/dev/null && [[ " $distro_id $distro_like " == *fedora* || " $distro_id $distro_like " == *rhel* ]]; then
				adapter=grubby; config_path=; config_format=; config_variable=
			else
				adapter=grub; config_path=$(root_path /etc/default/grub); config_format=shell; config_variable=GRUB_CMDLINE_LINUX_DEFAULT
			fi
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
	[[ "$adapter" == grubby || -f "$config_path" ]] || die "authoritative $adapter configuration was not found: $config_path"
	[[ "$adapter" != grub ]] || validate_active_grub_chain "$distro_id" "$distro_like"
	log "active boot manager: $boot_manager ($adapter adapter)"
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
	local prior_conflict=$1
	state_dir=$(root_path /var/lib/t14-len2068-touchpad-patch)
	state_file=$state_dir/native-state
	sudo_run mkdir -p "$state_dir"
	printf 'method=native\nadapter=%q\nboot_manager=%q\nconfig_path=%q\nprior_conflict=%q\nstatus=pending-verification\n' \
		"$adapter" "$boot_manager" "$config_path" "$prior_conflict" | sudo_run tee "$state_file" >/dev/null
}

load_state() {
	state_file=$(root_path /var/lib/t14-len2068-touchpad-patch/native-state)
	[[ -r "$state_file" ]] || return 1
	# State is generated by this tool and restricted to simple values.
	# shellcheck disable=SC1090
	. "$state_file"
}

config_contains_token() {
	if [[ "$adapter" == grubby ]]; then
		grubby --info=ALL 2>/dev/null | grep -Fq "$token"
	else
		local -a command=(python3 "$editor" check "$config_format" "$config_path")
		[[ -z "$config_variable" ]] || command+=("$config_variable")
		"${command[@]}"
	fi
}

grub_generated_token_status() {
	local candidate content
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
		[[ -e "$candidate" ]] || continue
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
		grubby) grubby --info=ALL 2>/dev/null | grep -Fq "$token" || die 'generated boot entries do not contain the native parameter' ;;
		grub)
			local status
			if grub_generated_token_status; then status=0; else status=$?; fi
			case "$status" in
				0) log "generated GRUB kernel entries verified: $grub_verified_path" ;;
				1) die "generated GRUB kernel command lines do not contain the exact argument '$token' (checked: $grub_checked_paths)" ;;
				2) die "generated GRUB configuration could not be read with administrator privileges: $grub_unreadable_paths" ;;
				3) die "generated GRUB configuration was not found (checked: $grub_checked_paths)" ;;
			esac
			;;
		cachyos-systemd-boot|systemd-boot) grep -RFq "$token" "$(root_path /boot/loader/entries)" 2>/dev/null || die 'generated boot entries do not contain the native parameter' ;;
		limine) grep -Fq "$token" "$(root_path /boot/limine.conf)" 2>/dev/null || die 'generated boot entries do not contain the native parameter' ;;
		refind) grep -Fq "$token" "$config_path" || die 'generated boot entries do not contain the native parameter' ;;
	esac
}

verify_generated_absent_token() {
	case "$adapter" in
		grubby)
			if grubby --info=ALL 2>/dev/null | grep -Fq "$token"; then die 'generated boot entries still contain the native parameter after rollback'; fi
			return 0
			;;
		cachyos-systemd-boot|systemd-boot)
			if grep -RFq "$token" "$(root_path /boot/loader/entries)" 2>/dev/null; then die 'generated boot entries still contain the native parameter after rollback'; fi
			return 0
			;;
		limine)
			if grep -Fq "$token" "$(root_path /boot/limine.conf)" 2>/dev/null; then die 'generated boot entries still contain the native parameter after rollback'; fi
			return 0
			;;
		refind)
			if grep -Fq "$token" "$config_path"; then die 'generated boot entries still contain the native parameter after rollback'; fi
			return 0
			;;
	esac
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
		grubby --info=ALL 2>/dev/null | grep -Fq "$conflict" && prior_conflict=1
		sudo_run grubby --update-kernel=ALL --remove-args="$conflict" --args="$token"
	else
		grep -Fq "$conflict" "$config_path" && prior_conflict=1
		local backup="${config_path}.touchpad-patcher-v2-backup"
		[[ -e "$backup" ]] || sudo_run cp -a -- "$config_path" "$backup"
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
	log 'native stock-kernel fix verified: SynPS/2 active and native TM3471 RMI4 absent'
	if ! load_state; then
		detect_adapter
		config_contains_token || die 'native parameter is active but no manageable persistent configuration was found'
		state_write 0
	fi
	sudo_run sed -i 's/^status=.*/status=verified/' "$state_file"
}

rollback_native() {
	hardware_guard
	load_state || die 'no native Touchpad Patcher state was found'
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
	preflight) hardware_guard; detect_adapter; kernel_supports_parameter || exit 20; log 'native route supported' ;;
	status) native_status ;;
	apply) apply_native ;;
	verify) verify_native ;;
	rollback) rollback_native ;;
	complete-rollback) complete_rollback ;;
esac
