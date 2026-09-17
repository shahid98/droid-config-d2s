#!/usr/bin/env python3
"""Start CP voice-call audio by driving the vendor audio HAL over HIDL.

WHY THIS EXISTS

Calls connected but were silent both ways. On Android the vendor audio HAL sets
up call audio: it routes the codec, tells the CP over rild's abstract socket
@VND_Multiclient (SetCallAudioPath / SetCallClockSync), and opens the CP voice
PCMs. Nothing did that here - the HAL is 32-bit so PulseAudio cannot dlopen it,
and Sailfish has no AudioFlinger to drive it. Talking to rild's socket directly
is impossible too: it accepts gpsd but closes our connections instantly, and
uid, peer executable path, free client slots, SELinux and timing were all ruled
out.

The way in: the HAL runs in its own process,
/vendor/bin/hw/android.hardware.audio@2.0-service, and registers
android.hardware.audio@5.0::IDevicesFactory on hwbinder. Its 32-bitness only
ever blocked an in-process dlopen; a 64-bit caller over binder is fine, and
being a vendor process it IS allowed on the rild socket.

THE SEQUENCE THAT WORKS (verified on a live call - audio and DTMF both good)

    openPrimaryDevice                       IDevicesFactory code 2
    setMode(AUDIO_MODE_IN_CALL)             IPrimaryDevice  code 23
    setVoiceVolume(1.0)                     IPrimaryDevice  code 22
    openOutputStream(...)                   IDevice         code 9
    IStream.setParameters(routing=<dev>)    IStream         code 21   <- the trigger
    IStream.start()                         IStream         code 22

after which the HAL logs exactly what is wanted:

    adev_set_route: routes to device(handset-mic) for usage(voice_call_nb)
    AudioRil: ### setVoicePath deviceType : 0x1, ret = [0]
    proxy-voice_rx_start: Voice Call RX PCM Device(/dev/snd/pcmC0D4p) opened & started
    proxy-voice_tx_start: Voice Call TX PCM Device(/dev/snd/pcmC0D14c) opened & started
    out_set_parameters: *** Started CP Voice Call ***

The HAL does ALL the routing itself, so the mixer lists in
/usr/share/droid-audio/incall/ are not applied during a call any more - they
would fight it. The boot media+mic lists are re-applied afterwards, because the
HAL leaves the mixer set up for a call.

HARD-WON DETAILS

* A transaction carries the descriptor of the interface that DECLARES the
  method. setMode/setVoiceVolume are IPrimaryDevice's; setParameters and
  openOutputStream are inherited from IDevice; stream calls use IStream. Using
  the wrong descriptor fails with UNKNOWN_ERROR - which made codes 17..21 on
  IPrimaryDevice look broken while 22+ worked.
* IStream numbering (mapped by sending a uniquely named key per code and
  reading the HAL's log): 17 getDevice, 18 setDevice, 19 setHwAvSync,
  20 getParameters, 21 setParameters, 22 start, 23 stop, 26 close. Do not
  assume the AOSP order - setConnectedState is IDevice's, not IStream's, which
  shifts everything after setDevice by one.
* openPrimaryDevice's reply is 32 bytes: int32 Result, 4 bytes of padding, then
  a 24-byte flat_binder_object. gbinder will not read an object from a
  misaligned offset and its reader has no skip(), so consume the padding with a
  uint32 read.
* GBinderWriterType.fields needs an explicit ctypes.cast to
  POINTER(GBinderWriterField).
* Only one primary_out may be open: a second openOutputStream returns nothing.

Routing values are Android's audio_devices_t: EARPIECE 0x1, SPEAKER 0x2.
"""
import ctypes as C
import glob
import os
import select
import signal
import struct
import subprocess
import sys
import threading
import time

