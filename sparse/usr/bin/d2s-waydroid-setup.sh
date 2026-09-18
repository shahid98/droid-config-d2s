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
# Usage: d2s-waydroid-setup.sh [--gapps] [--no-init]
#   --gapps    use the image with Google apps (bigger; needed for FCM push)
#   --no-init  skip the image download entirely

set -e

CHUM_REPO="https://repo.sailfishos.org/obs/sailfishos:/chum/5.1_aarch64/"

# The system image MUST be Android 11 (LineageOS 18.1), not the Android 13
# (LineageOS 20) one `waydroid init` downloads by itself. Waydroid pairs its
# download with the HALIUM_11 vendor shim, i.e. an Android 13 system on an
# Android 11 vendor, and on that combination shared storage never mounts
# (MediaProvider crash-loops forever, so Gallery and Documents hang) and the
# camera count is 0. With the matching 18.1 image /storage/emulated/0 is
# populated and the camera enumerates. Upstream only serves lineage-20 now, so
# this comes from the archive. See docs/WAYDROID-d2s.md.
SYS_BASE="https://downloads.sourceforge.net/project/waydroid/images/system/lineage/waydroid_arm64"
SYS_VANILLA="lineage-18.1-20250628-VANILLA-waydroid_arm64-system.zip"
SYS_GAPPS="lineage-18.1-20250628-GAPPS-waydroid_arm64-system.zip"
VENDOR_OTA="https://ota.waydro.id/vendor/waydroid_arm64/HALIUM_11.json"
EXTRA=/etc/waydroid-extra/images
PKGS="lxc waydroid waydroid-settings waydroid-sensors waydroid-gbinder-config-hybris waydroid-runner python3-gbinder dnsmasq"

SYS_ZIP="$SYS_VANILLA"
NO_INIT=""
for a in "$@"; do
    case "$a" in
        --gapps)   SYS_ZIP="$SYS_GAPPS";;
        --no-init) NO_INIT=1;;
        *) echo "unknown option: $a"; exit 1;;
    esac
done

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

if [ -n "$NO_INIT" ]; then
    echo "done (skipped images; run 'waydroid init' yourself, but read the note above)"
    exit 0
fi

echo "== images =="
# Placed in /etc/waydroid-extra/images, which `waydroid init` prefers over its
# own download when BOTH system.img and vendor.img are there. That is how the
# Android 11 system image gets used instead of the Android 13 one.
if [ -f /var/lib/waydroid/waydroid.cfg ] && [ -d /var/lib/waydroid/rootfs ]; then
    echo "already initialised, skipping"
else
    mkdir -p "$EXTRA"
    if [ ! -f "$EXTRA/system.img" ]; then
        echo "fetching the Android 11 system image (~800 MB) ..."
        # -C - so an interrupted download resumes; SourceForge mirrors drop often.
        curl -L -C - --retry 5 --connect-timeout 20 --speed-limit 20480 --speed-time 60 \
             -o "$EXTRA/$SYS_ZIP" "$SYS_BASE/$SYS_ZIP" || { echo "system image download failed"; exit 1; }
        # No unzip on this device; python3 is present because waydroid needs it.
        python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
                "$EXTRA/$SYS_ZIP" "$EXTRA" || { echo "could not unpack the system image"; exit 1; }
        rm -f "$EXTRA/$SYS_ZIP"
    fi
    if [ ! -f "$EXTRA/vendor.img" ]; then
        echo "fetching the HALIUM_11 vendor image ..."
        VZ=$(curl -s --max-time 60 "$VENDOR_OTA" | python3 -c "import json,sys; print(json.load(sys.stdin)['response'][0]['url'])")
        [ -z "$VZ" ] && { echo "could not read the vendor OTA channel"; exit 1; }
        curl -L -C - --retry 5 --connect-timeout 20 -o "$EXTRA/vendor.zip" "$VZ" || { echo "vendor image download failed"; exit 1; }
        python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
                "$EXTRA/vendor.zip" "$EXTRA" || { echo "could not unpack the vendor image"; exit 1; }
        rm -f "$EXTRA/vendor.zip"
    fi
    ls -l "$EXTRA"
    # vendor_type is detected from ro.vndk.version (30 -> HALIUM_11), and the
    # binder nodes are picked up from /dev automatically: waydroid prefers
    # anbox-binder over the host's own /dev/binder, so the container gets its
    # own binder domain and the phone's own HALs are untouched.
    waydroid init
fi

echo
echo "done. Open the 'Waydroid' app from the launcher - it starts the container"
echo "on first run and takes about a minute."
echo
echo "Then, once Android is up, set its media volume (the speaker amps clip"
echo "above this and everything crackles):"
echo "    lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- \\"
echo "        /system/bin/sh -c 'settings put system volume_music 11'"
echo
echo "And do NOT accept the Waydroid Updater's offer to move to 20.0 - that is"
echo "the Android 13 image this script deliberately avoids."
