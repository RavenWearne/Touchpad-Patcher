#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d --tmpdir 'touchpad patcher tests.XXXXXX')
trap 'rm -rf -- "$test_root"' EXIT

make_case() {
	local name=$1
	case_dir="$test_root/$name with spaces"
	repo_dir="$case_dir/Touchpad Patcher"
	fixture_dir="$case_dir/system fixture"
	fake_bin="$case_dir/fake commands"
	trace_file="$case_dir/installer trace"
	mkdir -p "$repo_dir" "$fixture_dir/etc/default" "$fixture_dir/boot/grub" \
		"$fixture_dir/proc/bus/input" "$fixture_dir/sys/module/psmouse/parameters" "$fake_bin"
	cp -a -- "$source_dir/." "$repo_dir/"
	printf '%s\n' 'ID=linuxmint' 'ID_LIKE="ubuntu debian"' 'PRETTY_NAME="Linux Mint 22.3"' >"$fixture_dir/etc/os-release"
	printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >"$fixture_dir/etc/default/grub"
	printf '%s\n' 'generated quiet splash' >"$fixture_dir/boot/grub/grub.cfg"
	printf '%s\n' 'quiet splash' >"$fixture_dir/proc/cmdline"
	printf '%s\n' 'N: Name="SynPS/2 Synaptics TouchPad"' >"$fixture_dir/proc/bus/input/devices"

	cat >"$fake_bin/update-grub" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ ${TOUCHPAD_TEST_UPDATE_GRUB_FAIL:-0} != 1 ]] || exit 42
# shellcheck disable=SC1091
. "$TOUCHPAD_PATCHER_TEST_ROOT/etc/default/grub"
printf '    linux /boot/vmlinuz-test root=UUID=test ro %s $vt_handoff\n' "$GRUB_CMDLINE_LINUX_DEFAULT" \
	>"$TOUCHPAD_PATCHER_TEST_ROOT/boot/grub/grub.cfg"
SH
	chmod +x "$fake_bin/update-grub"

	cat >"$repo_dir/scripts/t14-ps2-kernel-installer.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TOUCHPAD_TEST_INSTALLER_TRACE"
SH
	chmod +x "$repo_dir/scripts/t14-ps2-kernel-installer.sh"
}

enable_uefi() {
	local current=$1 current_label=$2 current_vendor=$3
	local other_id=$4 other_label=$5 other_vendor=$6
	mkdir -p "$fixture_dir/sys/firmware/efi" "$fixture_dir/boot/efi/efi/$current_vendor" "$fixture_dir/boot/efi/efi/$other_vendor"
	touch "$fixture_dir/boot/efi/efi/$current_vendor/shimx64.efi" "$fixture_dir/boot/efi/efi/$other_vendor/shimx64.efi"
	printf '%s\n' \
		'search.fs_uuid 11111111-2222-3333-4444-555555555555 root' \
		"set prefix=(\$root)'/boot/grub'" \
		'configfile $prefix/grub.cfg' >"$fixture_dir/boot/efi/efi/$current_vendor/grub.cfg"
	printf '%s\n' \
		"BootCurrent: $current" \
		"Boot${current}* $current_label HD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0x100000)/File(\\EFI\\$current_vendor\\shimx64.efi)" \
		"Boot${other_id}* $other_label HD(1,GPT,ffffffff-1111-2222-3333-444444444444,0x800,0x100000)/File(\\EFI\\$other_vendor\\shimx64.efi)" \
		>"$fixture_dir/efibootmgr.out"
	cat >"$fake_bin/efibootmgr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat "$TOUCHPAD_PATCHER_TEST_ROOT/efibootmgr.out"
SH
	chmod +x "$fake_bin/efibootmgr"
}

run_launcher() {
	local output_file=$1
	shift
	env -u DISPLAY -u WAYLAND_DISPLAY \
		PATH="$fake_bin:$PATH" \
		TOUCHPAD_PATCHER_TESTING=1 \
		TOUCHPAD_PATCHER_TEST_ROOT="$fixture_dir" \
		TOUCHPAD_PATCHER_BOOT_MANAGER=grub \
		TOUCHPAD_PATCHER_TEST_UNAME_R=6.8.0-85-generic \
		TOUCHPAD_PATCHER_TEST_GRUB_UUID=11111111-2222-3333-4444-555555555555 \
		TOUCHPAD_TEST_INSTALLER_TRACE="$trace_file" \
		XDG_CACHE_HOME="$case_dir/cache with spaces" \
		"$@" "$repo_dir/Run Touchpad Patcher.sh" >"$output_file" 2>&1
}

