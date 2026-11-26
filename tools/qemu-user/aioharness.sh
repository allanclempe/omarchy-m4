#!/bin/bash
# aioharness.sh QEMU [WRAPPER...]: run aiotest under QEMU and hand it an
# address in QEMU's own writable data, which is not guest memory.
q=$1; shift
fifo=$(mktemp -u); mkfifo "$fifo"
"$@" "$q" ./aiotest - < "$fifo" &
pid=$!
exec 3>"$fifo"
sleep 1
# With a wrapper (userpages exec's), the pid is the qemu process itself.
addr=$(awk -v b="$(basename "$q")" '$2 ~ /^rw/ && $6 ~ b {split($1, a, "-"); print a[1]; exit}' "/proc/$pid/maps")
echo "${addr:-0}" >&3
exec 3>&-
wait $pid; echo "exit=$?"; rm -f "$fifo"
