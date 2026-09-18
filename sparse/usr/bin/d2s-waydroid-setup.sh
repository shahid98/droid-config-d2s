#!/bin/sh
# Set up Waydroid on a freshly flashed d2s.
#
# Waydroid is not part of the image: the system image alone is ~2 GB and comes
# from Waydroid's own OTA server, so it is installed on demand. Everything this
# script does is reproducible and idempotent - run it again after an OS upgrade
# and it will only fix what drifted.
#
# The kernel side is already in the image (see docs/WAYDROID-d2s.md):
# anbox-binder/anbox-vndbinder/anbox-hwbinder, ashmem, and the netfilter
# CHECKSUM target Waydroid's network script needs.
#
# Usage: d2s-waydroid-setup.sh [--no-init]   (--no-init skips the image download)

set -e

CHUM_REPO="https://repo.sailfishos.org/obs/sailfishos:/chum/5.1_aarch64/"
PKGS="lxc waydroid waydroid-settings waydroid-sensors waydroid-gbinder-config-hybris waydroid-runner python3-gbinder dnsmasq"

[ "$(id -u)" = "0" ] || { echo "run as root"; exit 1; }

echo "== checking the kernel side =="
for n in anbox-binder anbox-vndbinder anbox-hwbinder; do
    [ -c "/dev/$n" ] || { echo "MISSING /dev/$n - wrong kernel, stopping"; exit 1; }
done
[ -c /dev/ashmem ] || { echo "MISSING /dev/ashmem - wrong kernel, stopping"; exit 1; }
# Waydroid's waydroid-net.sh ends with a CHECKSUM rule for DHCP, and a failure
# there aborts the whole network setup, so the container never starts.
iptables -t mangle -C POSTROUTING -o lo -p udp --dport 68 -j CHECKSUM --checksum-fill 2>/dev/null \
    || iptables -t mangle -A POSTROUTING -o lo -p udp --dport 68 -j CHECKSUM --checksum-fill \
    || { echo "kernel has no CHECKSUM target (CONFIG_NETFILTER_XT_TARGET_CHECKSUM) - stopping"; exit 1; }
iptables -t mangle -D POSTROUTING -o lo -p udp --dport 68 -j CHECKSUM --checksum-fill 2>/dev/null || true
echo "ok"

echo "== repository =="
if ! ssu lr 2>/dev/null | grep -q "chum"; then
    ssu ar chum "$CHUM_REPO"
    ssu ur
fi

echo "== packages =="
zypper --non-interactive --gpg-auto-import-keys refresh
zypper --non-interactive install $PKGS

echo "== dnsmasq =="
# The dnsmasq package ships a system-wide resolver that binds 0.0.0.0:53.
# Waydroid runs its own dnsmasq bound to the container bridge (192.168.240.1),
# which then cannot bind: "failed to create listening socket ... Address
# already in use", and the container never starts. Nothing on this device wants
# the system-wide one.
systemctl disable --now dnsmasq 2>/dev/null || true

echo "== units that would fail on every boot =="
# The lxc package ships a template unit for a container this device does not
# have, so it sits in `systemctl --failed` forever.
systemctl mask lxc@multi-user.service >/dev/null 2>&1 || true
# Waydroid's modules-load.d asks for veth and xt_CHECKSUM. Both are built into
# this port's kernel, not modules, so modprobe fails and takes
# systemd-modules-load.service down with it.
M=/etc/modules-load.d/waydroid.conf
if [ -f "$M" ]; then
    sed -i 's/^veth$/# veth - built in on d2s/; s/^xt_CHECKSUM$/# xt_CHECKSUM - built in on d2s/' "$M"
fi

echo "== launcher icons =="
# Two icons both called "Waydroid" get installed. waydroid.desktop runs
# `waydroid show-full-ui`, which connects straight to lipstick: Android renders,
# but lipstick routes no touch to that surface, so it looks frozen. The one to
# keep is waydroid-runner, a Silica app with its own nested compositor, which
# receives touch as a normal app and forwards it to Android.
D=/usr/share/applications/waydroid.desktop
if [ -f "$D" ] && ! grep -q "^NoDisplay=true" "$D"; then
    sed -i '/^Icon=waydroid$/a NoDisplay=true' "$D"
fi

if [ "$1" = "--no-init" ]; then
    echo "done (skipped image download; run 'waydroid init' yourself)"
    exit 0
fi

echo "== images =="
# Downloads ~1 GB and needs WiFi. vendor_type is detected from
# ro.vndk.version (30 -> HALIUM_11) and the binder nodes are picked up from
# /dev automatically - waydroid prefers anbox-binder over the host's own
# /dev/binder, so the container gets its own binder domain and the phone's
# own HALs are untouched.
if [ -d /var/lib/waydroid/rootfs ] && [ -f /var/lib/waydroid/waydroid.cfg ]; then
    echo "already initialised, skipping"
else
    waydroid init
fi

echo
echo "done. Open the 'Waydroid' app from the launcher - it starts the container"
echo "on first run and takes about a minute."
