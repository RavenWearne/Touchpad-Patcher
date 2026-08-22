#!/usr/bin/env bash
set -euo pipefail

terminal_child=0
verbose=0
testing=${TOUCHPAD_PATCHER_TESTING:-0}
launcher_args=("$@")
while [[ $# -gt 0 ]]; do
	case "$1" in
		--terminal-child) terminal_child=1; shift ;;
		--verbose|--debug) verbose=1; shift ;;
		-h|--help) printf 'Usage: %q [--verbose|--debug]\n' "$0"; exit 0 ;;
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
user_summary="$project_dir/scripts/t14-ps2-user-summary.py"
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
	if (( verbose )); then
		"$@" > >(tee -a "$log_file") 2> >(tee -a "$log_file" >&2)
	else
		"$@" >>"$log_file" 2>&1
	fi
}

sudo_keeper=
inventory_file=
cleanup_keeper() {
	[[ -z "$sudo_keeper" ]] || kill "$sudo_keeper" 2>/dev/null || true
	[[ -z "$inventory_file" ]] || rm -f -- "$inventory_file"
}
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

collect_inventory() {
	if (( verbose )); then
		"$native_manager" "${native_args[@]}" inventory >"$inventory_file" 2> >(tee -a "$log_file" >&2)
	else
		"$native_manager" "${native_args[@]}" inventory >"$inventory_file" 2>>"$log_file"
	fi
}

concise_native_error() {
	local reason
	reason=$(grep -F '[native] ERROR:' "$log_file" | head -n1 | sed 's/^\[native\] ERROR: //' || true)
	printf '✗ %s\n' "${reason:-The touchpad patch could not be applied safely.}" >&2
	printf 'The operation stopped safely; no further changes were made.\n' >&2
}

[[ -x "$installer" && -x "$native_manager" && -x "$user_summary" ]] || { printf 'Required patcher components are missing or not executable.\n' >&2; exit 1; }
printf '%s\n' 'ThinkPad T14 Gen 1 LEN2068 Touchpad Patcher v3.1.0'
if (( ! testing )); then
	printf '\n%s\n' 'Administrator authentication is required to manage the touchpad patch.'
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

current_kernel_patched=0
if [[ "$running" == *"-$suffix" || "$running" == *"-$legacy_suffix" ]]; then
	current_kernel_patched=1
	rm -f -- "${XDG_CACHE_HOME:-$HOME/.cache}/t14-len2068-touchpad-patch/.custom-pending-verification"
fi

inventory_file=$(mktemp --tmpdir "t14-touchpad-machine-inventory.XXXXXX.json")
if ! collect_inventory; then
	concise_native_error
	exit 1
fi
printf '\n✓ ThinkPad T14 Gen 1 with LEN2068 detected\n'
python3 "$user_summary" current "$inventory_file"

if (( current_kernel_patched )); then
	if run_logged "$installer" "${installer_common[@]}" verify; then
		printf '✓ SynPS/2 touchpad verified\n'
	else
		printf '✗ Current kernel patch did not produce the expected touchpad state.\n' >&2
		printf 'No kernel was removed.\n' >&2
		exit 1
	fi
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
	if run_logged "$native_manager" "${native_args[@]}" verify; then
		(( current_kernel_patched )) || printf '✓ Touchpad patch active\n✓ SynPS/2 touchpad verified\n'
		python3 "$user_summary" multi "$inventory_file"
		if python3 "$user_summary" complete "$inventory_file"; then
			printf '\n✓ This system is fully patched.\n\nNo changes are required.\n'
		else
			printf '\nThe current system is verified. Other listed systems still require patching or runtime verification.\n'
		fi
		finish 0
	fi
	printf '\nThe active touchpad patch did not produce the expected SynPS/2 state.\n'
	choice=$(ask_choice 'Roll it back and build the custom fallback kernel? [Y/n] ' y)
	if [[ "${choice,,}" == n* ]]; then finish 1; fi
	run_logged "$native_manager" "${native_args[@]}" rollback
	printf '\nThe boot patch was rolled back. Continuing with the custom-kernel fallback...\n'
elif (( native_status == 10 )); then
	if [[ "$native_state" == *rollback-pending-reboot* ]]; then
		run_logged "$native_manager" "${native_args[@]}" complete-rollback
		printf '\nTouchpad patch rollback verified and completed.\n'
		finish 0
	fi
	python3 "$user_summary" multi "$inventory_file"
	printf '\n✓ Touchpad patch installed\n○ Reboot to activate and verify it\n'
	finish 0
elif (( native_status != 20 )); then
	concise_native_error
	exit 1
fi

if (( native_status == 20 )); then
	python3 "$user_summary" multi "$inventory_file"
	printf '\nApplying patches...\n'
	set +e
	run_logged "$native_manager" "${native_args[@]}" --yes apply
	apply_status=$?
	set -e
	if (( apply_status == 0 )); then
		if (( current_kernel_patched )); then printf '✓ Existing patched kernel preserved\n'; fi
		if ! collect_inventory; then concise_native_error; exit 1; fi
		python3 "$user_summary" result "$inventory_file"
		printf '\n✓ Touchpad patch installed\n○ Reboot into each newly patched system for runtime verification\n'
		finish 0
	elif (( apply_status != 20 )); then
		concise_native_error
		printf 'The custom-kernel fallback was not started.\n' >&2
		exit "$apply_status"
	fi
	printf '\nA safe stock-kernel touchpad patch is not available for this system.\n'
	printf 'A custom patched kernel can be built instead.\n'
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
