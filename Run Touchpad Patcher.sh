#!/usr/bin/env bash
set -euo pipefail

terminal_child=0
verbose=0
launcher_args=("$@")
while [[ $# -gt 0 ]]; do
	case "$1" in
		--terminal-child) terminal_child=1; shift ;;
		--verbose) verbose=1; shift ;;
		-h|--help)
			printf 'Usage: %q [--verbose]\n' "$0"
			exit 0
			;;
		*) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done

if (( ! terminal_child )) && [[ ! -t 0 ]]; then
	if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v konsole >/dev/null; then
		exec konsole -e bash "$0" --terminal-child "${launcher_args[@]}"
	elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v gnome-terminal >/dev/null; then
		exec gnome-terminal --wait -- bash "$0" --terminal-child "${launcher_args[@]}"
	elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v x-terminal-emulator >/dev/null; then
		exec x-terminal-emulator -e bash "$0" --terminal-child "${launcher_args[@]}"
	else
		printf 'Open a terminal and run:\n  %q' "$0" >&2
		(( verbose )) && printf ' --verbose' >&2
		printf '\n' >&2
		exit 1
	fi
fi

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
installer="$project_dir/scripts/t14-ps2-kernel-installer.sh"
suffix=t14-len2068-touchpad-patch
legacy_suffix=t14ps2quirk1
log_dir="$project_dir/logs"
mkdir -p "$log_dir"
log_file="$log_dir/$(date +%Y%m%d-%H%M%S-%N)-touchpad-patcher.log"
touch "$log_file"

detail() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$log_file"
	if (( verbose )); then printf '[detail] %s\n' "$*"; fi
}

run_logged() {
	local status command
	printf -v command '%q ' "$@"
	detail "+ ${command% }"
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
	detail "exit $status: ${command% }"
	return "$status"
}

sudo_keeper=
cleanup_keeper() {
	[[ -z "$sudo_keeper" ]] || kill "$sudo_keeper" 2>/dev/null || true
}

press_to_close() {
	printf '\n%s\n' "$1"
	if [[ -t 0 ]]; then
		printf 'Press any key to close...'
		IFS= read -r -n 1 -s _ || true
		printf '\n'
	fi
}

handle_exit() {
	local status=$?
	cleanup_keeper
	if (( status != 0 )); then
		printf '\nTouchpad Patcher stopped with an error (code %s).\n' "$status" >&2
		printf 'Stock distribution kernels were not removed and remain available as fallbacks.\n' >&2
		printf 'Full diagnostic log: %s\n' "$log_file" >&2
		if [[ -t 0 ]]; then
			printf 'Press any key to close...'
			IFS= read -r -n 1 -s _ || true
			printf '\n'
		fi
	fi
	exit "$status"
}
trap handle_exit EXIT

[[ -x "$installer" ]] || { printf 'Required installer is missing or not executable:\n  %s\n' "$installer" >&2; exit 1; }

printf '%s\n\n' 'ThinkPad T14 Gen 1 Touchpad Patcher'
printf '%s\n' 'Administrator authentication is required for dependency and kernel installation.'
sudo -v
detail 'sudo authentication established'

while true; do
	sudo -n true 2>/dev/null || exit
	sleep 50
done &
sudo_keeper=$!

running=$(uname -r)
if [[ "$running" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
	base_version=${BASH_REMATCH[1]}
else
	printf 'Unable to derive an upstream kernel version from: %s\n' "$running" >&2
	exit 1
fi
target_release="$base_version-$suffix"
target_kernel="/boot/vmlinuz-$target_release"
target_modules="/lib/modules/$target_release"
legacy_release="$base_version-$legacy_suffix"

if [[ (! -f "$target_kernel" || ! -d "$target_modules") && -f "/boot/vmlinuz-$legacy_release" && -d "/lib/modules/$legacy_release" ]]; then
	target_release=$legacy_release
	target_kernel="/boot/vmlinuz-$legacy_release"
	target_modules="/lib/modules/$legacy_release"
	detail "recognized legacy patched kernel $legacy_release"
fi

installer_args=(--yes --kernel "$base_version" --log-file "$log_file")
(( verbose )) && installer_args+=(--verbose)

if [[ -f "$target_kernel" && -d "$target_modules" ]]; then
	printf '✓ Patched kernel already installed: %s\n' "$target_release"
	if command -v grubby >/dev/null; then
		default_kernel=$(sudo grubby --default-kernel 2>>"$log_file" || true)
		if [[ "$default_kernel" != "$target_kernel" ]]; then
			run_logged sudo grubby --set-default "$target_kernel" || { printf 'Could not select the installed patched kernel as the default.\n' >&2; exit 1; }
			[[ "$(sudo grubby --default-kernel 2>>"$log_file")" == "$target_kernel" ]] || { printf 'Bootloader default verification failed.\n' >&2; exit 1; }
			printf '✓ Patched kernel selected for next boot\n'
		fi
	fi
	if [[ "$running" == "$target_release" ]]; then
		verify_args=(--log-file "$log_file")
		(( verbose )) && verify_args+=(--verbose)
		"$installer" "${verify_args[@]}" verify
	else
		printf 'Reboot into %s to activate and verify the touchpad patch.\n' "$target_release"
	fi
	cleanup_keeper
	trap - EXIT
	printf 'Diagnostic log: %s\n' "$log_file"
	press_to_close 'Patch already completed successfully.'
	exit 0
fi

"$installer" "${installer_args[@]}" all

printf '\nInstallation complete. Reboot to use %s.\n' "$target_release"
printf 'Full diagnostic log: %s\n' "$log_file"

cleanup_keeper
trap - EXIT
press_to_close 'Touchpad patch installation successful.'