AUDIO_MODE_NORMAL = 0
AUDIO_MODE_IN_CALL = 2
ROUTING = {"handset": 0x1, "earpiece": 0x1, "dual-speaker": 0x2, "speaker": 0x2}
# The in-call UI publishes its chosen output as org.nemomobile.voicecall's
# audioMode: "earpiece" or "ihf" (integrated hands-free = loudspeaker).
UI_ROUTING = {"earpiece": 0x1, "ihf": 0x2, "speaker": 0x2, "bluetooth": 0x20}
USER_BUS = "unix:path=/run/user/100000/dbus/user_bus_socket"

# The in-call volume slider is decorative here: moving it changes nothing we
# can observe - not dconf, not the PulseAudio sink volumes, not ofono's
# CallVolume (which stays 0x00) - because Sailfish is adjusting a PulseAudio
# call stream that does not exist when the HAL owns call audio. The volume
# KEYS still work though, so they are read directly and applied to the HAL.
# gpio_keys advertises KEY=1c000000000000, i.e. codes 114/115/116.
KEY_VOLUMEDOWN = 114
KEY_VOLUMEUP = 115
VOLUME_STEPS = [0.2, 0.4, 0.6, 0.8, 1.0]
INPUT_EVENT = struct.Struct("llHHi")   # sec, usec, type, code, value

FACTORY = b"android.hardware.audio@5.0::IDevicesFactory/default"
FACTORY_IFACE = b"android.hardware.audio@5.0::IDevicesFactory"
DEVICE_IFACE = b"android.hardware.audio@5.0::IDevice"
PRIMARY_IFACE = b"android.hardware.audio@5.0::IPrimaryDevice"
STREAM_IFACE = b"android.hardware.audio@5.0::IStream"

CODE_SET_MIC_MUTE = 4          # IDevice
CODE_OPEN_PRIMARY = 2
CODE_OPEN_OUTPUT_STREAM = 9
CODE_SET_VOICE_VOLUME = 22
CODE_SET_MODE = 23
CODE_STREAM_SET_PARAMETERS = 21
CODE_STREAM_START = 22
CODE_STREAM_STOP = 23
CODE_STREAM_CLOSE = 26

try:
    g = C.CDLL("libgbinder.so.1")
except OSError as exc:
    print("cannot load libgbinder: %s" % exc, flush=True)
    sys.exit(1)

for name, restype, argtypes in [
    ("gbinder_servicemanager_new", C.c_void_p, [C.c_char_p]),
    ("gbinder_servicemanager_get_service_sync", C.c_void_p,
     [C.c_void_p, C.c_char_p, C.POINTER(C.c_int)]),
    ("gbinder_client_new", C.c_void_p, [C.c_void_p, C.c_char_p]),
    ("gbinder_client_new_request", C.c_void_p, [C.c_void_p]),
    ("gbinder_client_transact_sync_reply", C.c_void_p,
     [C.c_void_p, C.c_uint32, C.c_void_p, C.POINTER(C.c_int)]),
]:
    fn = getattr(g, name)
    fn.restype = restype
    fn.argtypes = argtypes
g.gbinder_servicemanager_wait.restype = C.c_bool
g.gbinder_servicemanager_wait.argtypes = [C.c_void_p, C.c_long]
g.gbinder_local_request_init_writer.argtypes = [C.c_void_p, C.c_void_p]
g.gbinder_writer_append_int32.argtypes = [C.c_void_p, C.c_uint32]
g.gbinder_writer_append_float.argtypes = [C.c_void_p, C.c_float]
g.gbinder_writer_append_bool.argtypes = [C.c_void_p, C.c_bool]
g.gbinder_writer_append_struct.argtypes = [C.c_void_p, C.c_void_p, C.c_void_p, C.c_void_p]
g.gbinder_writer_append_struct_vec.argtypes = [C.c_void_p, C.c_void_p, C.c_uint, C.c_void_p]
g.gbinder_remote_reply_init_reader.argtypes = [C.c_void_p, C.c_void_p]
g.gbinder_reader_read_int32.restype = C.c_bool
g.gbinder_reader_read_int32.argtypes = [C.c_void_p, C.POINTER(C.c_int32)]
g.gbinder_reader_read_uint32.restype = C.c_bool
g.gbinder_reader_read_uint32.argtypes = [C.c_void_p, C.POINTER(C.c_uint32)]
g.gbinder_reader_read_nullable_object.restype = C.c_bool
g.gbinder_reader_read_nullable_object.argtypes = [C.c_void_p, C.POINTER(C.c_void_p)]

