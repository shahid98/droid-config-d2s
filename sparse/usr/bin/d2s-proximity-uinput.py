#!/usr/bin/env python3
"""Feed sensorfw a proximity input device built from the kernel's raw readings.

WHY THIS EXISTS

The TMD4910 works perfectly and Samsung's sensors HAL reports it correctly in
getSensorsList (handle 9, type 8 = SENSOR_TYPE_PROXIMITY). But the events it
delivers are tagged with Samsung's *device-private* type 65592 - the raw
TMD4910 proximity/palm sensor reserved above SENSOR_TYPE_DEVICE_PRIVATE_BASE
(65535). Android does not care, because its sensorservice dispatches events by
sensor handle. sensorfw dispatches by type:

    void HybrisManager::processSample(const sensors_event_t& data) {
        foreach (HybrisAdaptor *adaptor, m_registeredAdaptors.values(data.type))

and HybrisProximityAdaptor registers itself under type 8, so every proximity
event falls through and is dropped. Measured: with the sensor covered and
uncovered repeatedly, sensorfw logged 14 "HYBRIS EVE SENSOR_TYPE_PRIVATE_65592"
and zero "HYBRIS EVE PROXIMITY", and mce never saw a single sample - while
ACCELEROMETER and LIGHT events flowed normally the whole time.

There is no configuration for this: sensorfw's proximity interval range is
clamped to the sensor's [minDelay, maxDelay] = [0, 0], the adaptor's type is
compiled in, and the HAL is a vendor blob. So instead of going through the
hybris adaptor, this reads the kernel's own proximity value and republishes it
as a normal evdev device, which sensorfw's proximityadaptor-evdev consumes.

WHAT IT DOES

Polls /sys/class/sensors/proximity_sensor/raw_data and emits ABS_DISTANCE on a
uinput device, using the evdev convention sensorfw expects: 0 = near (covered),
1 = far. Measured separation on this handset is wide - about 1340 uncovered
versus 3500-4700 covered - so a hysteresis band either side of ~2200 is stable
without tracking the hub's drifting baseline.
"""
import ctypes
import fcntl
import os
import struct
import sys
import time

RAW_PATH = "/sys/class/sensors/proximity_sensor/raw_data"
DEVICE_NAME = b"d2s-proximity"

# Hysteresis: the hub re-baselines while covered, so keep the two edges well
# apart rather than using a single threshold.
NEAR_ABOVE = 2500
FAR_BELOW = 1900
POLL_INTERVAL = 0.1

EV_SYN, EV_ABS = 0x00, 0x03
SYN_REPORT = 0
ABS_DISTANCE = 0x19

UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
UI_SET_EVBIT = 0x40045564
UI_SET_ABSBIT = 0x40045567

ABS_CNT = 64
INPUT_EVENT = struct.Struct("llHHi")

NEAR, FAR = 0, 1


def create_uinput():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_ABS)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    fcntl.ioctl(fd, UI_SET_ABSBIT, ABS_DISTANCE)

    # struct uinput_user_dev: name[80], input_id{4 x u16}, ff_effects_max,
    # then absmax/absmin/absfuzz/absflat, each ABS_CNT s32 entries.
    absmax = [0] * ABS_CNT
    absmin = [0] * ABS_CNT
    absmax[ABS_DISTANCE] = 1
    dev = bytearray(DEVICE_NAME.ljust(80, b"\0"))
    dev += struct.pack("HHHH", 0x03, 0x1234, 0x5678, 1)   # BUS_USB, ids
    dev += struct.pack("I", 0)                            # ff_effects_max
    dev += struct.pack("%di" % ABS_CNT, *absmax)
    dev += struct.pack("%di" % ABS_CNT, *absmin)
    dev += struct.pack("%di" % ABS_CNT, *([0] * ABS_CNT))  # absfuzz
    dev += struct.pack("%di" % ABS_CNT, *([0] * ABS_CNT))  # absflat
    os.write(fd, bytes(dev))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def emit(fd, state):
    now = time.time()
    sec, usec = int(now), int((now % 1) * 1000000)
    os.write(fd, INPUT_EVENT.pack(sec, usec, EV_ABS, ABS_DISTANCE, state))
    os.write(fd, INPUT_EVENT.pack(sec, usec, EV_SYN, SYN_REPORT, 0))


def read_raw():
    try:
        with open(RAW_PATH) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def main():
    verbose = "--verbose" in sys.argv
    fd = create_uinput()
    # Give udev/sensorfw a moment to notice the new node before the first event.
    time.sleep(0.5)
    state = FAR
    emit(fd, state)
    if verbose:
        print("uinput device '%s' created, initial state=far"
              % DEVICE_NAME.decode(), flush=True)
    try:
        while True:
            raw = read_raw()
            if raw is not None:
                if state == FAR and raw >= NEAR_ABOVE:
                    state = NEAR
                    emit(fd, state)
                    if verbose:
                        print("  raw=%d -> NEAR" % raw, flush=True)
                elif state == NEAR and raw <= FAR_BELOW:
                    state = FAR
                    emit(fd, state)
                    if verbose:
                        print("  raw=%d -> FAR" % raw, flush=True)
            time.sleep(POLL_INTERVAL)
    finally:
        try:
            fcntl.ioctl(fd, UI_DEV_DESTROY)
        except OSError:
            pass
        os.close(fd)


if __name__ == "__main__":
    main()
