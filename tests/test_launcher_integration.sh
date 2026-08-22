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
	printf '%s\n' \
		"menuentry 'Linux Mint test' {" \
		'    linux /boot/vmlinuz-6.8.0-85-generic root=UUID=test ro quiet splash' \
		'}' >"$fixture_dir/boot/grub/grub.cfg"
	printf '%s\n' 'quiet splash' >"$fixture_dir/proc/cmdline"
	printf '%s\n' 'N: Name="SynPS/2 Synaptics TouchPad"' >"$fixture_dir/proc/bus/input/devices"

	cat >"$fake_bin/update-grub" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ ${TOUCHPAD_TEST_UPDATE_GRUB_FAIL:-0} != 1 ]] || exit 42
# shellcheck disable=SC1091
. "$TOUCHPAD_PATCHER_TEST_ROOT/etc/default/grub"
printf "menuentry 'Linux Mint test' {\n    linux /boot/vmlinuz-6.8.0-85-generic root=UUID=test ro %s \$vt_handoff\n}\n" \
	"$GRUB_CMDLINE_LINUX_DEFAULT" >"$TOUCHPAD_PATCHER_TEST_ROOT/boot/grub/grub.cfg"
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
	mkdir -p "$fixture_dir/sys/firmware/efi" "$fixture_dir/boot/efi/EFI/$current_vendor" "$fixture_dir/boot/efi/EFI/$other_vendor"
	touch "$fixture_dir/boot/efi/EFI/$current_vendor/shimx64.efi" "$fixture_dir/boot/efi/EFI/$other_vendor/shimx64.efi"
	printf '%s\n' \
		'search.fs_uuid 11111111-2222-3333-4444-555555555555 root' \
		"set prefix=(\$root)'/boot/grub'" \
		'configfile $prefix/grub.cfg' >"$fixture_dir/boot/efi/EFI/$current_vendor/grub.cfg"
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

enable_foreign_grub() {
	local current_label=$1 current_vendor=$2 chain_uuid=$3 root_uuid=$4 kernel=$5 title=$6
	mkdir -p "$fixture_dir/sys/firmware/efi" "$fixture_dir/boot/efi/EFI/$current_vendor" \
		"$fixture_dir/filesystems/$chain_uuid/grub2"
	touch "$fixture_dir/boot/efi/EFI/$current_vendor/shimx64.efi"
	printf '%s\n' \
		"search --no-floppy --root-dev-only --fs-uuid --set=dev $chain_uuid" \
		'set prefix=($dev)/grub2' \
		'export $prefix' \
		'configfile $prefix/grub.cfg' >"$fixture_dir/boot/efi/EFI/$current_vendor/grub.cfg"
	printf '%s\n' \
		'BootCurrent: 0001' \
		"Boot0001* $current_label HD(1,GPT,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,0x800,0x100000)/\\EFI\\$current_vendor\\shimx64.efi" \
		>"$fixture_dir/efibootmgr.out"
	cat >"$fake_bin/efibootmgr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat "$TOUCHPAD_PATCHER_TEST_ROOT/efibootmgr.out"
SH
	chmod +x "$fake_bin/efibootmgr"
	printf '%s\n' \
		'### BEGIN /etc/grub.d/30_os-prober ###' \
		"menuentry '$title' {" \
		"    linux /boot/vmlinuz-$kernel root=UUID=$root_uuid ro quiet splash" \
		'}' \
		'### END /etc/grub.d/30_os-prober ###' \
		>"$fixture_dir/filesystems/$chain_uuid/grub2/grub.cfg"
}

