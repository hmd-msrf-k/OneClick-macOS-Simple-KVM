#!/usr/bin/env bash

#!/bin/bash

# Check if PulseAudio is running
if ! pgrep -x pulseaudio >/dev/null 2>&1; then
    pulseaudio --start >/dev/null 2>&1
fi

sleep 0.5

# Apple SMC key
OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"

# VM directory and firmware paths
VMDIR=$(realpath $(dirname $0))
OVMF=$VMDIR/firmware

# Optional headless mode
MOREARGS=()
[[ "$HEADLESS" = "1" ]] && {
    MOREARGS+=(-nographic -vnc :0 -k en-us)
}

# -------------------------------
# Dynamic CPU selection (always 4)
# -------------------------------
CPUS=$(lscpu -e | awk '$NF=="yes"{print $1,$2,$4}')

BEST_CPUS=$(echo "$CPUS" | awk '
{
    cpu=$1; node=$2; core=$3;
    if (!seen[node] && !seen_core[node,core]++) {
        chosen[node]=chosen[node] ? chosen[node]","cpu : cpu;
    }
}
END {
    for (n in chosen) print chosen[n];
}' | head -n 1)

CPU_ARRAY=($(echo "$BEST_CPUS" | tr ',' ' '))
COUNT=${#CPU_ARRAY[@]}

# Ensure we always have 4 CPUs
if [ "$COUNT" -lt 4 ]; then
    NODE=$(echo "$CPUS" | awk 'NR==1{print $2}')
    # Build exclusion regex from already selected CPUs
    EXCLUDE=$(printf "|%s" "${CPU_ARRAY[@]}")
    EXCLUDE=${EXCLUDE:1}
    EXTRA=$(echo "$CPUS" | awk -v node=$NODE '$2==node{print $1}' \
        | grep -Ev "($EXCLUDE)" \
        | head -n $((4-COUNT)))
    CPU_ARRAY+=($EXTRA)
fi

CPU_LIST=$(IFS=,; echo "${CPU_ARRAY[*]}")
echo "Pinning QEMU to CPUs: $CPU_LIST"

# -------------------------------
# QEMU launch arguments
# -------------------------------
args=(
    -enable-kvm
    -m 13G
    -machine q35,accel=kvm
    -smp cores=4,threads=1,sockets=1
    -cpu host,kvm=on,+invtsc
    -device isa-applesmc,osk="$OSK"
    -smbios type=2
    -device intel-hda -device hda-output
    -drive if=pflash,format=raw,readonly=on,file="$OVMF/OVMF_CODE.fd"
    -drive if=pflash,format=raw,file="$OVMF/OVMF_VARS.fd"
    -vga vmware
    -usb -device usb-ehci,id=ehci -device usb-kbd,bus=ehci.0 -device usb-tablet,bus=ehci.0
    -netdev user,id=net0
    -device vmxnet3,netdev=net0,id=net0,mac=52:54:00:c9:18:27
    -monitor telnet:127.0.0.1:5801,server,nowait
    -device ich9-ahci,id=sata
    -drive id=OpenCore,if=none,format=qcow2,file="$VMDIR/OpenCore.qcow2"
    -device ide-hd,bus=sata.2,drive=OpenCore
    -drive id=InstallMedia,format=raw,if=none,file="$VMDIR/BaseSystem.img"
    -device ide-hd,bus=sata.3,drive=InstallMedia
    -drive id=SystemDisk,if=none,file="$VMDIR/macOS.qcow2"
    -device ide-hd,bus=sata.4,drive=SystemDisk
    "${MOREARGS[@]}"
)

# -------------------------------
# Launch QEMU pinned to CPUs
# -------------------------------
taskset -c $CPU_LIST qemu-system-x86_64 "${args[@]}" &

# Wait a few seconds for VM to start
sleep 5

# Auto launch RealVNC Viewer from Windows
"/mnt/c/Program Files/RealVNC/VNC Viewer/vncviewer.exe" localhost:5900 --fullscreen