READER = C.create_string_buffer(256)
KEEP = []
_running = True


def _stop(_signum, _frame):
    global _running
    _running = False


class HidlString(C.Structure):
    _fields_ = [("buffer", C.c_char_p), ("size", C.c_uint32),
                ("owns", C.c_bool), ("pad", C.c_uint8 * 3)]


class HidlVec(C.Structure):
    _fields_ = [("buffer", C.c_void_p), ("size", C.c_uint32),
                ("owns", C.c_bool), ("pad", C.c_uint8 * 3)]


class ParameterValue(C.Structure):
    _fields_ = [("key", HidlString), ("value", HidlString)]


class DeviceAddress(C.Structure):
    _fields_ = [("device", C.c_uint32), ("address", C.c_uint8 * 8),
                ("pad0", C.c_uint8 * 4),
                ("busAddress", HidlString), ("rSubmixAddress", HidlString)]


class AudioOffloadInfo(C.Structure):
    _fields_ = [("sampleRateHz", C.c_uint32), ("channelMask", C.c_uint32),
                ("format", C.c_uint32), ("streamType", C.c_int32),
                ("bitRatePerSecond", C.c_uint32), ("pad0", C.c_uint32),
                ("durationMicroseconds", C.c_int64),
                ("hasVideo", C.c_bool), ("isStreaming", C.c_bool),
                ("pad1", C.c_uint8 * 2), ("bitWidth", C.c_uint32),
                ("bufferSize", C.c_uint32), ("usage", C.c_int32)]


class AudioConfig(C.Structure):
    _fields_ = [("sampleRateHz", C.c_uint32), ("channelMask", C.c_uint32),
                ("format", C.c_uint32), ("pad0", C.c_uint32),
                ("offloadInfo", AudioOffloadInfo), ("frameCount", C.c_uint64)]


class SourceMetadata(C.Structure):
    _fields_ = [("tracks", HidlVec)]


class WField(C.Structure):
    _fields_ = [("name", C.c_char_p), ("offset", C.c_size_t),
                ("type", C.c_void_p), ("write_buf", C.c_void_p),
                ("reserved", C.c_void_p)]


class WType(C.Structure):
    _fields_ = [("name", C.c_char_p), ("size", C.c_size_t),
                ("fields", C.POINTER(WField))]


_STR_WB = C.cast(g.gbinder_writer_field_hidl_string_write_buf, C.c_void_p).value
_VEC_WB = C.cast(g.gbinder_writer_field_hidl_vec_write_buf, C.c_void_p).value


def mktype(name, size, fields):
    arr = (WField * (len(fields) + 1))()
    for i, field in enumerate(fields):
        arr[i] = field
    arr[len(fields)] = WField(None, 0, None, None, None)
    wtype = WType(name, size, C.cast(arr, C.POINTER(WField)))
    KEEP.extend([arr, wtype])
    return wtype


PV_TYPE = mktype(b"ParameterValue", C.sizeof(ParameterValue), [
    WField(b"key", 0, None, _STR_WB, None),
    WField(b"value", 16, None, _STR_WB, None)])
DA_TYPE = mktype(b"DeviceAddress", C.sizeof(DeviceAddress), [
    WField(b"busAddress", DeviceAddress.busAddress.offset, None, _STR_WB, None),
    WField(b"rSubmixAddress", DeviceAddress.rSubmixAddress.offset, None, _STR_WB, None)])
