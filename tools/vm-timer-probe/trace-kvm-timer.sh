#!/usr/bin/env bash
# Trace KVM's guest timer handling while a 2-vCPU test guest hangs.
#
# Usage (as root, at the Mac):  sudo tools/vm-timer-probe/trace-kvm-timer.sh <kernel Image> [out dir]
#
# Boots <kernel Image> under KVM with 2 vCPUs and no disk, as the invoking user (SUDO_USER),
# waits for the guest to get stuck, then records 3 s of KVM exit, timer and vGIC events and the
# host IRQ handler for the guest timers and the vGIC maintenance interrupt. Stops QEMU, turns
# tracing off and writes trace.txt, guest.log and a summary to the out dir (default /tmp/vm-timer-trace).
#
# Changes nothing persistent: tracefs settings are put back and QEMU is killed at the end.
set -euo pipefail

image=${1:?usage: trace-kvm-timer.sh <kernel Image> [out dir]}
out=${2:-/tmp/vm-timer-trace}
user=${SUDO_USER:?run with sudo, so the guest runs as your user}
T=/sys/kernel/tracing
[ -d "$T/events/kvm" ] || T=/sys/kernel/debug/tracing

mkdir -p "$out"
chown "$user" "$out"

events=(kvm/kvm_exit kvm/kvm_entry kvm/kvm_timer_update_irq kvm/kvm_timer_save_state
        kvm/kvm_timer_restore_state kvm/kvm_timer_hrtimer_expire kvm/kvm_wfx_arm
        kvm/vgic_update_irq_pending kvm/kvm_get_timer_map irq/irq_handler_entry)

cleanup() {
	set +e
	echo 0 > "$T/tracing_on"
	for e in "${events[@]}"; do echo 0 > "$T/events/$e/enable" 2>/dev/null || true; done
	echo 0 > "$T/events/irq/irq_handler_entry/filter" 2>/dev/null || true
	echo 1408 > "$T/buffer_size_kb"
	[ -n "${qpid:-}" ] && kill "$qpid" 2>/dev/null || true
}
trap cleanup EXIT

irqs() { awk '/kvm guest vtimer|kvm guest ptimer| vgic$/{s=0; for(i=2;i<=NF && $i ~ /^[0-9]+$/;i++) s+=$i; print $NF"="s}' /proc/interrupts | tr '\n' ' '; }

echo 0 > "$T/tracing_on"
echo > "$T/trace"
echo 16384 > "$T/buffer_size_kb"
for e in "${events[@]}"; do
	if [ -e "$T/events/$e/enable" ]; then echo 1 > "$T/events/$e/enable"; else echo "skipping $e: not in this kernel"; fi
done
vt=$(awk '/kvm guest vtimer/{sub(":","",$1); print $1}' /proc/interrupts)
pt=$(awk '/kvm guest ptimer/{sub(":","",$1); print $1}' /proc/interrupts)
vg=$(awk '/ vgic$/{sub(":","",$1); print $1}' /proc/interrupts)
echo "irq==$vt || irq==$pt || irq==$vg" > "$T/events/irq/irq_handler_entry/filter"

echo "before: $(irqs)" | tee "$out/summary.txt"
sudo -u "$user" qemu-system-aarch64 -machine virt,accel=kvm -cpu host -smp 2 -m 1024 \
	-nographic -no-reboot -kernel "$image" \
	-append "earlycon=pl011,0x9000000 console=ttyAMA0 panic=-1 rcupdate.rcu_cpu_stall_timeout=3" \
	> "$out/guest.log" 2>&1 &
qpid=$!
sleep 6
echo "at 6 s: $(irqs)" | tee -a "$out/summary.txt"
echo 1 > "$T/tracing_on"
sleep 3
echo 0 > "$T/tracing_on"
echo "at 9 s: $(irqs)" | tee -a "$out/summary.txt"
kill "$qpid" 2>/dev/null || true
wait "$qpid" 2>/dev/null || true
qpid=
cp "$T/trace" "$out/trace.txt"
{
	echo "events in 3 s:"
	grep -oE ' (kvm_[a-z_]+|vgic_[a-z_]+|irq_handler_entry):' "$out/trace.txt" | sort | uniq -c | sort -rn
	echo "kvm_exit by reason:"
	grep -oE 'kvm_exit: [A-Z_]+: HSR_EC: 0x[0-9a-f]+ \([A-Z0-9_]+\)|kvm_exit: [A-Z_]+' "$out/trace.txt" | sort | uniq -c | sort -rn | head
	echo "guest log tail:"
	tail -3 "$out/guest.log"
} | tee -a "$out/summary.txt"
chown "$user" "$out"/*
echo "wrote $out/{summary.txt,trace.txt,guest.log}"
