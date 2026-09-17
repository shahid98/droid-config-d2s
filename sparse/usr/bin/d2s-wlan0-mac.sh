#!/bin/sh
# Give connman a STABLE wifi device ident.
#
# connman names every wifi service after the interface MAC it saw when it
# created the device: wifi_<mac-without-colons>_<ssid-hex>_managed_psk. bcmdhd
# brings wlan0 up with a random 00:90:4c:xx:xx:xx address and only replaces it
# with the real one from EFS (8c:b8:4a:...) when the firmware loads, which is
# after connman has started (~35 s into boot). So every boot produces a new
# ident, and the first connection writes a new saved-service directory under
#   /home/defaultuser/.local/share/system/privileged/connman/
# The old ones stay, each one an extra copy of the same network in Settings -
# nine copies of one SSID had piled up by 2026-09-12. (wlan1's 02:90:4c:... is
# derived from the same random base, which is why its address looks related.)
#
# Fix: before connman starts, set wlan0 to the address EFS already holds, so
# the ident is the same on every boot. This is the address the driver ends up
# using anyway - we are only making it true earlier.
#
# Deliberately conservative: only act while the link is down and only when the
# address actually differs, so this can never disturb an interface that is
# already associated.
BB=/usr/bin/busybox
LOG=/var/lib/hybris-fix/wlan0-mac.log
$BB mkdir -p /var/lib/hybris-fix
: > "$LOG"
log() { echo "$($BB cut -d. -f1 /proc/uptime)s: $*" >> "$LOG"; }

# droid-wifi-firmware.sh bind-mounts /mnt/vendor/efs at /efs; read either.
# Keep these waits short: this unit is ordered Before=connman.service, so
# every second spent here delays networking at boot. EFS is mounted by
# droid-hal-init, well before this runs.
i=0
while [ $i -lt 20 ]; do
    for f in /mnt/vendor/efs/wifi/.mac.info /efs/wifi/.mac.info; do
        [ -s "$f" ] && { MACFILE="$f"; break; }
    done
    [ -n "$MACFILE" ] && break
    $BB sleep 1
    i=$((i + 1))
done
[ -n "$MACFILE" ] || { log "no .mac.info after ${i}s"; exit 0; }

RAW=$($BB cat "$MACFILE" 2>/dev/null | $BB tr -d ' \r\n' | $BB tr 'A-F' 'a-f')
# Accept both "8c:b8:4a:04:fd:03" and "8cb84a04fd03".
case "$RAW" in
    *:*) MAC="$RAW" ;;
    ????????????) MAC=$(echo "$RAW" | $BB sed 's/\(..\)/\1:/g; s/:$//') ;;
    *) log "unrecognised mac.info content"; exit 0 ;;
esac
log "efs mac = $MAC (from $MACFILE)"

i=0
while [ $i -lt 20 ]; do
    [ -e /sys/class/net/wlan0/address ] && break
    $BB sleep 1
    i=$((i + 1))
done
[ -e /sys/class/net/wlan0/address ] || { log "no wlan0 after ${i}s"; exit 0; }

CUR=$($BB cat /sys/class/net/wlan0/address 2>/dev/null | $BB tr 'A-F' 'a-f')
STATE=$($BB cat /sys/class/net/wlan0/operstate 2>/dev/null)
log "wlan0 = $CUR, state $STATE"
if [ "$CUR" = "$MAC" ]; then
    log "already correct, nothing to do"
    exit 0
fi
if [ "$STATE" = "up" ]; then
    log "wlan0 already up - leaving it alone"
    exit 0
fi

# Resolve ip through PATH: it is not in /sbin on this device, and hardcoding
# an absolute path just gets "not found" with rc=127 (same trap as
# /bin/systemctl in d2s-bluebinder-restart.service).
IP_BIN=$(command -v ip 2>/dev/null)
[ -n "$IP_BIN" ] || for c in /usr/sbin/ip /usr/bin/ip /sbin/ip /bin/ip; do
    [ -x "$c" ] && { IP_BIN="$c"; break; }
done
if [ -z "$IP_BIN" ]; then
    log "no ip binary found in PATH ($PATH)"
    exit 0
fi
log "using $IP_BIN"

# bcmdhd tears wlan0 down and recreates it while the firmware loads, so a
# single attempt can hit "RTNETLINK answers: No such device" (rc=2) even though
# /sys/class/net/wlan0 existed a moment earlier. Retry briefly, and judge the
# result by reading the address back rather than by the exit code.
n=0
while [ $n -lt 5 ]; do
    CUR=$($BB cat /sys/class/net/wlan0/address 2>/dev/null | $BB tr 'A-F' 'a-f')
    [ "$CUR" = "$MAC" ] && break
    "$IP_BIN" link set dev wlan0 down 2>>"$LOG"
    "$IP_BIN" link set dev wlan0 address "$MAC" 2>>"$LOG"
    RC=$?
    "$IP_BIN" link set dev wlan0 up 2>>"$LOG"
    log "attempt $n: rc=$RC, now $($BB cat /sys/class/net/wlan0/address 2>/dev/null)"
    $BB sleep 1
    n=$((n + 1))
done
FINAL=$($BB cat /sys/class/net/wlan0/address 2>/dev/null | $BB tr 'A-F' 'a-f')
if [ "$FINAL" = "$MAC" ]; then
    log "ok: wlan0 = $FINAL after $n attempt(s)"
else
    log "WARNING: wlan0 = $FINAL, wanted $MAC - connman ident will churn"
fi
exit 0
