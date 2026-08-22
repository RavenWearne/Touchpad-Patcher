#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manager="$project_dir/scripts/t14-ps2-native-manager.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/proc/bus/input" "$fixture/sys/module/psmouse/parameters" "$fixture/etc/kernel" "$fixture/boot/loader/entries" "$fixture/var/lib/t14-len2068-touchpad-patch"
printf 'ID=cachyos\n' >"$fixture/etc/os-release"
printf '%s\n' '0' >"$fixture/sys/module/psmouse/parameters/synaptics_intertouch"
printf '%s\n' 'quiet psmouse.synaptics_intertouch=0' >"$fixture/proc/cmdline"
printf '%s\n' 'N: Name="SynPS/2 Synaptics TouchPad"' >"$fixture/proc/bus/input/devices"
printf '%s\n' 'quiet psmouse.synaptics_intertouch=0' >"$fixture/etc/kernel/cmdline"
printf '%s\n' 'options quiet psmouse.synaptics_intertouch=0' >"$fixture/boot/loader/entries/test.conf"

export TOUCHPAD_PATCHER_TESTING=1
export TOUCHPAD_PATCHER_TEST_ROOT=$fixture
export TOUCHPAD_PATCHER_BOOT_MANAGER=systemd-boot

[[ "$("$manager" status)" == native-active ]]
output=$("$manager" verify)
grep -q 'native stock-kernel fix verified' <<<"$output"

rm -f -- "$fixture/var/lib/t14-len2068-touchpad-patch/native-state"

printf '%s\n' 'quiet' >"$fixture/proc/cmdline"
set +e
status=$("$manager" status)
code=$?
set -e
[[ $code -eq 20 && $status == not-managed ]]

mkdir -p "$fixture/boot"
printf '%s\n' '"Boot using default options" "root=UUID=test quiet"' >"$fixture/boot/refind_linux.conf"
export TOUCHPAD_PATCHER_BOOT_MANAGER=refind
output=$("$manager" --yes apply)
grep -q 'native parameter installed' <<<"$output"
grep -q 'psmouse.synaptics_intertouch=0' "$fixture/boot/refind_linux.conf"
[[ -r "$fixture/var/lib/t14-len2068-touchpad-patch/native-state" ]]

printf '%s\n' 'quiet psmouse.synaptics_intertouch=0' >"$fixture/proc/cmdline"
output=$("$manager" verify)
grep -q 'native stock-kernel fix verified' <<<"$output"
output=$("$manager" rollback)
grep -q 'native parameter removed' <<<"$output"
if grep -q 'psmouse.synaptics_intertouch=0' "$fixture/boot/refind_linux.conf"; then exit 1; fi

printf '%s\n' 'quiet' >"$fixture/proc/cmdline"
output=$("$manager" complete-rollback)
grep -q 'rollback verified' <<<"$output"
[[ ! -e "$fixture/var/lib/t14-len2068-touchpad-patch/native-state" ]]

printf '%s\n' 'native manager fixture tests passed'
