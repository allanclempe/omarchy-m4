#!/bin/bash
# Touch ID and Secure Enclave probe for the J616c (OMS-2, JOURNEY 9.38).
# Run at the Mac, in Omarchy:
#
#   sudo tools/touchid-probe.sh          read-only checks; loads nothing
#   sudo tools/touchid-probe.sh --load   the checks, then a read-only SEP attach
#
# Without --load it only reads: the device tree, the installed packages,
# omarchy-mac's Touch ID eligibility and status, the calibration and root-key
# files, and the kinds of factory record on the ESP.
#
# --load loads aurora's apple_sep with xart_writes=0 provision_keybag=0
# trusted_keys=0 filevault_api=0: the enclave's shared xART store in the iBoot
# System Container is opened read-only, no identity keybag is created, and no
# kernel key or FileVault API is registered. It never opens /dev/sep-bio, so
# Touch ID isn't activated. It reports the platform profile, the attach, the
# key store, the identity source and the policy the driver chose, from the
# driver's diag attributes, checks the policy it reports against the options
# given, and prints the driver's kernel log.
# The driver takes one attach per boot and can't be unloaded and loaded again,
# so reboot after --load before any further SEP step. A reboot unloads the
# driver; that the enclave also starts clean after it is what the trial is
# expected to show, not something known yet on this Mac.
#
# It prints no device identifier: no ECID, serial, UUID or digest. Long hex
# runs and UUIDs are replaced in place in every kernel log line, option and
# diag value; a line naming an ECID, serial, digest or nonce is withheld and
# counted. Factory records are reduced to their kind (a seal to its chip); an
# unknown record prints as "other".
set -uo pipefail

load=0
case ${1:-} in
  --load) load=1 ;;
  '') ;;
  *) echo "usage: sudo $0 [--load]" >&2; exit 2 ;;
esac
[[ $EUID -eq 0 ]] || { echo "run with sudo: the ESP is root-only" >&2; exit 2; }

tree=/proc/device-tree
esp=/boot/efi
archive=$esp/asahi/all_firmware.tar.gz
helpers=/usr/lib/omarchy-mac
# The driver's diag attributes this prints; local_policy_digest is left out.
diag_attrs=(abi profile boot protocol policy os_identity xart attach endpoints endpoint_names keystore
  keybag sensor touchid sensor_attach restore xart_guard xart_guard_list xart_guard_refusals matching
  hwrng attach_ms ready_ms xarm_failures unhandled_messages)

section() { printf '\n== %s\n' "$*"; }
# Hide what could be an identifier: a UUID or a long hex run is replaced in
# place, and a line that names an ECID, serial, digest or nonce is dropped and
# counted, so a log keeps the lines that explain a failure.
redact() {
  sed -E 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F-]{4,}/<uuid withheld>/g; s/(0x)?[0-9a-fA-F]{16,}/<hex withheld>/g' |
    awk 'tolower($0) ~ /ecid|serial|digest|nonce/ { n++; next } { print }
      END { if (n) printf "(%d line(s) withheld: they named an identifier)\n", n }'
}
nul_list() { [[ -r $1 ]] && tr '\0' ' ' <"$1" | sed 's/ *$//'; }
compatible() { [[ -r $tree/compatible ]] && tr '\0' '\n' <"$tree/compatible" | grep -Fxq "$1"; }

section "System"
echo "kernel:      $(uname -r)"
echo "compatible:  $(nul_list "$tree/compatible")"
echo "cmdline:     $(grep -oE 'apple_sep[^ ]*' /proc/cmdline | tr '\n' ' ' | sed -E 's/(os_uuid_(hi|lo))=[^ ]*/\1=<withheld>/g' | redact)"
[[ -r $tree/chosen/apfs-preboot-uuid ]] && echo "OS identity: /chosen/apfs-preboot-uuid present" ||
  echo "OS identity: /chosen/apfs-preboot-uuid MISSING"
[[ -e /dev/disk/by-partlabel/iBootSystemContainer ]] && echo "iBoot System Container: link present" ||
  echo "iBoot System Container: link MISSING"

section "Device tree"
for node in "$tree"/sep@* "$tree"/soc/sep@*; do
  [[ -d $node ]] && echo "${node#"$tree"}: status $(nul_list "$node/status")"
done
for node in "$tree"/*/fingerprint@* "$tree"/soc/*/fingerprint@*; do
  [[ -d $node ]] || continue
  echo "${node#"$tree"}: $(nul_list "$node/compatible"), status $(nul_list "$node/status")"
  echo "  firmware-name: $(nul_list "$node/firmware-name")"
done

section "Driver and packages"
echo "apple_sep module: $(modinfo -F filename apple_sep 2>/dev/null || echo none)"
echo "apple_sep loaded: $([[ -d /sys/module/apple_sep ]] && echo yes || echo no)"
pacman -Q omarchy omarchy-mac linux-aurora libfprint libfprint-git libfprint-aurora fprintd fprintd-aurora \
  aurora-sep python 2>&1 | sed "s/^error: package '\(.*\)' was not found/\1: not installed/"
echo "fprintd: $(systemctl is-active fprintd.service 2>/dev/null)"
for f in /usr/lib/modprobe.d/*sep* /etc/modprobe.d/*sep* /etc/modprobe.d/*touchid*; do
  [[ -e $f ]] && echo "modprobe.d: $f: $(grep -v '^#' "$f" | tr '\n' ' ' | sed -E 's/(os_uuid_(hi|lo))=[^ ]*/\1=<withheld>/g' | redact)"
done

section "omarchy-mac Touch ID"
if [[ -x $helpers/touchid-eligibility ]]; then
  echo "eligibility: $("$helpers/touchid-eligibility" 2>&1)"