make_privileged_chain_runner() {
	cat >"$fake_bin/privileged-chain-run" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root=$TOUCHPAD_PATCHER_TEST_ROOT
printf '%q ' "$@" >>"$TOUCHPAD_TEST_PRIVILEGED_TRACE"
printf '\n' >>"$TOUCHPAD_TEST_PRIVILEGED_TRACE"
chmod u+rwx "$root/boot/efi" 2>/dev/null || true
find "$root/boot/efi" "$root/devices" "$root/run" -mindepth 1 -exec chmod u+rwX {} + 2>/dev/null || true
case ${1:-} in
	findmnt)
		case ${TOUCHPAD_TEST_FINDMNT_MODE:-unmounted} in
			mounted) printf '%s\n' "${TOUCHPAD_TEST_EXISTING_MOUNT:?}"; status=0 ;;
			unmounted) status=1 ;;
			error) status=2 ;;
		esac
		;;
	mount)
		if [[ ${TOUCHPAD_TEST_MOUNT_FAIL:-0} == 1 ]]; then status=32; else
		source=${@: -2:1}
		target=${@: -1}
		mkdir -p -- "$target"
		ln -s -- "$source/grub2" "$target/grub2"
		[[ ! -d "$source/boot" ]] || ln -s -- "$source/boot" "$target/boot"
		status=0
		if [[ ${TOUCHPAD_TEST_SIGNAL_AFTER_MOUNT:-0} == 1 ]]; then kill -TERM "$PPID"; fi
		fi
		;;
	umount)
		target=${!#}
		if [[ -L "$target/grub2" ]]; then
			unlink "$target/grub2"
			[[ ! -L "$target/boot" ]] || unlink "$target/boot"
			status=0
		else status=32; fi
		;;
	*)
		set +e
		"$@"
		status=$?
		set -e
		;;
esac
find "$root/boot/efi" "$root/devices" -type f -exec chmod 000 {} + 2>/dev/null || true
chmod 000 "$root/boot/efi" 2>/dev/null || true
exit "$status"
SH
	chmod +x "$fake_bin/privileged-chain-run"
}

run_launcher() {
	local output_file=$1
	shift
	env -u DISPLAY -u WAYLAND_DISPLAY \
		PATH="$fake_bin:$PATH" \
		TOUCHPAD_PATCHER_TESTING=1 \
		TOUCHPAD_PATCHER_TEST_ROOT="$fixture_dir" \
		TOUCHPAD_PATCHER_BOOT_MANAGER=grub \
		TOUCHPAD_PATCHER_TEST_UNAME_R="${TOUCHPAD_PATCHER_TEST_UNAME_R:-6.8.0-85-generic}" \
		TOUCHPAD_PATCHER_TEST_GRUB_UUID=11111111-2222-3333-4444-555555555555 \
		TOUCHPAD_TEST_INSTALLER_TRACE="$trace_file" \
		XDG_CACHE_HOME="$case_dir/cache with spaces" \
		"$@" "$repo_dir/Run Touchpad Patcher.sh" >"$output_file" 2>&1
}

# Mint/GRUB native success from a repository path containing spaces.
make_case native-success
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
run_launcher "$case_dir/output" TOUCHPAD_PATCHER_TEST_HARDWARE_LOG=1
grep -Fq 'ThinkPad T14 Gen 1 with LEN2068 detected' "$case_dir/output"
if grep -Fq 'JSONDecodeError' "$case_dir/output"; then exit 1; fi
grep -Fq 'Native fix installed' "$case_dir/output"
grep -Fq 'psmouse.synaptics_intertouch=0' "$fixture_dir/etc/default/grub"
grep -Fq 'linux /boot/vmlinuz-6.8.0-85-generic root=UUID=test ro quiet splash psmouse.synaptics_intertouch=0 $vt_handoff' "$fixture_dir/boot/grub/grub.cfg"
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
grep -Fq 'active GRUB chain traced:' "$case_dir/install-output"
grep -Fq 'Native fix installed' "$case_dir/install-output"
printf '%s\n' 'quiet splash psmouse.synaptics_intertouch=0' >"$fixture_dir/proc/cmdline"
run_launcher "$case_dir/reboot-output"
grep -Fq 'Native fix kept' "$case_dir/reboot-output"

# The physical Fedora-GRUB-booting-Mint chain is traced to its os-prober entry,
# but generated foreign configuration is never edited as a persistent source.
make_case fedora-grub-booting-mint
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
# Mint's inactive generated configuration has the token; Fedora's active entry does not.
printf '%s\n' \
	"menuentry 'Linux Mint inactive' {" \
	'    linux /boot/vmlinuz-6.8.0-85-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro quiet splash psmouse.synaptics_intertouch=0' \
	'}' >"$fixture_dir/boot/grub/grub.cfg"
