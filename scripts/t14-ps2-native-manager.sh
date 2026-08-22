#!/usr/bin/env bash
set -euo pipefail

tool_version=2.0.0
token=psmouse.synaptics_intertouch=0
conflict=psmouse.synaptics_intertouch=1
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
editor="$project_dir/scripts/t14-ps2-kernel-arg.py"
state_dir=/var/lib/t14-len2068-touchpad-patch
state_file=$state_dir/native-state
verbose=0
assume_yes=0
action=status

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

log() { printf '[native] %s\n' "$*"; }
detail() { (( ! verbose )) || printf '[native detail] %s\n' "$*"; }
die() { printf '[native] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "required command not found: $1"; }
read_dmi() { [[ -r "/sys/class/dmi/id/$1" ]] && tr -d '\n' <"/sys/class/dmi/id/$1" || true; }

sudo_run() {
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 ]]; then "$@"; else sudo "$@"; fi
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

detect_boot_manager() {
	if [[ ${TOUCHPAD_PATCHER_TESTING:-0} == 1 && -n ${TOUCHPAD_PATCHER_BOOT_MANAGER:-} ]]; then
		boot_manager=$TOUCHPAD_PATCHER_BOOT_MANAGER
	else
		local boot_status='' current_label=''
		if command -v bootctl >/dev/null; then boot_status=$(bootctl status 2>/dev/null || true); fi
		if grep -qi 'product:.*systemd-boot' <<<"$boot_status"; then
			boot_manager=systemd-boot
		elif command -v efibootmgr >/dev/null; then
			local current
			current=$(efibootmgr 2>/dev/null | sed -n 's/^BootCurrent: //p' | head -n1)
			[[ -z "$current" ]] || current_label=$(efibootmgr 2>/dev/null | sed -n "s/^Boot${current}[* ]*//p" | head -n1)
			case "${current_label,,}" in
				*limine*) boot_manager=limine ;;
				*refind*) boot_manager=refind ;;
				*grub*|*fedora*|*ubuntu*|*debian*|*opensuse*) boot_manager=grub ;;
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
	log "active boot manager: $boot_manager ($adapter adapter)"
}

regenerate() {
	case "$adapter" in
		grubby) return ;;
		grub)
			if command -v update-grub >/dev/null; then sudo_run update-grub
			elif command -v grub2-mkconfig >/dev/null && candidate_exists /boot/grub2; then sudo_run grub2-mkconfig -o "$(root_path /boot/grub2/grub.cfg)"
			elif command -v grub-mkconfig >/dev/null && candidate_exists /boot/grub; then sudo_run grub-mkconfig -o "$(root_path /boot/grub/grub.cfg)"
			else die 'the active GRUB installation has no supported regeneration command'; fi
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

generated_contains_token() {
	case "$adapter" in
		grubby) grubby --info=ALL 2>/dev/null | grep -Fq "$token" ;;
		grub)
			local generated
			for generated in "$(root_path /boot/grub/grub.cfg)" "$(root_path /boot/grub2/grub.cfg)"; do
				if [[ -r "$generated" ]] && grep -Fq "$token" "$generated"; then return 0; fi
			done
			return 1
			;;
		cachyos-systemd-boot|systemd-boot) grep -RFq "$token" "$(root_path /boot/loader/entries)" 2>/dev/null ;;
		limine) grep -Fq "$token" "$(root_path /boot/limine.conf)" 2>/dev/null ;;
		refind) grep -Fq "$token" "$config_path" ;;
	esac
}

apply_native() {
	hardware_guard
	detect_adapter
	kernel_supports_parameter || return 20
	if config_contains_token; then
		generated_contains_token || die 'native parameter is configured but absent from generated boot entries'
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
	regenerate
	config_contains_token || die 'boot configuration regeneration did not retain the native parameter'
	generated_contains_token || die 'generated boot entries do not contain the native parameter'
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
	generated_contains_token && die 'generated boot entries still contain the native parameter after rollback'
	sudo_run sed -i 's/^status=.*/status=rollback-pending-reboot/' "$state_file"
	log 'native parameter removed from boot configuration; reboot required to complete rollback'
}

native_status() {
	if grep -Fqw "$token" <<<"$(cmdline_value)"; then printf 'native-active\n'; return 0; fi
	if load_state; then
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