AC_TYPE = mktype(b"AudioConfig", C.sizeof(AudioConfig), [])
PTM_TYPE = mktype(b"PlaybackTrackMetadata", 12, [])
SM_TYPE = mktype(b"SourceMetadata", C.sizeof(SourceMetadata), [
    WField(b"tracks", 0, C.cast(C.byref(PTM_TYPE), C.c_void_p), _VEC_WB, None)])


def empty_pv():
    return pv_array([])


def hidl_string(text):
    raw = text.encode()
    KEEP.append(raw)
    return HidlString(raw, len(raw), False, (C.c_uint8 * 3)())


def pv_array(pairs):
    array = (ParameterValue * max(len(pairs), 1))()
    for i, (key, value) in enumerate(pairs):
        array[i].key = hidl_string(key)
        array[i].value = hidl_string(value)
    KEEP.append(array)
    return array


def transact(client, code, build=None, want_object=False):
    req = g.gbinder_client_new_request(client)
    if build:
        writer = C.create_string_buffer(256)
        g.gbinder_local_request_init_writer(req, writer)
        build(writer)
    status = C.c_int(0)
    reply = g.gbinder_client_transact_sync_reply(client, code, req, C.byref(status))
    if not reply:
        return status.value, None, None
    g.gbinder_remote_reply_init_reader(reply, READER)
    result = C.c_int32(-1)
    g.gbinder_reader_read_int32(READER, C.byref(result))
    obj = None
    if want_object:
        padding = C.c_uint32(0)
        g.gbinder_reader_read_uint32(READER, C.byref(padding))
        ptr = C.c_void_p(None)
        g.gbinder_reader_read_nullable_object(READER, C.byref(ptr))
        obj = ptr.value
    return status.value, result.value, obj


def volume_key_device():
    """The input device carrying KEY_VOLUMEUP/DOWN (gpio_keys on this device)."""
    try:
        blocks = open("/proc/bus/input/devices").read().split("\n\n")
    except OSError:
        return None
    for block in blocks:
        if "gpio_keys" not in block:
            continue
        for part in block.split():
            if part.startswith("event"):
                return "/dev/input/" + part
    return None


class VolumeKeys(threading.Thread):
    """Applies the hardware volume keys to the HAL during a call."""

    daemon = True

    def __init__(self, apply_volume, start_index=3):
        threading.Thread.__init__(self)
        self.apply_volume = apply_volume
        self.index = start_index
        self.path = volume_key_device()

    def run(self):
        if not self.path:
            print("no volume-key device found", flush=True)
            return
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError as exc:
            print("cannot read %s: %s" % (self.path, exc), flush=True)
            return
        print("reading volume keys from %s" % self.path, flush=True)
        try:
            while _running:
                ready, _, _ = select.select([fd], [], [], 0.5)
                if not ready:
                    continue
                try:
                    data = os.read(fd, INPUT_EVENT.size * 32)
                except OSError:
                    continue
                for i in range(0, len(data) - INPUT_EVENT.size + 1, INPUT_EVENT.size):
                    _s, _us, etype, code, value = INPUT_EVENT.unpack_from(data, i)
                    if etype != 1 or value != 1:      # EV_KEY, key down only
                        continue
                    if code == KEY_VOLUMEUP:
                        self.index = min(self.index + 1, len(VOLUME_STEPS) - 1)
                    elif code == KEY_VOLUMEDOWN:
                        self.index = max(self.index - 1, 0)
                    else:
                        continue
                    self.apply_volume(VOLUME_STEPS[self.index])
        finally:
            os.close(fd)