enable_foreign_grub Fedora FeDoRa 2b35be97-3acf-4fde-8fa4-9961c3202da2 \
	501f6d9f-910b-4ff3-8820-ac4e2272bf8b 6.14.0-37-generic \
	'Linux Mint 22.3 Cinnamon (on /dev/nvme0n1p4)'
foreign_root="$fixture_dir/filesystems/2b35be97-3acf-4fde-8fa4-9961c3202da2"
saved_fedora_entry=4076fe3979de4e6f8953e741454d8241-7.1.8-t14ps2quirk1
mkdir -p "$foreign_root/boot/loader/entries"
printf 'saved_entry=%s\n' "$saved_fedora_entry" >"$foreign_root/grub2/grubenv"
printf '%s\n' 'title Fedora patched kernel' "version $saved_fedora_entry" \
	>"$foreign_root/boot/loader/entries/$saved_fedora_entry.conf"
printf '%s\n' \
	'### BEGIN /etc/grub.d/30_os-prober ###' \
	"menuentry 'Linux Mint 22.3 Cinnamon (on /dev/nvme0n1p4)' --id 'osprober-mint-current' {" \
	'    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro quiet splash' \
	'}' \
	"menuentry 'Linux Mint 22.3 Cinnamon, with Linux 6.14.0-37-generic (on /dev/nvme0n1p4)' --id 'osprober-mint-current' {" \
	'    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro quiet splash' \
	'}' \
	"menuentry 'Linux Mint 22.3 Cinnamon, with Linux 6.14.0-37-generic (recovery mode) (on /dev/nvme0n1p4)' --id 'osprober-mint-recovery' {" \
	'    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro recovery nomodeset' \
	'}' \
	'### END /etc/grub.d/30_os-prober ###' \
	>"$foreign_root/grub2/grub.cfg"
if grep -Fq "$saved_fedora_entry" "$foreign_root/grub2/grub.cfg"; then exit 1; fi
[[ -e "$fixture_dir/boot/efi/EFI/FeDoRa/shimx64.efi" ]]
[[ ! -e "$fixture_dir/boot/efi/efi/fedora/shimx64.efi" ]]
mkdir -p "$fixture_dir/devices" "$fixture_dir/run"
mv "$fixture_dir/filesystems/2b35be97-3acf-4fde-8fa4-9961c3202da2" "$fixture_dir/devices/"
privileged_trace="$case_dir/privileged trace"
: >"$privileged_trace"
make_privileged_chain_runner
find "$fixture_dir/boot/efi" "$fixture_dir/devices" -type f -exec chmod 000 {} +
chmod 000 "$fixture_dir/boot/efi"
if test -e "$fixture_dir/boot/efi/EFI/FeDoRa/shimx64.efi"; then exit 1; fi
# A v2.0.3-style pending record is reconciled against the active Fedora entry.
mkdir -p "$fixture_dir/var/lib/t14-len2068-touchpad-patch"
printf '%s\n' \
	'method=native' 'adapter=grub' 'boot_manager=grub' \
	>"$fixture_dir/var/lib/t14-len2068-touchpad-patch/native-state"
printf 'config_path=%q\nprior_conflict=0\nstatus=pending-verification\n' "$fixture_dir/etc/default/grub" \
	>>"$fixture_dir/var/lib/t14-len2068-touchpad-patch/native-state"
set +e
foreign_status=$(env PATH="$fake_bin:$PATH" \
	TOUCHPAD_PATCHER_TESTING=1 \
	TOUCHPAD_PATCHER_TEST_ROOT="$fixture_dir" \
	TOUCHPAD_PATCHER_TEST_ROOT_UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b \
	TOUCHPAD_PATCHER_TEST_UNAME_R=6.14.0-37-generic \
	TOUCHPAD_PATCHER_TEST_FORCE_TEMP_MOUNT=1 \
	TOUCHPAD_PATCHER_TEST_SUDO_RUNNER="$fake_bin/privileged-chain-run" \
	TOUCHPAD_TEST_PRIVILEGED_TRACE="$privileged_trace" \
	TOUCHPAD_PATCHER_BOOT_MANAGER=grub \
	"$repo_dir/scripts/t14-ps2-native-manager.sh" status 2>"$case_dir/foreign-status-error")