# Mint/GRUB native success from a repository path containing spaces.
make_case native-success
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
run_launcher "$case_dir/output"
grep -Fq 'Native fix installed' "$case_dir/output"
grep -Fq 'psmouse.synaptics_intertouch=0' "$fixture_dir/etc/default/grub"
grep -Fq 'linux /boot/vmlinuz-test root=UUID=test ro quiet splash psmouse.synaptics_intertouch=0 $vt_handoff' "$fixture_dir/boot/grub/grub.cfg"
[[ ! -e "$trace_file" ]] # Native success must not touch build dependencies/fallback.

# The same Mint/GRUB installation rolls back through the manager path with spaces.
printf '%s\n' 'quiet splash psmouse.synaptics_intertouch=0' >"$fixture_dir/proc/cmdline"
rollback_output=$(env PATH="$fake_bin:$PATH" \
	TOUCHPAD_PATCHER_TESTING=1 \
	TOUCHPAD_PATCHER_TEST_ROOT="$fixture_dir" \
	TOUCHPAD_PATCHER_BOOT_MANAGER=grub \
	"$repo_dir/scripts/t14-ps2-native-manager.sh" rollback)
grep -Fq 'native parameter removed' <<<"$rollback_output"
if grep -Fq 'psmouse.synaptics_intertouch=0' "$fixture_dir/etc/default/grub"; then exit 1; fi
if grep -Fq 'psmouse.synaptics_intertouch=0' "$fixture_dir/boot/grub/grub.cfg"; then exit 1; fi

# Existing active native fix verifies and remains on the stock kernel.
make_case native-active
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash psmouse.synaptics_intertouch=0"' >"$fixture_dir/etc/default/grub"
printf '%s\n' '    linux /boot/vmlinuz-test root=UUID=test ro quiet splash psmouse.synaptics_intertouch=0 $vt_handoff' >"$fixture_dir/boot/grub/grub.cfg"
printf '%s\n' 'quiet splash psmouse.synaptics_intertouch=0' >"$fixture_dir/proc/cmdline"
run_launcher "$case_dir/output"
grep -Fq 'Native fix kept' "$case_dir/output"
[[ ! -e "$trace_file" ]]

# Stale pending state is reconciled against the real persistent configuration.
make_case stale-native-state
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
run_launcher "$case_dir/first-output"
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >"$fixture_dir/etc/default/grub"
TOUCHPAD_PATCHER_TEST_ROOT="$fixture_dir" "$fake_bin/update-grub"
set +e
stale_output=$(env PATH="$fake_bin:$PATH" \
	TOUCHPAD_PATCHER_TESTING=1 \
	TOUCHPAD_PATCHER_TEST_ROOT="$fixture_dir" \
	TOUCHPAD_PATCHER_BOOT_MANAGER=grub \
	"$repo_dir/scripts/t14-ps2-native-manager.sh" status 2>"$case_dir/stale-error")
status=$?
set -e
[[ $status -eq 20 && $stale_output == not-managed ]]
grep -Fq 'stale native state cleared' "$case_dir/stale-error"
[[ ! -e "$fixture_dir/var/lib/t14-len2068-touchpad-patch/native-state" ]]
run_launcher "$case_dir/second-output"
grep -Fq 'Native fix installed' "$case_dir/second-output"

# Multiple GRUB installations are safe when BootCurrent resolves to Mint/Ubuntu.
make_case active-ubuntu-chain
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
enable_uefi 0003 Ubuntu ubuntu 0001 Fedora fedora
run_launcher "$case_dir/install-output"
grep -Fq 'active EFI GRUB chain verified: BootCurrent 0003' "$case_dir/install-output"
grep -Fq 'Native fix installed' "$case_dir/install-output"
printf '%s\n' 'quiet splash psmouse.synaptics_intertouch=0' >"$fixture_dir/proc/cmdline"
run_launcher "$case_dir/reboot-output"
grep -Fq 'Native fix kept' "$case_dir/reboot-output"

# A generated Mint config is irrelevant when BootCurrent is Fedora's GRUB chain.
make_case active-fedora-chain-mismatch
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
printf '%s\n' '    linux /boot/vmlinuz-test root=UUID=test ro quiet splash psmouse.synaptics_intertouch=0' >"$fixture_dir/boot/grub/grub.cfg"
enable_uefi 0001 Fedora fedora 0003 Ubuntu ubuntu
set +e
run_launcher "$case_dir/output"
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'active EFI boot chain mismatch' "$case_dir/output"
grep -Fq '\EFI\fedora\shimx64.efi' "$case_dir/output"
[[ ! -e "$trace_file" ]]
if grep -Fq 'psmouse.synaptics_intertouch=0' "$fixture_dir/etc/default/grub"; then exit 1; fi