def ui_state():
    """(routing, muted) as the in-call UI currently wants them, or (None, None).

    The UI does not reach the vendor HAL by itself: the speaker button only
    sets audioMode on org.nemomobile.voicecall, and the mute button only sets
    isMicrophoneMuted, so both are polled here and pushed down to the HAL.
    """
    try:
        out = subprocess.run(
            ["gdbus", "call", "--address", USER_BUS,
             "--dest", "org.nemomobile.voicecall", "--object-path", "/",
             "--method", "org.freedesktop.DBus.Properties.GetAll",
             "org.nemomobile.voicecall.VoiceCallManager"],
            capture_output=True, timeout=4, text=True).stdout
    except (OSError, subprocess.SubprocessError):
        return None, None
    if "'activeVoiceCall': <''>" in out:
        # No call in the UI's view: it resets audioMode/mute as the call ends,
        # and acting on that just fights the teardown.
        return None, None
    routing = None
    for name, value in UI_ROUTING.items():
        if "'audioMode': <'%s'>" % name in out:
            routing = value
            break
    muted = None
    if "'isMicrophoneMuted': <true>" in out:
        muted = True
    elif "'isMicrophoneMuted': <false>" in out:
        muted = False
    return routing, muted


def start_call_audio(routing):
    sm = g.gbinder_servicemanager_new(b"/dev/hwbinder")
    if not sm:
        print("no service manager on /dev/hwbinder", flush=True)
        return None
    g.gbinder_servicemanager_wait(sm, 5000)
    status = C.c_int(0)
    obj = g.gbinder_servicemanager_get_service_sync(sm, FACTORY, C.byref(status))
    if not obj:
        print("IDevicesFactory unavailable (status=%d)" % status.value, flush=True)
        return None

    factory = g.gbinder_client_new(obj, FACTORY_IFACE)
    st, result, dev = transact(factory, CODE_OPEN_PRIMARY, None, want_object=True)
    if not dev:
        print("openPrimaryDevice failed (status=%d Result=%s)" % (st, result), flush=True)
        return None
    primary = g.gbinder_client_new(dev, PRIMARY_IFACE)
    device = g.gbinder_client_new(dev, DEVICE_IFACE)

    st, result, _ = transact(primary, CODE_SET_MODE,
                             lambda w: g.gbinder_writer_append_int32(w, AUDIO_MODE_IN_CALL))
    print("setMode(in_call): status=%d Result=%s" % (st, result), flush=True)
    if st != 0:
        return None

    # The HAL starts a call at volume 0 otherwise.
    st, result, _ = transact(primary, CODE_SET_VOICE_VOLUME,
                             lambda w: g.gbinder_writer_append_float(w, 1.0))
    print("setVoiceVolume(1.0): status=%d Result=%s" % (st, result), flush=True)

    addr = DeviceAddress()
    addr.device = routing
    addr.busAddress = hidl_string("")
    addr.rSubmixAddress = hidl_string("")
    config = AudioConfig()
    config.sampleRateHz = 48000
    config.channelMask = 0x3          # AUDIO_CHANNEL_OUT_STEREO
    config.format = 0x1               # AUDIO_FORMAT_PCM_16_BIT
    metadata = SourceMetadata()
    KEEP.extend([addr, config, metadata])

    def build_open(writer):
        g.gbinder_writer_append_int32(writer, 1)                  # ioHandle
        g.gbinder_writer_append_struct(writer, C.byref(addr), C.byref(DA_TYPE), None)
        g.gbinder_writer_append_struct(writer, C.byref(config), C.byref(AC_TYPE), None)
        g.gbinder_writer_append_int32(writer, 0x2)                # OUTPUT_FLAG_PRIMARY
        g.gbinder_writer_append_struct(writer, C.byref(metadata), C.byref(SM_TYPE), None)

    st, result, stream = transact(device, CODE_OPEN_OUTPUT_STREAM, build_open,
                                  want_object=True)
    print("openOutputStream: status=%d Result=%s" % (st, result), flush=True)
    if not stream:
        return None
    stream_client = g.gbinder_client_new(stream, STREAM_IFACE)

    empty = pv_array([])
    params = pv_array([("routing", str(routing))])

    def build_params(writer):
        g.gbinder_writer_append_struct_vec(writer, empty, 0, C.byref(PV_TYPE))
        g.gbinder_writer_append_struct_vec(writer, params, 1, C.byref(PV_TYPE))

    # This is the call that makes the HAL run setVoicePath and open the CP
    # voice PCMs - "*** Started CP Voice Call ***".
    st, result, _ = transact(stream_client, CODE_STREAM_SET_PARAMETERS, build_params)
    print("stream setParameters(routing=0x%x): status=%d Result=%s"
          % (routing, st, result), flush=True)

    st, result, _ = transact(stream_client, CODE_STREAM_START)
    print("stream start: status=%d Result=%s" % (st, result), flush=True)
    return primary, device, stream_client