else
  echo "eligibility: $helpers/touchid-eligibility not installed"
fi
echo "status:      $(cat /run/omarchy-mac/touchid 2>/dev/null || echo 'no /run/omarchy-mac/touchid')"
echo "agreement:   $([[ -e /etc/omarchy-mac/touchid-on ]] && echo 'recorded (/etc/omarchy-mac/touchid-on)' || echo none)"
echo "keybag:      $([[ -e /var/lib/aurora-sep-keybag.bin ]] && echo 'present (/var/lib/aurora-sep-keybag.bin)' || echo none)"

section "Calibration and sensor root key"
found=0
for dir in /usr/lib/firmware/apple /usr/lib/firmware/vendor/apple /usr/lib/firmware/updates/apple; do
  for f in "$dir"/mesacal-* "$dir"/msrk-* "$dir"/mesa_calibration.bin; do
    [[ -e $f ]] && { echo "$f ($(stat -c '%s bytes, mode %a' "$f"))"; found=1; }
  done
done
((found)) || echo "none installed"

section "Factory records on the ESP"
if mountpoint -q "$esp" && [[ -r $archive ]]; then
  # Record kinds only; a seal is named by chip, never by ECID, and any other
  # name is "other", so an unexpected one can't print an identifier.
  records=$(tar -tzf "$archive" 2>/dev/null | grep -i 'com\.apple\.factorydata/.' | sed 's|.*/||' | grep -v '^$')
  if [[ -n $records ]]; then
    sed -E 's/^seal-([0-9A-Fa-f]{8})-.*/seal for chip \1/; t; s/^(MSRk|FSC2|FSCl|trustobject)-.*/\1/; t; s/.*/other/' \
      <<<"$records" | sort | uniq -c | sed 's/^ */  /'
  else
    echo "  $archive has no com.apple.factorydata"
  fi
else
  echo "no $archive (is $esp mounted?)"
fi

((load)) || { echo; echo "Read-only checks done; nothing was loaded."; exit 0; }

section "Read-only SEP attach"
compatible apple,j616c || { echo "refused: this is not a J616c"; exit 1; }
[[ ! -d /sys/module/apple_sep ]] || { echo "refused: apple_sep is already loaded this boot; reboot first"; exit 1; }
grep -q 'apple_sep' /proc/cmdline && { echo "refused: the kernel command line sets apple_sep options"; exit 1; }
[[ ! -e /etc/omarchy-mac/touchid-on ]] || { echo "refused: Touch ID is agreed on (omarchy-mac would activate it)"; exit 1; }
systemctl is-active -q fprintd.service && { echo "refused: fprintd is running and would open /dev/sep-bio"; exit 1; }

since=$(date '+%Y-%m-%d %H:%M:%S')
echo "modprobe apple_sep xart_writes=0 provision_keybag=0 trusted_keys=0 filevault_api=0"
modprobe apple_sep xart_writes=0 provision_keybag=0 trusted_keys=0 filevault_api=0 ||
  { echo "modprobe failed"; journalctl -k --since "$since" --no-pager | grep -iE 'sep' | tail -40 | redact; exit 1; }

dev=""
for d in /sys/bus/platform/devices/*.sep; do [[ -d $d/diag ]] && dev=$d && break; done
if [[ -z $dev ]]; then
  # The module loaded but enabled no SEP: no profile, or the probe failed.
  echo "no SEP device with diag attributes after loading"
else
  # The attach decides about 3 s after a warm probe; the key store can take
  # most of a minute (J700: 43 s), and the driver gives it up to 90 s after
  # the attach. Wait for both, up to 100 s.
  for _ in $(seq 1 200); do
    attach=$(cat "$dev/diag/attach" 2>/dev/null) keystore=$(cat "$dev/diag/keystore" 2>/dev/null)
    [[ $attach == failed || ($attach != pending && $keystore != unknown) ]] && break
    sleep 0.5
  done
  echo "device: ${dev##*/}"
  for a in "${diag_attrs[@]}"; do
    [[ -r $dev/diag/$a ]] || continue
    value=$(tr '\n' ' ' <"$dev/diag/$a" | sed 's/ *$//')
    value=$(redact <<<"$value")
    printf '  %-20s %s\n' "$a" "$value"
  done
  [[ $(cat "$dev/diag/xart" 2>/dev/null) == disabled ]] && echo "xART writes: disabled, as asked" ||
    echo "WARNING: diag/xart does not read 'disabled'; do not open /dev/sep-bio, and reboot"
  # Module parameters don't appear in sysfs for this Rust driver; diag/policy
  # is where it reports the policy it chose.
  policy=" $(cat "$dev/diag/policy" 2>/dev/null) "
  if [[ $policy == "  " ]]; then
    echo "policy: not reported by this driver (diag ABI before 3)"
  else
    missing=0
    for want in xart_writes=0 provision_keybag=0 trusted_keys=0 filevault_api=0; do
      [[ $policy == *" $want "* ]] ||
        { echo "WARNING: diag/policy lacks $want; do not open /dev/sep-bio, and reboot"; missing=1; }
    done
    ((missing)) || echo "policy: all four options as asked"
  fi
fi
echo "/dev/sep-bio: $([[ -e /dev/sep-bio ]] && echo present || echo absent) (not opened)"

section "Kernel log since the load"
journalctl -k --since "$since" --no-pager -o short-monotonic |
  grep -iE 'apple_sep|apple-sep|sep[:@ ]|secure enclave|xart|touch ?id|mesa|keystore|keybag' |
  tail -80 | redact

echo
echo "Done. Reboot before any further SEP step: the driver takes one attach per boot."
