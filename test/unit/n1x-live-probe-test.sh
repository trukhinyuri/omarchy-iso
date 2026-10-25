#!/bin/bash
#
# The N1x recovery entry's probe copies its evidence into probe/ on a
# partition named OMARCHY-PROBE in its GPT, or labelled OMARCHY-PROBE or
# N1XPROBE, and only onto one on a removable or USB disk: it must never write
# to the laptop's own disks. The evidence leaves out the Windows product key
# and the SMBIOS serial numbers.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
probe="$ROOT/configs/airootfs/usr/local/sbin/omarchy-n1x-live-probe"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$probe"
grep -Fqx 'log=/var/log/omarchy-n1x-live-probe.log' "$probe" || fail "the probe no longer logs to /var/log"
grep -Fqx 'probe_partlabel=OMARCHY-PROBE' "$probe" || fail "the probe does not look for the GPT name OMARCHY-PROBE"
grep -Fqx 'probe_labels=(OMARCHY-PROBE N1XPROBE)' "$probe" || fail "the probe does not look for an 11-character exFAT label"
grep -Fq '! -name '\''MSDM*'\' "$probe" || fail "the probe would copy the Windows product key"
grep -Fq 'EXPOSED_DISP_FRM-4b086294-0740-4f71-a7b5-85a329c7ec5f' "$probe" || fail "the probe does not record the GPU carve-out"
grep -Fq 'NVDA8400' "$probe" || fail "the probe does not show whether SSPM is hidden"

# The SMBIOS dump keeps what names the hardware and drops what names the one
# machine.
grep -Fq 'run dmidecode -t 0,1,2,3,4,17 | redact_dmi >' "$probe" || fail "the probe's SMBIOS dump is not redacted"
eval "$(sed -n '/^redact_dmi() {$/,/^}$/p' "$probe")"
redacted=$(printf '%s\n' 'System Information' $'\tProduct Name: ProArt P16 H7607BA' $'\tSerial Number: SYSTEM-SERIAL' \
  $'\tUUID: 01234567-89ab-cdef-0123-456789abcdef' 'Base Board Information' $'\tSerial Number: BOARD-SERIAL' \
  $'\tAsset Tag: BOARD-TAG' 'Memory Device' $'\tSerial Number: DIMM-SERIAL' $'\tPart Number: MT62F4G32D8DV-023' | redact_dmi)
grep -Eq 'SERIAL|01234567|BOARD-TAG' <<<"$redacted" && fail "the SMBIOS dump keeps a serial number, asset tag or UUID: $redacted"
[[ $(grep -c ': (removed)$' <<<"$redacted") == 5 ]] || fail "the SMBIOS dump does not mark what it left out: $redacted"
grep -Fqx $'\tProduct Name: ProArt P16 H7607BA' <<<"$redacted" && grep -Fqx $'\tPart Number: MT62F4G32D8DV-023' <<<"$redacted" \
  || fail "the SMBIOS dump lost the hardware's identity: $redacted"
echo "ok - the SMBIOS dump leaves out serial numbers, asset tags and the UUID"

eval "$(sed -n '/^is_probe_partition() {/,/^}$/p;/^copy_to_probe_partition() {$/,/^}$/p' "$probe")"
declare -F copy_to_probe_partition >/dev/null || fail "the probe has no copy_to_probe_partition"
declare -F is_probe_partition >/dev/null || fail "the probe has no is_probe_partition"

probe_partlabel=OMARCHY-PROBE
probe_labels=(OMARCHY-PROBE N1XPROBE)
bundle=$work/var/log/omarchy-n1x-live-probe-20261025-101500
mkdir -p "$bundle/acpi-tables/dynamic"
echo log >"$bundle/omarchy-n1x-live-probe.log"
echo table >"$bundle/acpi-tables/dynamic/SSDT1"
export TMPDIR=$work/tmp
mkdir -p "$TMPDIR"