status=$?
set -e
[[ $status -eq 20 && $foreign_status == not-managed ]]
[[ ! -e "$fixture_dir/var/lib/t14-len2068-touchpad-patch/native-state" ]]
[[ ! -e "$fixture_dir/run/t14-len2068-touchpad-patch/grub-2b35be97-3acf-4fde-8fa4-9961c3202da2" ]]
set +e
TOUCHPAD_PATCHER_TEST_ROOT_UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b \
	TOUCHPAD_PATCHER_TEST_UNAME_R=6.14.0-37-generic \
	TOUCHPAD_PATCHER_TEST_FORCE_TEMP_MOUNT=1 \
	TOUCHPAD_PATCHER_TEST_SUDO_RUNNER="$fake_bin/privileged-chain-run" \
	TOUCHPAD_TEST_PRIVILEGED_TRACE="$privileged_trace" \
	run_launcher "$case_dir/output"
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'Active EFI entry' "$case_dir/output" || grep -Fq 'active EFI entry' "$case_dir/output"
grep -Fq 'current linuxmint installation is booted through Fedora GRUB via an os-prober-generated entry' "$case_dir/output"
grep -Fq 'collapsed 2 equivalent normal GRUB entries into one logical target (menu ID osprober-mint-current)' "$case_dir/output"
grep -Fq "Fedora GRUB saved/default entry: $saved_fedora_entry (independent of the current Mint entry)" "$case_dir/output"
grep -Fq "Fedora saved entry is backed by BLS:" "$case_dir/output"
grep -Fq 'cannot be modified safely from the running installation' "$case_dir/output"
grep -Fq 'mount -o ro --' "$privileged_trace"
grep -Fq 'findmnt -rn -S' "$privileged_trace"
grep -Fq 'umount --' "$privileged_trace"
grep -Fq 'cat --' "$privileged_trace"
[[ ! -e "$fixture_dir/run/t14-len2068-touchpad-patch/grub-2b35be97-3acf-4fde-8fa4-9961c3202da2" ]]
[[ ! -e "$trace_file" ]]
if grep -Fq 'psmouse.synaptics_intertouch=0' "$fixture_dir/etc/default/grub"; then exit 1; fi

# Mint adopts a fix that is genuinely active through Fedora's authoritative
# os-prober entry. Verification succeeds, but local rollback remains blocked.
foreign_generated="$fixture_dir/devices/2b35be97-3acf-4fde-8fa4-9961c3202da2/grub2/grub.cfg"
chmod u+rw "$foreign_generated"
sed -i '/ro quiet splash$/s/$/ psmouse.synaptics_intertouch=0/' "$foreign_generated"
chmod 000 "$foreign_generated"
printf '%s\n' 'quiet splash psmouse.synaptics_intertouch=0' >"$fixture_dir/proc/cmdline"
TOUCHPAD_PATCHER_TEST_ROOT_UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b \
	TOUCHPAD_PATCHER_TEST_UNAME_R=6.14.0-37-generic \
	TOUCHPAD_PATCHER_TEST_FORCE_TEMP_MOUNT=1 \
	TOUCHPAD_PATCHER_TEST_SUDO_RUNNER="$fake_bin/privileged-chain-run" \
	TOUCHPAD_TEST_PRIVILEGED_TRACE="$privileged_trace" \
	run_launcher "$case_dir/foreign-adoption-output"
