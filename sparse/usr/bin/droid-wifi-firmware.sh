#!/bin/sh
# bcmdhd on this device is built with -DDHD_LINUX_STD_FW_API, so it loads
# firmware through request_firmware() - NOT filp_open(). request_firmware takes
# a name relative to /lib/firmware, so the absolute vendor paths Android's HAL
# would normally write are meaningless here: the kernel was looking for
# /lib/firmware//vendor/etc/wifi/bcmdhd_sta.bin_b1. Every failure surfaced as
# BCME_NOTFOUND (-30) because dhd_os_get_img_fwreq() rewrites request_firmware's
# errno to that single value.
#
# The Makefile sets the expected base names:
#   DHD_FW_NAME    = "bcmdhd_sta.bin"
#   DHD_NVRAM_NAME = "nvram.txt"
# and the driver appends its CID suffix (_b1 for firmware,
# _CS01_semco_b1 for nvram), so the files must land in /lib/firmware under
# those exact suffixed names.
BB=/usr/bin/busybox
BBS=/usr/bin/busybox-static
FW=/lib/firmware
LOG=/var/lib/hybris-fix/wififw.log
: > "$LOG"
log() { echo "$($BB cut -d. -f1 /proc/uptime)s: $*" >> "$LOG"; }

i=0
while [ $i -lt 120 ]; do [ -d /vendor/etc/wifi ] && break; $BB sleep 1; i=$((i+1)); done
[ -d /vendor/etc/wifi ] || { log "no /vendor/etc/wifi"; exit 0; }

# EFS holds the real WLAN MAC; droid-hal mounts it at /mnt/vendor/efs but the
# driver looks in /efs. Bind READ-ONLY - EFS also carries IMEI and calibration.
$BB mkdir -p /efs
[ -e /efs/wifi/.mac.info ] || /usr/bin/mount --bind /mnt/vendor/efs /efs 2>/dev/null
log "mac.info: $($BB cat /efs/wifi/.mac.info 2>&1)"

$BB mkdir -p "$FW"
# Verify the copy, do not merely check that something is there.
#
# "[ -f ] || cp" left a corrupt copy in place for good, and a corrupt copy is
# exactly what this device produces: /data is f2fs, cp does not fsync, and a
# forced reset (vol-down+power, which this port needs while the shutdown hang
# is unfixed) commits the inode size without the data blocks. The result is a
# file of precisely the right length that is mostly NULs - 1058687 of 1261732
# bytes of bcmdhd_sta.bin_b1 were zero when this bit us, and every existence
# test still passed.
#
# The failure is silent and looks nothing like bad firmware. The dongle takes
# the download, the PCIe link trains, the NVRAM even reads back and compares
# OK - and then the dongle CPU never starts, because there is no valid code
# for it to run:
#   dhdpcie_readshared: address (0xf2c30d3c) of pciedev_shared invalid
#   dhd_bus_init :Shared area read failed
#   failed to power up wifi chip, retry again (0 left)
# which reads as a dead chip, not as a bad file.
#
# cmp over ~1.3 MB costs a few tens of ms once per boot; wifi silently not
# existing costs rather more. sync afterwards so our own copy is durable.
COPIED=0
for f in bcmdhd_sta.bin_b1 bcmdhd_mfg.bin_b1 nvram.txt_CS01_semco_b1 bcmdhd_clm.blob; do
    [ -f "/vendor/etc/wifi/$f" ] || continue
    if $BB cmp -s "/vendor/etc/wifi/$f" "$FW/$f" 2>/dev/null; then continue; fi
    log "refreshing $f (missing or does not match vendor)"
    $BB cp "/vendor/etc/wifi/$f" "$FW/$f" 2>/dev/null && COPIED=1
done
[ "$COPIED" = 1 ] && $BB sync
log "in $FW: $($BB ls $FW 2>&1 | $BB tr '\n' ' ')"

# firmware_class searches its "path" parameter first; droid-hal leaves it at
# /vendor/firmware, which has no bcmdhd files. Point it at our directory so the
# CLM blob is found too - the firmware and nvram already fall through to the
# built-in /lib/firmware search, but the CLM request returned -2 and then sat
# in the 60s user-helper fallback, which is what wedges rtnl_lock and hangs
# every subsequent ifconfig on wlan0.
[ -w /sys/module/firmware_class/parameters/path ] \
    && echo /lib/firmware > /sys/module/firmware_class/parameters/path
log "fw_class path = $($BB cat /sys/module/firmware_class/parameters/path 2>&1)"

# ...but repointing that parameter takes EVERY other vendor firmware out of
# reach, because it is a replacement for /vendor/firmware, not an addition to
# it. The kernel tries the parameter first and then falls back to /lib/firmware
# only - never to the old value. That silently broke the camera:
#   exynos-fimc-is: Direct firmware load for fimc_is_lib.bin failed with error -2
#   exynos-fimc-is: Direct firmware load for fimc_is_rta.bin failed with error -2
#   exynos-fimc-is: Direct firmware load for setfile_2l4.bin failed with error -2
# (-2 = ENOENT). With no ISP firmware the sensor never streams, so the camera
# app got no frames at all.
#
# Link every vendor firmware into /lib/firmware so both sets resolve. Existing
# files are never replaced, which keeps the real bcmdhd/nvram files written
# above - those must stay real files, not links into /vendor.
if [ -d /vendor/firmware ]; then
    for f in /vendor/firmware/*; do
        [ -e "$f" ] || continue
        b=$($BB basename "$f")
        [ -e "$FW/$b" ] || $BB ln -sf "$f" "$FW/$b"
    done
    log "linked vendor firmware into $FW"
fi

# Bare names, relative to /lib/firmware.
# printf, not echo: echo appends a newline. dhd strips a trailing '\n' from
# firmware_path and nvram_path, but clm_path is used verbatim
# (clm_blob_path = clm_path), so "bcmdhd_clm.blob\n" made request_firmware
# return -ENOENT and then sit in a 61s user-helper fallback. That timeout is
# what held rtnl_lock, hung every ifconfig on wlan0, and eventually took the
# RNDIS link and the boot down with it.
#
# clm_path is deliberately left unset: the kernel is built with
# -DDHD_CLM_NAME="bcmdhd_clm.blob", so the default is already correct and
# cannot pick up stray whitespace.
printf '%s' bcmdhd_sta.bin > /sys/module/dhd/parameters/firmware_path
printf '%s' nvram.txt      > /sys/module/dhd/parameters/nvram_path
log "params: fw=$($BB cat /sys/module/dhd/parameters/firmware_path) nv=$($BB cat /sys/module/dhd/parameters/nvram_path)"

for r in /sys/class/rfkill/rfkill*; do
    [ -e "$r/type" ] || continue
    [ "$($BB cat $r/type)" = "wlan" ] && echo 0 > "$r/soft" 2>/dev/null
done

$BBS ifconfig wlan0 down 2>/dev/null; $BB sleep 1
$BBS ifconfig wlan0 up 2>&1 | while read l; do log "up: $l"; done
log "wlan0: $($BBS ifconfig wlan0 2>&1 | $BB head -2)"

# No trailing sleep and no journalctl sweep here any more. connman is ordered
# after this unit now, so every second spent past the firmware load is a second
# of networking delayed at boot - the 6 s settle plus the journal scan bought
# nothing but a prettier log. The same lines are still in `journalctl -b -k`
# for anyone debugging, and "up:" above records what ifconfig said.
exit 0