def main(argv):
    route = "handset"
    for arg in argv[1:]:
        if arg.startswith("--route="):
            route = arg.split("=", 1)[1]
    routing = ROUTING.get(route, 0x1)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    started = start_call_audio(routing)
    if not started:
        return 1
    primary, device, stream_client = started

    # Hold everything open - the HAL tears the call path down as soon as the
    # last reference goes away - and follow the in-call UI while we are here,
    # so the speaker and mute buttons actually do something.
    def apply_volume(level):
        st, result, _ = transact(primary, CODE_SET_VOICE_VOLUME,
                                 lambda w, v=level: g.gbinder_writer_append_float(w, v))
        print("volume key -> %.1f: status=%d Result=%s" % (level, st, result), flush=True)

    VolumeKeys(apply_volume).start()

    current_routing = routing
    current_muted = False
    seen_routing = seen_muted = None
    while _running:
        time.sleep(0.5)
        want_routing, want_muted = ui_state()
        # Debounce: act only on a value that shows up twice in a row. A single
        # stale or mid-transition read otherwise makes the route oscillate.
        stable_routing = want_routing if want_routing == seen_routing else None
        stable_muted = want_muted if want_muted == seen_muted else None
        seen_routing, seen_muted = want_routing, want_muted
        want_routing, want_muted = stable_routing, stable_muted
        if want_routing is not None and want_routing != current_routing:
            params = pv_array([("routing", str(want_routing))])

            def build(writer, params=params):
                g.gbinder_writer_append_struct_vec(writer, empty_pv(), 0, C.byref(PV_TYPE))
                g.gbinder_writer_append_struct_vec(writer, params, 1, C.byref(PV_TYPE))
            st, result, _ = transact(stream_client, CODE_STREAM_SET_PARAMETERS, build)
            print("UI route change -> 0x%x: status=%d Result=%s"
                  % (want_routing, st, result), flush=True)
            if st == 0:
                current_routing = want_routing
        if want_muted is not None and want_muted != current_muted:
            st, result, _ = transact(device, CODE_SET_MIC_MUTE,
                                     lambda w, v=want_muted: g.gbinder_writer_append_bool(w, v))
            print("UI mute -> %s: status=%d Result=%s" % (want_muted, st, result), flush=True)
            if st == 0:
                current_muted = want_muted

    # Tear down explicitly and in this order. Relying on process exit alone
    # leaves the CP voice PCMs (pcm4p RX, pcm14c TX, pcm19c TX-direct) RUNNING:
    # the HAL then reports "is not ready" on the next call and never closes
    # them, which holds ABOX DMA channels and breaks camera recording and video
    # playback until vendor.audio-hal-2-0 is restarted.
    st, result, _ = transact(primary, CODE_SET_MODE,
                             lambda w: g.gbinder_writer_append_int32(w, AUDIO_MODE_NORMAL))
    print("setMode(normal): status=%d Result=%s" % (st, result), flush=True)
    st, result, _ = transact(stream_client, CODE_STREAM_STOP)
    print("stream stop: status=%d Result=%s" % (st, result), flush=True)
    st, result, _ = transact(stream_client, CODE_STREAM_CLOSE)
    print("stream close: status=%d Result=%s" % (st, result), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
