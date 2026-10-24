#!/bin/bash
#
# The N1x recovery entry's probe copies its evidence onto a partition
# labelled OMARCHY-PROBE, and only onto one on a removable or USB disk: it
# must never write to the laptop's own disks.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
probe="$ROOT/configs/airootfs/usr/local/sbin/omarchy-n1x-live-probe"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$probe"
grep -Fqx 'log=/var/log/omarchy-n1x-live-probe.log' "$probe" || fail "the probe no longer logs to /var/log"
grep -Fqx 'probe_label=OMARCHY-PROBE' "$probe" || fail "the probe does not look for OMARCHY-PROBE"
grep -Fq '! -name '\''MSDM*'\' "$probe" || fail "the probe would copy the Windows product key"
grep -Fq 'EXPOSED_DISP_FRM-4b086294-0740-4f71-a7b5-85a329c7ec5f' "$probe" || fail "the probe does not record the GPU carve-out"
grep -Fq 'NVDA8400' "$probe" || fail "the probe does not show whether SSPM is hidden"
eval "$(sed -n '/^copy_to_probe_partition() {$/,/^}$/p' "$probe")"
declare -F copy_to_probe_partition >/dev/null || fail "the probe has no copy_to_probe_partition"

probe_label=OMARCHY-PROBE
bundle=$work/var/log/omarchy-n1x-live-probe-20261025-101500
mkdir -p "$bundle/acpi-tables/dynamic"
echo log >"$bundle/omarchy-n1x-live-probe.log"
echo table >"$bundle/acpi-tables/dynamic/SSDT1"
export TMPDIR=$work/tmp
mkdir -p "$TMPDIR"

# Disks as lsblk reports them: the laptop's NVMe drive, the card in its own
# SD slot (the kernel never marks an MMC disk removable, so it cannot be
# told from soldered eMMC), a USB stick (RM 0, as many report themselves), a
# removable disk whose transport lsblk does not name, and a stick formatted
# without a partition table.
declare -A parent=([/dev/nvme0n1p3]=/dev/nvme0n1 [/dev/mmcblk0p1]=/dev/mmcblk0 [/dev/sda1]=/dev/sda [/dev/sdc1]=/dev/sdc)
declare -A rmtran=([/dev/nvme0n1]='0 nvme' [/dev/mmcblk0]='0 mmc' [/dev/sda]='0 usb' [/dev/sdc]='1 ' [/dev/sdb]='1 usb')
lsblk() {
  case "$*" in
    '-nrpo NAME,LABEL') printf '%s\n' "${disks[@]}" ;;
    '-dnpo PKNAME '*) printf '%s\n' "${parent[${*: -1}]:-}" ;;
    '-dnro RM,TRAN '*) printf '%s\n' "${rmtran[${*: -1}]:-}" ;;
    *) echo "lsblk $*" >>"$work/unexpected" ;;
  esac
}
# A mount leaves what was written on the "disk" when it is unmounted.
mount() {
  echo "mount $*" >>"$work/calls"
  [[ -z ${mount_fails:-} ]]
}
umount() {
  echo "umount $*" >>"$work/calls"
  mv "$1" "$work/disk"
  mkdir "$1"
}
sync() { :; }
fresh_disks() { rm -rf "$work/calls" "$work/disk" "$work/unexpected" "$TMPDIR"/*; mount_fails=; }

# Only the laptop's own disks carry the label, or a near miss of it.
fresh_disks
disks=('/dev/nvme0n1 ' '/dev/nvme0n1p3 OMARCHY-PROBE' '/dev/mmcblk0 ' '/dev/mmcblk0p1 OMARCHY-PROBE' '/dev/sda ' '/dev/sda1 OMARCHY-PROBES')
out=$(copy_to_probe_partition) && fail "the probe reported a copy with no removable disk: $out"
[[ ! -e $work/calls ]] || fail "the probe mounted a partition it must not write to: $(cat "$work/calls")"
grep -Fq '/dev/nvme0n1p3 is labelled OMARCHY-PROBE, but /dev/nvme0n1 is neither removable nor on USB' <<<"$out" \
  && grep -Fq '/dev/mmcblk0p1 is labelled OMARCHY-PROBE, but /dev/mmcblk0 is neither removable nor on USB' <<<"$out" \
  || fail "the probe does not say why it left the internal partitions alone: $out"
grep -Fq 'the evidence stays in' <<<"$out" || fail "the probe does not say where the evidence stayed: $out"
echo "ok - a labelled partition on the laptop's own disk is never mounted"

# A USB stick is used, even after the internal disk's labelled partition.
fresh_disks
disks=('/dev/nvme0n1 ' '/dev/nvme0n1p3 OMARCHY-PROBE' '/dev/sda ' '/dev/sda1 OMARCHY-PROBE')
out=$(copy_to_probe_partition) || fail "the probe did not copy to a USB stick: $out"
[[ $(grep -c '^mount ' "$work/calls") == 1 ]] && grep -q '^mount -o rw,noatime /dev/sda1 ' "$work/calls" \
  || fail "the probe mounted something other than the USB stick: $(cat "$work/calls")"
grep -q '^umount ' "$work/calls" || fail "the probe left the USB stick mounted"
cmp -s "$work/disk/omarchy-n1x-live-probe-20261025-101500/omarchy-n1x-live-probe.log" "$bundle/omarchy-n1x-live-probe.log" \
  && cmp -s "$work/disk/omarchy-n1x-live-probe-20261025-101500/acpi-tables/dynamic/SSDT1" "$bundle/acpi-tables/dynamic/SSDT1" \
  || fail "the bundle did not reach the USB stick in a directory of its own"
[[ -z $(ls -A "$TMPDIR") ]] || fail "the probe left its mount point behind"
echo "ok - a USB stick labelled OMARCHY-PROBE gets the bundle in a new directory"

# A removable disk counts whatever its transport, a label typed in lower case
# too, and so does a disk without a partition table.
fresh_disks
disks=('/dev/sdc ' '/dev/sdc1 omarchy-probe')
out=$(copy_to_probe_partition) || fail "the probe did not copy to a removable disk: $out"
grep -q '^mount -o rw,noatime /dev/sdc1 ' "$work/calls" || fail "the probe did not mount the removable disk: $(cat "$work/calls")"
fresh_disks
disks=('/dev/sdb OMARCHY-PROBE')
out=$(copy_to_probe_partition) || fail "the probe did not copy to a stick without partitions: $out"
grep -q '^mount -o rw,noatime /dev/sdb ' "$work/calls" || fail "the probe did not mount the whole stick: $(cat "$work/calls")"
echo "ok - removable disks and unpartitioned sticks qualify"

# A partition that will not mount is reported, and nothing is left behind.
fresh_disks
mount_fails=1
disks=('/dev/sda ' '/dev/sda1 OMARCHY-PROBE')
out=$(copy_to_probe_partition) && fail "the probe reported a copy to a partition it could not mount: $out"
grep -Fq 'Could not mount /dev/sda1' <<<"$out" || fail "a failed mount is not reported: $out"
[[ -z $(ls -A "$TMPDIR") ]] || fail "the probe left its mount point behind after a failed mount"
echo "ok - a partition that will not mount is reported"

[[ ! -e $work/unexpected ]] || fail "the probe asked lsblk something the test does not model: $(cat "$work/unexpected")"
