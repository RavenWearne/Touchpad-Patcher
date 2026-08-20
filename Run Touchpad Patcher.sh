#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == --terminal-child ]]; then
	shift
elif [[ ! -t 0 ]]; then
	if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v konsole >/dev/null; then
		exec konsole -e bash "$0" --terminal-child
	elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v gnome-terminal >/dev/null; then
		exec gnome-terminal --wait -- bash "$0" --terminal-child
	elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v x-terminal-emulator >/dev/null; then
		exec x-terminal-emulator -e bash "$0" --terminal-child
	else
		printf 'Open a terminal and run:\n  %q\n' "$0" >&2
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
active_log="$log_file.in-progress"
exec > >(tee -a "$active_log") 2>&1

sudo_keeper=
cleanup_keeper() {
	[[ -z "$sudo_keeper" ]] || kill "$sudo_keeper" 2>/dev/null || true
}

handle_exit() {
	status=$?
	cleanup_keeper
	if (( status != 0 )); then
		if [[ -f "$active_log" ]]; then
			mv -f -- "$active_log" "$log_file"
		fi
		printf '\nTouchpad Patcher stopped with an error (code %s).\n' "$status" >&2
		printf 'Nothing removed your stock distribution kernels. They remain available as fallbacks.\n' >&2
		printf 'Diagnostic log: %s\n' "$log_file" >&2
		if [[ -t 0 ]]; then
			printf 'Press any key to close...'
			IFS= read -r -n 1 -s _ || true
			printf '\n'
		fi
	fi
	exit "$status"
}
trap handle_exit EXIT

[[ -x "$installer" ]] || {
	printf 'Required installer is missing or not executable:\n  %s\n' "$installer" >&2
	exit 1
}

printf '%s\n' 'ThinkPad T14 Gen 1 LEN2068 Touchpad Patcher'
printf '%s\n' 'This installs a distinctly named SynPS/2 policy kernel and preserves all stock kernels.'
printf '\nAdministrator authentication is required once for kernel installation.\n'
sudo -v

show_compatibility() {
	local distro_id distro_like pretty adapter likelihood
	local -a required missing

	if [[ -r /etc/os-release ]]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		distro_id=${ID:-unknown}
		distro_like=${ID_LIKE:-}
		pretty=${PRETTY_NAME:-$distro_id}
	else
		distro_id=unknown
		distro_like=
		pretty='Unknown Linux distribution'
	fi

	case " $distro_id $distro_like " in
		*fedora*|*rhel*)
			adapter='Fedora/RHEL'
			likelihood='HIGH — Fedora is validated end-to-end; compatible derivatives use the same adapter.'
			required=(dracut kernel-install grubby)
			;;
		*debian*|*ubuntu*)
			adapter='Debian/Ubuntu (includes Linux Mint)'
			likelihood='GOOD — the adapter is implemented, but has not yet been physically validated by this project.'
			required=(update-initramfs update-grub)
			;;
		*arch*)
			adapter='Arch Linux'
			likelihood='GOOD — the adapter is implemented, but has not yet been physically validated by this project.'
			required=(mkinitcpio)
			;;
		*suse*|*opensuse*)
			adapter='openSUSE'
			likelihood='GOOD — the adapter is implemented, but has not yet been physically validated by this project.'
			required=(dracut grub2-mkconfig)
			;;
		*)
			adapter='Generic systemd Linux'
			likelihood='EXPERIMENTAL — installation can proceed only with compatible kernel-install and dracut tooling.'
			required=(kernel-install dracut)
			;;
	esac

	missing=()
	for command in "${required[@]}"; do
		command -v "$command" >/dev/null || missing+=("$command")
	done

	printf '\nDistribution compatibility assessment\n'
	printf '  Detected:   %s\n' "$pretty"
	printf '  Adapter:    %s\n' "$adapter"
	printf '  Likelihood: %s\n' "$likelihood"
	printf '  Kernel:     stable upstream Linux 4.x+ on x86-64 with supported Synaptics source layout\n'
	if (( ${#missing[@]} )); then
		printf '  Warning:    missing adapter tool(s): %s\n' "${missing[*]}"
		printf '              Preflight will stop safely unless these are installed.\n'
	else
		printf '  Tooling:    required adapter commands detected\n'
	fi
}

show_compatibility

# Keep the sudo timestamp alive during a potentially long compilation so the
# user is not prompted again near the end of the build.
while true; do
	sudo -n true 2>/dev/null || exit
	sleep 50
done &
sudo_keeper=$!

press_to_close() {
	local message=$1
	printf '\n%s\n' "$message"
	if [[ -t 0 ]]; then
		printf 'Press any key to close...'
		IFS= read -r -n 1 -s _
		printf '\n'
	fi
}

discard_success_log() {
	rm -f -- "$active_log" "$log_file"
}

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
legacy_kernel="/boot/vmlinuz-$legacy_release"
legacy_modules="/lib/modules/$legacy_release"

if [[ ! -f "$target_kernel" || ! -d "$target_modules" ]]; then
	if [[ -f "$legacy_kernel" && -d "$legacy_modules" ]]; then
		target_release=$legacy_release
		target_kernel=$legacy_kernel
		target_modules=$legacy_modules
		printf '\nAn existing kernel containing the same touchpad patch was detected.\n'
		printf 'Future builds use the clearer suffix: %s\n' "$suffix"
	fi
fi

if [[ -f "$target_kernel" && -d "$target_modules" ]]; then
	printf '\nPatch already completed for kernel series %s.\n' "$base_version"
	printf 'Installed kernel: %s\n' "$target_release"

	if command -v grubby >/dev/null; then
		default_kernel=$(sudo grubby --default-kernel 2>/dev/null || true)
		if [[ "$default_kernel" != "$target_kernel" ]]; then
			printf 'Restoring the patched kernel as the default boot entry...\n'
			sudo grubby --set-default "$target_kernel"
		fi
		printf 'Default kernel: %s\n' "$(sudo grubby --default-kernel 2>/dev/null || printf unknown)"
	fi

	if [[ "$running" == "$target_release" ]]; then
		"$installer" verify
	else
		printf 'Reboot and select %s if it is not selected automatically.\n' "$target_release"
	fi

	cleanup_keeper
	trap - EXIT
	discard_success_log
	press_to_close 'Patch already completed successfully.'
	exit 0
fi

printf '\nNo completed patch was found for the current %s kernel series.\n' "$base_version"
printf 'Running guarded hardware and build checks, then building %s...\n\n' "$target_release"
"$installer" --yes --kernel "$base_version" all

printf '\nInstallation completed successfully.\n'
printf 'Reboot into %s, then run this launcher again to verify it.\n' "$target_release"

cleanup_keeper
trap - EXIT
discard_success_log
press_to_close 'Touchpad patch successful.'
exit 0
