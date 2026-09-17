#!/bin/sh
# Mounts selinuxfs and loads the Android SELinux policy - deliberately LATE.
#
# Android's servicemanager needs selinuxfs (it aborts in Access::Access()) and a
# loaded policy (else "Unknown class service_manager" denies every addService).
# But Sailfish's systemd is built +SELINUX on a rootfs with no SELinux xattrs,
# so systemd-tmpfiles and systemd-logind SIGSEGV if selinuxfs exists when they
# start. Verified: same binary, same config - no selinuxfs rc=0, selinuxfs rc=139.
# Root cause, found later: with selinuxfs present every systemd daemon calls
# selabel_open(), which fails with no file-context database, and libselinux
# then crashes in its own cleanup. droid-config now ships an empty database
# (/etc/selinux/targeted/contexts/files/file_contexts), which fixes that for
# daemons started at any time (systemd-resolved, hostnamed, ...). The late
# mount below is kept because it is proven and costs nothing.
#
# We must therefore run after logind has started. We CANNOT express that as
# After=systemd-logind.service: logind sorts after basic.target, and
# droid-hal-init sorts before it, so systemd finds an ordering cycle and
# resolves it by deleting the droid-hal-init job outright:
#   basic.target: Found ordering cycle on droid-hal-init.service/start
#   Job droid-hal-init.service/start deleted to break ordering cycle
# That is why the HAL silently never started. So: poll for logind instead of
# declaring a dependency on it.
B=/usr/bin/busybox
i=0
while [ $i -lt 40 ]; do
    state=$(/usr/bin/systemctl is-active systemd-logind 2>/dev/null)
    [ "$state" = "active" ] && break
    [ "$state" = "failed" ] && break
    $B sleep 1
    i=$((i+1))
done

$B grep -q " /sys/fs/selinux " /proc/mounts || mount -t selinuxfs selinuxfs /sys/fs/selinux

# Single write(): the kernel's sel_write_load wants the whole policy in one
# call, and Samsung's kernel panics outright on a failed load.
SEPOL=/vendor/etc/selinux/precompiled_sepolicy
if [ -w /sys/fs/selinux/load ] && [ -f "$SEPOL" ] && [ ! -d /sys/fs/selinux/class/service_manager ]; then
    SZ=$($B wc -c < "$SEPOL")
    $B dd if="$SEPOL" of=/sys/fs/selinux/load bs="$SZ" count=1 2>/dev/null
fi
# Must stay permissive - Sailfish's own processes are unlabelled.
echo 0 > /sys/fs/selinux/enforce 2>/dev/null
exit 0