grep -Fq 'Native fix recognised and runtime verified' "$case_dir/foreign-adoption-output"
grep -Fq 'rollback is available only from that owning installation' "$case_dir/foreign-adoption-output"
grep -Fq 'ownership=external' "$fixture_dir/var/lib/t14-len2068-touchpad-patch/native-state"
grep -Fq 'status=verified' "$fixture_dir/var/lib/t14-len2068-touchpad-patch/native-state"
set +e
rollback_output=$(env PATH="$fake_bin:$PATH" \
	TOUCHPAD_PATCHER_TESTING=1 \
	TOUCHPAD_PATCHER_TEST_ROOT="$fixture_dir" \
	TOUCHPAD_PATCHER_TEST_SUDO_RUNNER="$fake_bin/privileged-chain-run" \
	TOUCHPAD_TEST_PRIVILEGED_TRACE="$privileged_trace" \
	TOUCHPAD_PATCHER_BOOT_MANAGER=grub \
	"$repo_dir/scripts/t14-ps2-native-manager.sh" rollback 2>&1)
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'rollback must be run from the authoritative bootloader owner' <<<"$rollback_output"
TOUCHPAD_PATCHER_TEST_ROOT="$fixture_dir" TOUCHPAD_TEST_PRIVILEGED_TRACE="$privileged_trace" \
	"$fake_bin/privileged-chain-run" cat -- "$foreign_generated" | grep -Fq 'psmouse.synaptics_intertouch=0'

# An already-mounted active GRUB filesystem is reused without a temporary mount.
: >"$privileged_trace"
set +e
mounted_output=$(env PATH="$fake_bin:$PATH" \
	TOUCHPAD_PATCHER_TESTING=1 \
	TOUCHPAD_PATCHER_TEST_ROOT="$fixture_dir" \
	TOUCHPAD_PATCHER_TEST_ROOT_UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b \
	TOUCHPAD_PATCHER_TEST_UNAME_R=6.14.0-37-generic \
	TOUCHPAD_PATCHER_TEST_FORCE_TEMP_MOUNT=1 \
	TOUCHPAD_PATCHER_TEST_SUDO_RUNNER="$fake_bin/privileged-chain-run" \
	TOUCHPAD_TEST_PRIVILEGED_TRACE="$privileged_trace" \
	TOUCHPAD_TEST_FINDMNT_MODE=mounted \
	TOUCHPAD_TEST_EXISTING_MOUNT="$fixture_dir/devices/2b35be97-3acf-4fde-8fa4-9961c3202da2" \
	TOUCHPAD_PATCHER_BOOT_MANAGER=grub \
	"$repo_dir/scripts/t14-ps2-native-manager.sh" --yes apply 2>&1)
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'active GRUB filesystem already mounted' <<<"$mounted_output"
if grep -Fq 'mount -o ro --' "$privileged_trace"; then exit 1; fi

# A failed temporary mount remains fatal, is cleaned, and never starts fallback.
: >"$privileged_trace"
set +e
TOUCHPAD_PATCHER_TEST_ROOT_UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b \
	TOUCHPAD_PATCHER_TEST_UNAME_R=6.14.0-37-generic \
	TOUCHPAD_PATCHER_TEST_FORCE_TEMP_MOUNT=1 \
	TOUCHPAD_PATCHER_TEST_SUDO_RUNNER="$fake_bin/privileged-chain-run" \
	TOUCHPAD_TEST_PRIVILEGED_TRACE="$privileged_trace" \
	TOUCHPAD_TEST_MOUNT_FAIL=1 \
	run_launcher "$case_dir/mount-failure-output"
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'could not be mounted read-only' "$case_dir/mount-failure-output"
[[ ! -e "$trace_file" ]]
[[ ! -e "$fixture_dir/run/t14-len2068-touchpad-patch/grub-2b35be97-3acf-4fde-8fa4-9961c3202da2" ]]

# A genuine findmnt error is fatal and is not treated as "not mounted".
: >"$privileged_trace"
set +e
TOUCHPAD_PATCHER_TEST_ROOT_UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b \
	TOUCHPAD_PATCHER_TEST_UNAME_R=6.14.0-37-generic \
	TOUCHPAD_PATCHER_TEST_FORCE_TEMP_MOUNT=1 \
	TOUCHPAD_PATCHER_TEST_SUDO_RUNNER="$fake_bin/privileged-chain-run" \
	TOUCHPAD_TEST_PRIVILEGED_TRACE="$privileged_trace" \
	TOUCHPAD_TEST_FINDMNT_MODE=error \
	run_launcher "$case_dir/findmnt-failure-output"
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'findmnt failed while inspecting the active GRUB device' "$case_dir/findmnt-failure-output"
if grep -Fq 'mount -o ro --' "$privileged_trace"; then exit 1; fi
[[ ! -e "$trace_file" ]]

