#!/usr/bin/env bash
set -euo pipefail

terminal_child=0
verbose=0
testing=${TOUCHPAD_PATCHER_TESTING:-0}
launcher_args=("$@")
while [[ $# -gt 0 ]]; do
	case "$1" in
		--terminal-child) terminal_child=1; shift ;;
		--verbose) verbose=1; shift ;;
		-h|--help) printf 'Usage: %q [--verbose]\n' "$0"; exit 0 ;;
		*) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done

if (( ! testing && ! terminal_child )) && [[ ! -t 0 ]]; then
	if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v konsole >/dev/null; then
		exec konsole -e bash "$0" --terminal-child "${launcher_args[@]}"
	elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v gnome-terminal >/dev/null; then
		exec gnome-terminal --wait -- bash "$0" --terminal-child "${launcher_args[@]}"
	elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v x-terminal-emulator >/dev/null; then
		exec x-terminal-emulator -e bash "$0" --terminal-child "${launcher_args[@]}"
	else
		printf 'Open a terminal and run:\n  %q\n' "$0" >&2
		exit 1
	fi
fi

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
installer="$project_dir/scripts/t14-ps2-kernel-installer.sh"
native_manager="$project_dir/scripts/t14-ps2-native-manager.sh"
suffix=t14-len2068-touchpad-patch
legacy_suffix=t14ps2quirk1
log_dir="$project_dir/logs"
mkdir -p "$log_dir"
log_file="$log_dir/$(date +%Y%m%d-%H%M%S-%N)-touchpad-patcher.log"
touch "$log_file"

detail() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$log_file"
	(( ! verbose )) || printf '[detail] %s\n' "$*"
}

run_logged() {
	local status
	if (( verbose )); then
		set +e; "$@" > >(tee -a "$log_file") 2> >(tee -a "$log_file" >&2); status=$?; set -e
	else
		set +e; "$@" >>"$log_file" 2>&1; status=$?; set -e
	fi
	return "$status"
}

sudo_keeper=
cleanup_keeper() { [[ -z "$sudo_keeper" ]] || kill "$sudo_keeper" 2>/dev/null || true; }
finish() {
	cleanup_keeper
	trap - EXIT
	printf '\nDiagnostic log: %s\n' "$log_file"
	if [[ -t 0 ]]; then printf 'Press any key to close...'; IFS= read -r -n 1 -s _ || true; printf '\n'; fi
	exit "${1:-0}"
}

handle_exit() {
	local status=$?
	cleanup_keeper
	if (( status != 0 )); then
		printf '\nTouchpad Patcher stopped with an error (code %s).\n' "$status" >&2
		printf 'Stock distribution kernels remain available as fallbacks.\n' >&2
		printf 'Full diagnostic log: %s\n' "$log_file" >&2
		if [[ -t 0 ]]; then printf 'Press any key to close...'; IFS= read -r -n 1 -s _ || true; printf '\n'; fi
	fi
	exit "$status"
}
trap handle_exit EXIT

ask_choice() {
	local prompt=$1 default=$2 answer
	if [[ ! -t 0 ]]; then printf '%s\n' "$default"; return; fi
	printf '%s' "$prompt" >&2
	IFS= read -r answer
	printf '%s\n' "${answer:-$default}"
}

[[ -x "$installer" && -x "$native_manager" ]] || { printf 'Required patcher components are missing or not executable.\n' >&2; exit 1; }
printf '%s\n' 'ThinkPad T14 Gen 1 LEN2068 Touchpad Patcher v2.0.1'
printf '%s\n\n' 'The stock-kernel boot parameter is preferred; a custom kernel is the guarded fallback.'
if (( ! testing )); then
	printf '%s\n' 'Administrator authentication is required to manage boot configuration or kernels.'
	sudo -v
	while true; do sudo -n true 2>/dev/null || exit; sleep 50; done &
	sudo_keeper=$!
fi

native_args=()
installer_common=(--log-file "$log_file")
(( verbose )) && { native_args+=(--verbose); installer_common+=(--verbose); }
if (( testing )); then
	running=${TOUCHPAD_PATCHER_TEST_UNAME_R:?}
else
	running=$(uname -r)
fi

if [[ "$running" == *"-$suffix" || "$running" == *"-$legacy_suffix" ]]; then
	rm -f -- "${XDG_CACHE_HOME:-$HOME/.cache}/t14-len2068-touchpad-patch/.custom-pending-verification"
	printf '\nCustom-kernel method detected. Verifying...\n'
	if "$installer" "${installer_common[@]}" verify; then
		choice=$(ask_choice 'Press Enter to keep the custom kernel, or R to begin rollback: ' keep)
	else
		printf '\nCustom-kernel verification failed.\n' >&2
		choice=$(ask_choice 'Press R to return to a stock kernel, or Enter to close without changing anything: ' keep)
	fi
	if [[ "${choice,,}" == r* ]]; then
		mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/t14-len2068-touchpad-patch"
		printf '%s\n' "$running" >"${XDG_CACHE_HOME:-$HOME/.cache}/t14-len2068-touchpad-patch/.remove-pending"
		printf '\nRollback recorded. Reboot into any stock distribution kernel, then run this patcher again.\n'
		printf 'The patcher will remove only the custom kernel after confirming it is no longer running.\n'
	else
		printf '\nCustom patched kernel kept.\n'
	fi
	finish 0