# Missing/ambiguous BootCurrent fails before any persistent modification.
make_case ambiguous-efi-chain
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
mkdir -p "$fixture_dir/sys/firmware/efi"
printf '%s\n' \
	'Boot0001* Fedora HD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0x100000)/File(\EFI\fedora\shimx64.efi)' \
	'Boot0003* Ubuntu HD(1,GPT,ffffffff-1111-2222-3333-444444444444,0x800,0x100000)/File(\EFI\ubuntu\shimx64.efi)' \
	>"$fixture_dir/efibootmgr.out"
cat >"$fake_bin/efibootmgr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat "$TOUCHPAD_PATCHER_TEST_ROOT/efibootmgr.out"
SH
chmod +x "$fake_bin/efibootmgr"
set +e
run_launcher "$case_dir/output"
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'UEFI BootCurrent is missing or invalid; the active boot chain is ambiguous' "$case_dir/output"
[[ ! -e "$trace_file" ]]
if grep -Fq 'psmouse.synaptics_intertouch=0' "$fixture_dir/etc/default/grub"; then exit 1; fi

# A root-only generated GRUB file is verified through the privileged reader.
make_case root-only-grub
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash psmouse.synaptics_intertouch=0"' >"$fixture_dir/etc/default/grub"
printf '%s\n' '    linux /boot/vmlinuz-test root=UUID=test ro quiet splash psmouse.synaptics_intertouch=0 $vt_handoff' >"$fixture_dir/boot/grub/grub.cfg"
chmod 000 "$fixture_dir/boot/grub/grub.cfg"
if cat "$fixture_dir/boot/grub/grub.cfg" >/dev/null 2>&1; then exit 1; fi
cat >"$fake_bin/privileged-run" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == cat ]]; then
	target=${!#}
	chmod u+r "$target"
	set +e
	"$@"
	status=$?
	set -e
	chmod 000 "$target"
	exit "$status"
fi
"$@"
SH
chmod +x "$fake_bin/privileged-run"
run_launcher "$case_dir/output" TOUCHPAD_PATCHER_TEST_SUDO_RUNNER="$fake_bin/privileged-run"
grep -Fq 'generated GRUB kernel entries verified' "$case_dir/output"
grep -Fq 'Native fix installed' "$case_dir/output"
[[ ! -e "$trace_file" ]]

# A privileged read failure is explicit and never becomes "parameter absent".
make_case unreadable-grub
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash psmouse.synaptics_intertouch=0"' >"$fixture_dir/etc/default/grub"
printf '%s\n' '    linux /boot/vmlinuz-test root=UUID=test ro quiet splash psmouse.synaptics_intertouch=0' >"$fixture_dir/boot/grub/grub.cfg"
chmod 000 "$fixture_dir/boot/grub/grub.cfg"
if cat "$fixture_dir/boot/grub/grub.cfg" >/dev/null 2>&1; then exit 1; fi
set +e
run_launcher "$case_dir/output"
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'generated GRUB configuration could not be read with administrator privileges' "$case_dir/output"
[[ ! -e "$trace_file" ]]

# A readable file must contain the exact token on a generated kernel command.
make_case token-not-on-linux-command
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash psmouse.synaptics_intertouch=0"' >"$fixture_dir/etc/default/grub"
printf '%s\n' '# psmouse.synaptics_intertouch=0' '    linux /boot/vmlinuz-test root=UUID=test ro quiet splash' >"$fixture_dir/boot/grub/grub.cfg"
set +e
run_launcher "$case_dir/output"
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq "generated GRUB kernel command lines do not contain the exact argument 'psmouse.synaptics_intertouch=0'" "$case_dir/output"
[[ ! -e "$trace_file" ]]

# A genuinely unsupported kernel reaches the custom fallback offer/path.
make_case native-unsupported
run_launcher "$case_dir/output"
grep -Fq 'does not expose the required parameter' "$case_dir/output"
grep -Fq ' all' "$trace_file"

# An unexpected native application error stops; fallback must not run.
make_case native-apply-failure
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
set +e
TOUCHPAD_TEST_UPDATE_GRUB_FAIL=1 run_launcher "$case_dir/output"
status=$?
set -e
[[ $status -eq 42 ]]
grep -Fq 'Native installation failed; the kernel fallback was not started automatically.' "$case_dir/output"
[[ ! -e "$trace_file" ]]

printf '%s\n' 'launcher integration tests passed'
