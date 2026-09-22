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
# Usage: d2s-waydroid-setup.sh [--gapps|--vanilla] [--no-init]
#   --gapps    use the image with Google apps (the d2s default)
#   --vanilla  use the image without Google apps
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

SYS_ZIP="$SYS_GAPPS"
IMAGE_TYPE=GAPPS
NO_INIT=""
for a in "$@"; do
    case "$a" in
        --gapps)   SYS_ZIP="$SYS_GAPPS"; IMAGE_TYPE=GAPPS;;
        --vanilla) SYS_ZIP="$SYS_VANILLA"; IMAGE_TYPE=VANILLA;;
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
# Refresh only Chum here.  A headless root invocation cannot obtain the Jolla
# Store token over the user's session bus; refreshing every configured repo
# then aborts an otherwise healthy install with "Store credentials not
# received" even though all Waydroid packages come from Chum.
zypper --non-interactive --gpg-auto-import-keys refresh chum
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

# Android's stock 15-step media range drives this port's fixed speaker path
# beyond its clean gain range.  Limiting the range at AudioService level makes
# Android's own slider and hardware-key handling agree on 0..11, instead of a
# one-off settings write that leaves the device-specific
# volume_music_speaker key (and the running AudioService) at 15.
BASE_PROP=/var/lib/waydroid/waydroid_base.prop
if [ -f "$BASE_PROP" ]; then
    sed -i '/^ro\.config\.media_vol_steps=/d' "$BASE_PROP"
    printf '%s\n' 'ro.config.media_vol_steps=11' >> "$BASE_PROP"
fi

if [ -n "$NO_INIT" ]; then
    echo "done (skipped images; run 'waydroid init' yourself, but read the note above)"
    exit 0
fi

echo "== images =="
# Placed in /etc/waydroid-extra/images, which `waydroid init` prefers over its
# own download when BOTH system.img and vendor.img are there. That is how the
# Android 11 system image gets used instead of the Android 13 one.
IMAGE_MARKER="$EXTRA/.d2s-image-type"
INSTALLED_TYPE=$(cat "$IMAGE_MARKER" 2>/dev/null || true)
if [ -f /var/lib/waydroid/waydroid.cfg ] &&
        [ -d /var/lib/waydroid/rootfs ] &&
        [ "$INSTALLED_TYPE" = "$IMAGE_TYPE" ]; then
    echo "already initialised, skipping"
else
    mkdir -p "$EXTRA"
    if [ ! -f "$EXTRA/system.img" ] || [ "$INSTALLED_TYPE" != "$IMAGE_TYPE" ]; then
        # Never replace an image underneath a live loop mount.  The package
        # enables the container service, so it may have auto-started even when
        # the user has not opened Waydroid yet.
        systemctl stop waydroid-container.service 2>/dev/null || true
        pkill -f 'python3 /usr/bin/waydroid container start' 2>/dev/null || true
        echo "fetching the Android 11 $IMAGE_TYPE system image (~800 MB) ..."
        # -C - so an interrupted download resumes; SourceForge mirrors drop often.
        curl -L -C - --retry 5 --connect-timeout 20 --speed-limit 20480 --speed-time 60 \
             -o "$EXTRA/$SYS_ZIP" "$SYS_BASE/$SYS_ZIP" || { echo "system image download failed"; exit 1; }
        # No unzip on this device; python3 is present because waydroid needs it.
        python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
                "$EXTRA/$SYS_ZIP" "$EXTRA" || { echo "could not unpack the system image"; exit 1; }
        rm -f "$EXTRA/$SYS_ZIP"
        printf '%s\n' "$IMAGE_TYPE" > "$IMAGE_MARKER"
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
    if [ -f /var/lib/waydroid/waydroid.cfg ]; then
        waydroid init -f
    else
        waydroid init
    fi
fi

# `waydroid init` regenerates waydroid.desktop, so enforce this again after it
# finishes. Otherwise a fresh GApps/vanilla switch brings the non-touch direct
# launcher back and the app grid shows two identical Waydroid icons.
if [ -f "$D" ] && ! grep -q "^NoDisplay=true" "$D"; then
    sed -i '/^Icon=waydroid$/a NoDisplay=true' "$D"
fi

# `waydroid init` can regenerate the base property file.
if [ -f "$BASE_PROP" ]; then
    sed -i '/^ro\.config\.media_vol_steps=/d' "$BASE_PROP"
    printf '%s\n' 'ro.config.media_vol_steps=11' >> "$BASE_PROP"
fi

echo
echo "done. Open the 'Waydroid' app from the launcher - it starts the container"
echo "on first run and takes about a minute."
echo "Android media volume is capped at the tested clean 11-step range."
echo
echo "And do NOT accept the Waydroid Updater's offer to move to 20.0 - that is"
echo "the Android 13 image this script deliberately avoids."