fi

pending_remove="${XDG_CACHE_HOME:-$HOME/.cache}/t14-len2068-touchpad-patch/.remove-pending"
if [[ -r "$pending_remove" ]]; then
	release=$(<"$pending_remove")
	choice=$(ask_choice "Stock kernel detected. Remove custom kernel $release now? [Y/n] " y)
	if [[ "${choice,,}" != n* ]]; then
		"$installer" "${installer_common[@]}" --kernel "$release" uninstall
		rm -f -- "$pending_remove"
		printf '\nCustom-kernel rollback completed.\n'
	fi
	finish 0
fi

pending_custom="${XDG_CACHE_HOME:-$HOME/.cache}/t14-len2068-touchpad-patch/.custom-pending-verification"
if [[ -r "$pending_custom" ]]; then
	release=$(<"$pending_custom")
	if [[ -f "/boot/vmlinuz-$release" && -d "/lib/modules/$release" ]]; then
		printf '\nCustom fallback kernel is installed but not currently running: %s\n' "$release"
		printf 'Reboot into that kernel, then run the patcher again for verification.\n'
		finish 0
	fi
	printf 'The recorded custom fallback is incomplete; clearing stale pending state.\n' >&2
	rm -f -- "$pending_custom"
fi

set +e
native_state=$("$native_manager" "${native_args[@]}" status 2>>"$log_file")
native_status=$?
set -e
detail "native status=$native_status state='$native_state'"

if (( native_status == 0 )); then
	printf '\nNative stock-kernel method detected. Verifying...\n'
	if "$native_manager" "${native_args[@]}" verify; then
		choice=$(ask_choice 'Press Enter to keep the native fix, or R to roll it back: ' keep)
		if [[ "${choice,,}" == r* ]]; then
			"$native_manager" "${native_args[@]}" rollback
			printf '\nReboot once more to complete rollback, then run the patcher to confirm it.\n'
		else
			printf '\nNative fix kept. Future stock-kernel updates will inherit it.\n'
		fi
		finish 0
	fi
	printf '\nThe native parameter was active but did not produce the required SynPS/2 state.\n'
	choice=$(ask_choice 'Roll it back and build the custom fallback kernel? [Y/n] ' y)
	if [[ "${choice,,}" == n* ]]; then finish 1; fi
	"$native_manager" "${native_args[@]}" rollback
	printf '\nNative configuration rolled back. Continuing with the custom-kernel fallback...\n'
elif (( native_status == 10 )); then
	if [[ "$native_state" == *rollback-pending-reboot* ]]; then
		"$native_manager" "${native_args[@]}" complete-rollback
		printf '\nNative rollback verified and completed.\n'
		finish 0
	fi
	printf '\nThe native parameter is configured but is not active in this boot.\n'
	printf 'Reboot normally, then run the patcher again for verification.\n'
	finish 0
elif (( native_status != 20 )); then
	printf 'Unable to determine native patch state.\n' >&2
	exit 1
fi

if (( native_status == 20 )); then
	printf '\nChecking whether the stock-kernel native method is supported...\n'
	set +e
	"$native_manager" "${native_args[@]}" --yes apply
	apply_status=$?
	set -e
	if (( apply_status == 0 )); then
		printf '\nNative fix installed. Reboot normally, then run the patcher again to verify or roll it back.\n'
		finish 0
	elif (( apply_status != 20 )); then
		printf 'Native installation failed; the kernel fallback was not started automatically.\n' >&2
		exit "$apply_status"
	fi
	printf '\nThe running kernel does not expose the required parameter.\n'
	choice=$(ask_choice 'Build and install the custom patched-kernel fallback? [Y/n] ' y)
	[[ "${choice,,}" != n* ]] || finish 0
fi

if [[ ! "$running" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
	printf 'Unable to derive an upstream kernel version from: %s\n' "$running" >&2
	exit 1
fi
base_version=${BASH_REMATCH[1]}
"$installer" "${installer_common[@]}" --yes --kernel "$base_version" all
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/t14-len2068-touchpad-patch"
printf '%s\n' "$base_version-$suffix" >"$pending_custom"
printf '\nCustom fallback installed. Reboot into %s-%s, then run the patcher again.\n' "$base_version" "$suffix"
finish 0