# Disks as lsblk reports them: the laptop's NVMe drive, the card in its own
# SD slot (the kernel never marks an MMC disk removable, so it cannot be
# told from soldered eMMC), USB sticks (RM 0, as many report themselves), a
# removable disk whose transport lsblk does not name, and a stick formatted
# without a partition table. The names say nothing of the copy's own locals.
declare -A parent=([/dev/nvme0n1p3]=/dev/nvme0n1 [/dev/nvme0n1p4]=/dev/nvme0n1 [/dev/mmcblk0p1]=/dev/mmcblk0
  [/dev/sda1]=/dev/sda [/dev/sda2]=/dev/sda [/dev/sda3]=/dev/sda [/dev/sdc1]=/dev/sdc)
declare -A rmtran=([/dev/nvme0n1]='0 nvme' [/dev/mmcblk0]='0 mmc' [/dev/sda]='0 usb' [/dev/sdc]='1 ' [/dev/sdb]='1 usb')
declare -A fs_label=() gpt_name=()
names=()
lsblk() {
  case "$*" in
    '-nrpo NAME') printf '%s\n' "${names[@]}" ;;
    '-dno PARTLABEL '*) printf '%s\n' "${gpt_name[${*: -1}]:-}" ;;
    '-dno LABEL '*) printf '%s\n' "${fs_label[${*: -1}]:-}" ;;
    '-dnpo PKNAME '*) printf '%s\n' "${parent[${*: -1}]:-}" ;;
    '-dnro RM,TRAN '*) printf '%s\n' "${rmtran[${*: -1}]:-}" ;;
    *) echo "lsblk $*" >>"$work/unexpected" ;;
  esac
}
blockdev_is() { # name, file system label, GPT partition name
  names+=("$1"); fs_label[$1]=${2:-}; gpt_name[$1]=${3:-}
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
fresh_disks() {
  rm -rf "$work/calls" "$work/disk" "$work/unexpected" "$TMPDIR"/*
  mount_fails= names=() fs_label=() gpt_name=()
}
copied_bundle_is_intact() {
  cmp -s "$work/disk/probe/omarchy-n1x-live-probe-20261025-101500/omarchy-n1x-live-probe.log" "$bundle/omarchy-n1x-live-probe.log" \
    && cmp -s "$work/disk/probe/omarchy-n1x-live-probe-20261025-101500/acpi-tables/dynamic/SSDT1" "$bundle/acpi-tables/dynamic/SSDT1"
}

# Only the laptop's own disks carry the names, or a near miss of them.
fresh_disks
blockdev_is /dev/nvme0n1; blockdev_is /dev/nvme0n1p3 OMARCHY-PROBE; blockdev_is /dev/nvme0n1p4 '' OMARCHY-PROBE
blockdev_is /dev/mmcblk0; blockdev_is /dev/mmcblk0p1 N1XPROBE; blockdev_is /dev/sda; blockdev_is /dev/sda1 OMARCHY-PROBES
out=$(copy_to_probe_partition) && fail "the probe reported a copy with no removable disk: $out"
[[ ! -e $work/calls ]] || fail "the probe mounted a partition it must not write to: $(cat "$work/calls")"
grep -Fq '/dev/nvme0n1p3 (no name, OMARCHY-PROBE) is on /dev/nvme0n1, which is neither removable nor on USB' <<<"$out" \
  && grep -Fq '/dev/nvme0n1p4 (OMARCHY-PROBE, no label) is on /dev/nvme0n1, which is neither removable nor on USB' <<<"$out" \
  && grep -Fq '/dev/mmcblk0p1 (no name, N1XPROBE) is on /dev/mmcblk0, which is neither removable nor on USB' <<<"$out" \
  || fail "the probe does not say why it left the internal partitions alone: $out"
grep -Fq 'the evidence stays in' <<<"$out" || fail "the probe does not say where the evidence stayed: $out"
echo "ok - a probe partition on the laptop's own disk is never mounted"

# The installer stick tools/linux/make-usb-layout.sh writes: the ISO, its
# ESP, and an exFAT partition named OMARCHY-PROBE and labelled N1XPROBE.
fresh_disks
blockdev_is /dev/nvme0n1; blockdev_is /dev/nvme0n1p3 OMARCHY-PROBE
blockdev_is /dev/sda; blockdev_is /dev/sda1 OMARCHY_202610 ISO9660; blockdev_is /dev/sda2 ARCHISO_EFI Appended2
blockdev_is /dev/sda3 N1XPROBE OMARCHY-PROBE
out=$(copy_to_probe_partition) || fail "the probe did not copy to the installer stick: $out"
[[ $(grep -c '^mount ' "$work/calls") == 1 ]] && grep -q '^mount -o rw,noatime /dev/sda3 ' "$work/calls" \
  || fail "the probe mounted something other than the stick's probe partition: $(cat "$work/calls")"
grep -q '^umount ' "$work/calls" || fail "the probe left the USB stick mounted"
copied_bundle_is_intact || fail "the bundle did not reach probe/ on the stick in a directory of its own"
[[ -z $(ls -A "$TMPDIR") ]] || fail "the probe left its mount point behind"
grep -Fq 'Copied to /dev/sda3 on /dev/sda: probe/omarchy-n1x-live-probe-20261025-101500' <<<"$out" \
  || fail "the probe does not say where the bundle went: $out"
echo "ok - the installer stick's OMARCHY-PROBE partition gets the bundle under probe/"

# A second stick formatted on Windows: exFAT labelled N1XPROBE, or NTFS
# labelled OMARCHY-PROBE, any case.
for label in N1XPROBE omarchy-probe; do
  fresh_disks
  blockdev_is /dev/sda; blockdev_is /dev/sda1 "$label"
  out=$(copy_to_probe_partition) || fail "the probe did not copy to a stick labelled $label: $out"
  grep -q '^mount -o rw,noatime /dev/sda1 ' "$work/calls" && copied_bundle_is_intact \
    || fail "the bundle did not reach a stick labelled $label: $(cat "$work/calls")"
done
echo "ok - a stick labelled N1XPROBE or OMARCHY-PROBE gets the bundle"

# A removable disk counts whatever its transport, and so does a disk without
# a partition table.
fresh_disks
blockdev_is /dev/sdc; blockdev_is /dev/sdc1 N1XPROBE
out=$(copy_to_probe_partition) || fail "the probe did not copy to a removable disk: $out"
grep -q '^mount -o rw,noatime /dev/sdc1 ' "$work/calls" || fail "the probe did not mount the removable disk: $(cat "$work/calls")"
fresh_disks
blockdev_is /dev/sdb OMARCHY-PROBE
out=$(copy_to_probe_partition) || fail "the probe did not copy to a stick without partitions: $out"
grep -q '^mount -o rw,noatime /dev/sdb ' "$work/calls" || fail "the probe did not mount the whole stick: $(cat "$work/calls")"
echo "ok - removable disks and unpartitioned sticks qualify"

# A partition that will not mount is reported, and nothing is left behind.
fresh_disks
mount_fails=1
blockdev_is /dev/sda; blockdev_is /dev/sda3 N1XPROBE OMARCHY-PROBE
out=$(copy_to_probe_partition) && fail "the probe reported a copy to a partition it could not mount: $out"
grep -Fq 'Could not mount /dev/sda3' <<<"$out" || fail "a failed mount is not reported: $out"
[[ -z $(ls -A "$TMPDIR") ]] || fail "the probe left its mount point behind after a failed mount"
echo "ok - a partition that will not mount is reported"

[[ ! -e $work/unexpected ]] || fail "the probe asked lsblk something the test does not model: $(cat "$work/unexpected")"
