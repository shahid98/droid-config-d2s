#!/bin/sh
# Restart bluebinder when the adapter refuses to power on.
#
# bluebinder proxies BlueZ's HCI traffic to Samsung's Android Bluetooth HAL.
# Its instance can wedge while the phone is running - typically after a headset
# session - and from then on every power-on fails with
#
#     bluetoothd: Failed to set mode: Failed (0x03)
#
# while rfkill is clear and hci0 still exists, so Bluetooth simply stops working
# with nothing in the UI to explain it. This is the same fault
# d2s-bluebinder-restart.service handles once at boot: a *fresh* bluebinder
# instance always fixes it, whatever wedged the old one.
#
# So watch the journal for that line and restart bluebinder, rate limited so a
# genuinely broken adapter cannot turn this into a restart loop. 0x03 is
# HCI "hardware failure" as reported by mgmt; rfkill blocks report 0x12 instead
# and are not this fault, so they are deliberately not matched.
#
# --test replays the current boot's journal instead of following it, and only
# reports what it would have done.

COOLDOWN=60          # seconds between restarts
last=0

act() {
    now=$(cut -d. -f1 /proc/uptime)
    if [ $((now - last)) -lt $COOLDOWN ]; then
        echo "adapter power-on failed again after ${COOLDOWN}s guard - not restarting"
        return
    fi
    last=$now
    if [ "$TEST" = 1 ]; then
        echo "would restart bluebinder (uptime ${now}s)"
        return
    fi
    echo "adapter power-on failed - restarting bluebinder"
    systemctl restart bluebinder.service
    sleep 4
    # A fresh instance registers a new hci device, and that one comes up
    # soft-blocked - see d2s-bluebinder-restart.service.
    rfkill unblock bluetooth
}

if [ "$1" = "--test" ]; then
    TEST=1
    journalctl -b --no-pager -o cat 2>/dev/null | grep -a "Failed to set mode: Failed (0x03)" | while read -r l; do act; done
    exit 0
fi

journalctl -f -n 0 -o cat 2>/dev/null | while read -r line; do
    case "$line" in
        *"Failed to set mode: Failed (0x03)"*) act;;
    esac
done