# TERM after a successful mount still runs the EXIT cleanup and removes it.
: >"$privileged_trace"
set +e
env PATH="$fake_bin:$PATH" \
	TOUCHPAD_PATCHER_TESTING=1 \
	TOUCHPAD_PATCHER_TEST_ROOT="$fixture_dir" \
	TOUCHPAD_PATCHER_TEST_ROOT_UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b \
	TOUCHPAD_PATCHER_TEST_UNAME_R=6.14.0-37-generic \
	TOUCHPAD_PATCHER_TEST_FORCE_TEMP_MOUNT=1 \
	TOUCHPAD_PATCHER_TEST_SUDO_RUNNER="$fake_bin/privileged-chain-run" \
	TOUCHPAD_TEST_PRIVILEGED_TRACE="$privileged_trace" \
	TOUCHPAD_TEST_SIGNAL_AFTER_MOUNT=1 \
	TOUCHPAD_PATCHER_BOOT_MANAGER=grub \
	"$repo_dir/scripts/t14-ps2-native-manager.sh" --yes apply >"$case_dir/signal-output" 2>&1
status=$?
set -e
[[ $status -eq 143 ]]
grep -Fq 'umount --' "$privileged_trace"
[[ ! -e "$fixture_dir/run/t14-len2068-touchpad-patch/grub-2b35be97-3acf-4fde-8fa4-9961c3202da2" ]]
chmod u+rwx "$fixture_dir/boot/efi"

# The inverse arrangement is also traced: Fedora may run through Ubuntu GRUB.
make_case ubuntu-grub-booting-fedora
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
printf '%s\n' 'ID=fedora' 'ID_LIKE="rhel"' 'PRETTY_NAME="Fedora Linux"' >"$fixture_dir/etc/os-release"
enable_foreign_grub Ubuntu ubuntu aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee \
	fed0fed0-1111-2222-3333-444444444444 6.8.0-85-generic \
	'Fedora Linux (on /dev/nvme0n1p2)'
set +e
TOUCHPAD_PATCHER_TEST_ROOT_UUID=fed0fed0-1111-2222-3333-444444444444 run_launcher "$case_dir/output"
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'current fedora installation is booted through Ubuntu GRUB via an os-prober-generated entry' "$case_dir/output"
grep -Fq 'cannot be modified safely from the running installation' "$case_dir/output"
[[ ! -e "$trace_file" ]]

# A failed privileged inspection is not misreported as a missing EFI loader.
make_case privileged-efi-inspection-failure
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
enable_uefi 0003 Ubuntu ubuntu 0001 Fedora fedora
cat >"$fake_bin/failing-privileged-run" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == python3 && ${*: -2:1} == *shimx64.efi ]]; then
	printf '%s\n' 'simulated privileged inspection failure' >&2
	exit 4
fi
"$@"
SH
chmod +x "$fake_bin/failing-privileged-run"
set +e
run_launcher "$case_dir/output" TOUCHPAD_PATCHER_TEST_SUDO_RUNNER="$fake_bin/failing-privileged-run"
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'active EFI loader could not be inspected with administrator privileges' "$case_dir/output"
if grep -Fq 'active EFI loader is not present' "$case_dir/output"; then exit 1; fi
[[ ! -e "$trace_file" ]]

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

# A patched current Fedora/custom kernel is recorded and verified, but does not
# end machine inspection before the native configuration path is considered.
make_case patched-kernel-keeps-scanning
printf '%s\n' 0 >"$fixture_dir/sys/module/psmouse/parameters/synaptics_intertouch"
TOUCHPAD_PATCHER_TEST_UNAME_R=7.1.8-t14ps2quirk1 run_launcher "$case_dir/output"
grep -Fq 'already patched; it has been preserved' "$case_dir/output"
grep -Fq 'machine inspection will continue' "$case_dir/output"
grep -Fq 'Current patched-kernel remediation runtime verified' "$case_dir/output"
grep -Fq 'Native fix installed' "$case_dir/output"
grep -Fq 'verify' "$trace_file"
if grep -Fq ' all' "$trace_file"; then exit 1; fi

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
