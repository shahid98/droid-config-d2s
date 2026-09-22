#!/usr/bin/env python3
"""Turn the panel's double-tap KEY_WAKEUP into a wake gesture mce understands.

WHY THIS EXISTS

Samsung's touch driver supports double-tap-to-wake ("AOT", Always On Touch):
`echo aot_enable,1 > /sys/class/sec/tsp/cmd` puts the panel in low-power
scanning, and a double tap while blanked then emits EV_KEY KEY_WAKEUP (143) on
sec_touchscreen. Verified: every double tap produced a KEY_WAKEUP pair, and mce
received them.

But mce does nothing useful with that key - in its keypress handler
KEY_WAKEUP only takes a short wakelock:

    else if( ev->code == KEY_WAKEUP ) {
        mce_log(LL_DEVEL, "[wakeup] block suspend a while");
        mce_wakelock_obtain(WAKEUP_EVENT_WAKELOCK_NAME, ...);
    }

The unblank comes from a gesture event instead - EV_MSC/MSC_GESTURE with
GESTURE_DOUBLETAP - which mce synthesises from KEY_POWER arriving on a device
it has classified as EVDEV_DBLTAP:

    if( ev->type == EV_KEY && ev->code == KEY_POWER && ev->value == 0 ) {
        ev->type = EV_MSC; ev->code = MSC_GESTURE; ev->value = GESTURE_DOUBLETAP;
    }

So this reads KEY_WAKEUP from the real touchscreen and re-emits KEY_POWER on a
uinput device that mce classifies as EVDEV_DBLTAP. Classification is by
capabilities - evin_evdevtype_from_info() wants a key-only device carrying the
dbltap set (KEY_POWER, KEY_MENU, KEY_BACK, KEY_HOMEPAGE) - and is pinned by
name in /etc/mce/25-d2s-doubletap.ini so it can never be mistaken for a real
power key.

mce's own "Double-tap wakeup policy" still applies on top (it is set to
"proximity", i.e. only when the proximity sensor reports uncovered - which
needs d2s-proximity-uinput.service to be working).
"""
import fcntl
import os
import struct
import subprocess
import sys
import time

TOUCH_NAME = "sec_touchscreen"
DEVICE_NAME = b"d2s-doubletap"
TSP_CMD = "/sys/class/sec/tsp/cmd"

EV_SYN, EV_KEY = 0x00, 0x01
SYN_REPORT = 0
KEY_POWER, KEY_MENU, KEY_BACK, KEY_HOMEPAGE = 116, 139, 158, 172
KEY_WAKEUP = 143

UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565

ABS_CNT = 64
EVENT = struct.Struct("llHHi")


def find_touchscreen():
    for n in range(32):
        try:
            with open("/sys/class/input/event%d/device/name" % n) as f:
                if f.read().strip() == TOUCH_NAME:
                    return "/dev/input/event%d" % n
        except OSError:
            continue
    return None


def enable_aot():
    """Put the panel into low-power scanning so it reports double taps."""
    for cmd in ("aot_enable,1", "set_lowpower_mode,1"):
        try:
            with open(TSP_CMD, "w") as f:
                f.write(cmd)
            time.sleep(0.3)
        except OSError as e:
            print("could not write %s: %s" % (cmd, e), flush=True)


def wait_for_mce():
    """Do not create the hotplug device before mce's evdev monitor is ready."""
    args = ["gdbus", "call", "--system", "--dest", "com.nokia.mce",
            "--object-path", "/com/nokia/mce/request", "--method",
            "com.nokia.mce.request.get_display_status"]
    for _ in range(30):
        try:
            if subprocess.run(args, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL,
                              timeout=2).returncode == 0:
                return
        except (OSError, subprocess.SubprocessError):
            pass
        time.sleep(1)


def create_uinput():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    # The full dbltap set, so mce classifies this as EVDEV_DBLTAP and not as a
    # power key.
    for key in (KEY_POWER, KEY_MENU, KEY_BACK, KEY_HOMEPAGE):
        fcntl.ioctl(fd, UI_SET_KEYBIT, key)
    dev = bytearray(DEVICE_NAME.ljust(80, b"\0"))
    dev += struct.pack("HHHH", 0x03, 0x1234, 0x5679, 1)
    dev += struct.pack("I", 0)
    dev += struct.pack("%di" % ABS_CNT, *([0] * ABS_CNT)) * 4
    os.write(fd, bytes(dev))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def emit_gesture(fd):
    """mce turns the *release* of KEY_POWER into GESTURE_DOUBLETAP."""
    now = time.time()
    sec, usec = int(now), int((now % 1) * 1000000)
    for value in (1, 0):
        os.write(fd, EVENT.pack(sec, usec, EV_KEY, KEY_POWER, value))
        os.write(fd, EVENT.pack(sec, usec, EV_SYN, SYN_REPORT, 0))
        time.sleep(0.02)


def main():
    verbose = "--verbose" in sys.argv or "--test" in sys.argv
    wait_for_mce()
    fd = create_uinput()
    time.sleep(1.0)          # let mce notice and classify the new device
    if verbose:
        print("uinput '%s' created" % DEVICE_NAME.decode(), flush=True)

    if "--test" in sys.argv:
        print("injecting a synthetic double-tap gesture", flush=True)
        emit_gesture(fd)
        time.sleep(2)
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)
        return

    enable_aot()
    path = find_touchscreen()
    if not path:
        print("touchscreen '%s' not found" % TOUCH_NAME, flush=True)
        return
    if verbose:
        print("watching %s for KEY_WAKEUP" % path, flush=True)
    src = open(path, "rb", buffering=0)
    try:
        while True:
            data = src.read(EVENT.size)
            if not data or len(data) < EVENT.size:
                continue
            _, _, etype, code, value = EVENT.unpack(data)
            if etype == EV_KEY and code == KEY_WAKEUP and value == 1:
                emit_gesture(fd)
                if verbose:
                    print("  KEY_WAKEUP -> doubletap gesture", flush=True)
    finally:
        try:
            fcntl.ioctl(fd, UI_DEV_DESTROY)
        except OSError:
            pass
        os.close(fd)


if __name__ == "__main__":
    main()
