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

WHY THE POLLING IS GATED

Every read of raw_data used to be expensive. The stock sysfs show() handler
enabled the sensor, waited for a sample, and disabled it again. Measured on
d2s, one read cost ~200 ms and generated a large kernel trace:

    ssp_lines per 10s, bridge running : 366
    ssp_lines per 10s, bridge stopped :  13

At a flat 100 ms poll that was ~140 log lines a second - about 97% of
everything the kernel logged - which filled the 1 MB volatile journal in under
two minutes and made `journalctl -b` useless for diagnosing anything that
happened at boot. It also woke the sensor hub three times a second. Holding the
fd open did not help because the work was in show(), per read, not per open.

The d2s kernel fix allows the existing prox_avg control to hold the raw stream
open independently of Samsung's broken HAL proximity channel. This bridge now
enables that stream once while proximity is wanted, reads the already-updated
value without reconfiguring the hub, and disables it again when idle.

Proximity is only wanted when the display is on, or during a call - that second
case matters because mce needs it precisely while the screen is off, to unblank
when the phone leaves the ear. Both come from mce, over `gdbus monitor` on the
system bus, so there is no per-poll D-Bus cost.

The gate fails safe: anything unexpected - the monitor dying, an unparseable
signal, mce not answering at startup - leaves it polling at the active rate,
which is the old behaviour. Proximity going slow is a broken phone call; a
noisy log is not.
"""
import ctypes
import fcntl
import os
import struct
import subprocess
import sys
import threading
import time

RAW_PATH = "/sys/class/sensors/proximity_sensor/raw_data"
RAW_ENABLE_PATH = "/sys/class/sensors/proximity_sensor/prox_avg"
DEVICE_NAME = b"d2s-proximity"

# Hysteresis: the hub re-baselines while covered, so keep the two edges well
# apart rather than using a single threshold.
NEAR_ABOVE = 2500
FAR_BELOW = 1900

# Calls need prompt near/far transitions. Normal display-on sampling only
# keeps the last state fresh for the next blank and can be slower. Idle checks
# are in-memory only and never touch the sensor hub.
CALL_INTERVAL = 0.1
DISPLAY_INTERVAL = 0.8
IDLE_CHECK_INTERVAL = 0.25
STREAM_START_DELAY = 0.25

MCE_DEST = "com.nokia.mce"
MCE_REQ_PATH = "/com/nokia/mce/request"
MCE_REQ_IFACE = "com.nokia.mce.request"

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


def set_raw_stream(enable):
    try:
        with open(RAW_ENABLE_PATH, "w") as f:
            f.write("1\n" if enable else "0\n")
        return True
    except OSError:
        return False


class Gate:
    """Tracks whether proximity is wanted, from mce's display and call state.

    Starts in the active state and only ever goes idle on a signal that says
    so, so every failure mode ends up polling rather than not polling.
    """

    def __init__(self, verbose=False):
        self.verbose = verbose
        self.display = "on"
        self.call = "none"
        self.lock = threading.Lock()
        self.monitor_ready = threading.Event()

    def active(self):
        with self.lock:
            return self.display != "off" or self.call != "none"

    def mode(self):
        with self.lock:
            if self.call != "none":
                return "call"
            if self.display != "off":
                return "display"
            return "idle"

    def _mce_get(self, method):
        try:
            out = subprocess.run(
                ["gdbus", "call", "--system", "--dest", MCE_DEST,
                 "--object-path", MCE_REQ_PATH,
                 "--method", "%s.%s" % (MCE_REQ_IFACE, method)],
                capture_output=True, text=True, timeout=10)
            # Replies look like ('off',) or ('none', 'normal').
            return out.stdout.strip().strip("()").split(",")[0].strip().strip("'")
        except (subprocess.SubprocessError, OSError):
            return None

    def prime(self):
        """One-shot query, so we do not sit active until the first signal."""
        d = self._mce_get("get_display_status")
        c = self._mce_get("get_call_state")
        with self.lock:
            if d:
                self.display = d
            if c:
                self.call = c
        if self.verbose:
            print("gate primed: display=%s call=%s" % (self.display, self.call),
                  flush=True)

    def _consume(self, line):
        # gdbus monitor prints e.g.
        #   /com/nokia/mce/signal: com.nokia.mce.signal.display_status_ind ('off',)
        #
        # Note the name on the bus is display_status_ind, NOT the
        # sig_display_status_ind that mce calls it internally and that its
        # documentation shows. Matching the wire name also matches the sig_
        # form, so this is right either way.
        if "display_status_ind" in line:
            key = "display"
        elif "call_state_ind" in line:
            key = "call"
        else:
            return
        try:
            value = line.split("(", 1)[1].strip().strip(")").split(",")[0]
            value = value.strip().strip("'")
        except IndexError:
            return
        if not value:
            return
        with self.lock:
            setattr(self, key, value)
        if self.verbose:
            print("gate: %s=%s -> %s" % (key, value,
                                         "active" if self.active() else "idle"),
                  flush=True)

    def _watch(self):
        while True:
            try:
                p = subprocess.Popen(
                    ["gdbus", "monitor", "--system", "--dest", MCE_DEST],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    text=True, bufsize=1)
                self.monitor_ready.set()
                for line in p.stdout:
                    self._consume(line)
            except (subprocess.SubprocessError, OSError) as e:
                if self.verbose:
                    print("gate monitor failed: %s" % e, flush=True)
            # The monitor ended - mce restarting, or D-Bus went away. Assume
            # the worst and poll until it tells us otherwise again.
            with self.lock:
                self.display, self.call = "on", "none"
            time.sleep(5)

    def start(self):
        threading.Thread(target=self._watch, daemon=True).start()
        # Subscribe before taking the initial state snapshot. Otherwise a
        # display transition between prime() and monitor startup is lost and
        # can leave raw proximity sampling active while the display is off.
        self.monitor_ready.wait(timeout=2.0)


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

    gate = Gate(verbose)
    gate.start()
    gate.prime()
    streaming = False

    try:
        while True:
            mode = gate.mode()
            if mode == "idle":
                if streaming:
                    set_raw_stream(False)
                    streaming = False
                time.sleep(IDLE_CHECK_INTERVAL)
                continue

            if not streaming:
                if not set_raw_stream(True):
                    time.sleep(1.0)
                    continue
                streaming = True
                # Let the first hub sample replace the reset value.
                time.sleep(STREAM_START_DELAY)

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

            time.sleep(CALL_INTERVAL if mode == "call" else DISPLAY_INTERVAL)
    finally:
        if streaming:
            set_raw_stream(False)
        try:
            fcntl.ioctl(fd, UI_DEV_DESTROY)
        except OSError:
            pass
        os.close(fd)


if __name__ == "__main__":
    main()
