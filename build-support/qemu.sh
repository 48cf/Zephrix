#!/bin/bash

qemu-system-x86_64 \
    -M q35 \
    -m 8G \
    -smp 8 \
    -enable-kvm \
    -cpu host \
    -serial stdio \
    -drive file=jinix.img,format=raw \
    -device qemu-xhci,id=xhci \
    -device usb-kbd,bus=xhci.0,port=1 \
    -device usb-tablet,bus=xhci.0,port=2 \
    $QEMUFLAGS
