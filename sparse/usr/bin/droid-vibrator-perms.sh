#!/bin/sh
# Let ngfd reach the vibrator.
#
# ngfd runs as the user (defaultuser) and its droid-vibrator plugin,
# /usr/lib64/ngf/libngfd_droid-vibrator.so, drives the motor by writing a
# duration in milliseconds to
#
#     /sys/class/timed_output/vibrator/enable
#
# Android's ueventd owns that node and sets it to system:system 0664, so every
# write from ngfd fails with EACCES and nothing ever buzzes. Verified on
# device: as root the write reaches the driver ("[VIB] cs40l2x_vibe_enable:
# 400ms"), as defaultuser it is "Permission denied".
#
# Timing matters, and a single chmod at startup is not enough. Observed on
# device: ueventd finished coldboot at 15:54:44 (/dev/.coldboot_done), this
# service ran its chmod at 15:54:45, and by 15:54:53 the node was back to
# system:system 0664. Android keeps re-asserting ownership for a few seconds
# after coldboot - /vendor/etc/init/init.exynos9825.rc chowns every vibrator
# node back to system:system - so wait for coldboot, then keep re-applying the
# mode for a minute, which comfortably covers that window.
#
# A udev rule does not work either - udev sees the device at kernel add time,
# long before ueventd, and gets overwritten the same way.
#
# NOTE: on its own this is not enough to make the vibrator work. The Cirrus
# CS40L25A also needs its DSP firmware, which it requests at kernel probe time
# (~4.5 s uptime) when no filesystem is mounted yet, so the request fails, the
# user-helper fallback times out after 60 s and the driver gives up for good
# ("vibe init state? 0", num_waves=0). That half is fixed by embedding
# cs40l25a.wmfw and cs40l20.bin in the kernel via CONFIG_EXTRA_FIRMWARE; with
# it the driver logs "Loaded 75 waveforms from cs40l20.bin".
#
# Do NOT try to fix the firmware half by unbinding and rebinding the driver
# through /sys/bus/i2c/drivers/cs40l2x/. It reboots the device.

V=/sys/class/timed_output/vibrator

fix() {
    # 0666 rather than a group change: the node belongs to Android's "system"
    # user, which has no relationship to the Sailfish user, and there is no
    # shared group to hand it to. Writing a duration is not privileged.
    [ -e "$V/enable" ] && /bin/chmod 0666 "$V/enable" 2>/dev/null
    # The plugin also writes the intensity control when a strength is
    # requested; it carries the same ownership.
    [ -e "$V/intensity" ] && /bin/chmod 0666 "$V/intensity" 2>/dev/null
}

# Wait (bounded) for ueventd to finish coldboot.
i=0
while [ ! -e /dev/.coldboot_done ] && [ $i -lt 120 ]; do
    /bin/sleep 1
    i=$((i + 1))
done

[ -e "$V/enable" ] || exit 0

# Re-assert for a further minute. Cheap, and covers a late uevent for the
# device (or a /dev/.coldboot_done that never appears on some base).
n=0
while [ $n -lt 60 ]; do
    fix
    /bin/sleep 1
    n=$((n + 1))
done
fix

exit 0
