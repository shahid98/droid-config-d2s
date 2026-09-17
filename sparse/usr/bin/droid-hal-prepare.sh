#!/bin/sh
# droid-hal-prepare.service - runs Before=droid-hal-init.service.
#
# This MUST be its own unit, not an ExecStartPre of droid-hal-init: that service
# sets ProtectSystem=full and PrivateTmp=true, and systemd gives every Exec*
# process its own mount namespace, so mounts made in ExecStartPre are torn down
# before ExecStart runs. This unit has no namespacing, so its mounts land in the
# host namespace and are inherited by droid-hal-init.

E=/var/lib/hybris-fix/empty.rc
K=/var/lib/hybris-fix/ok.sh

# 1. Flattened APEX.
# LOS 18.1 is not an updatable-APEX device, so apexd exits immediately and
# init's own ActivateFlattenedApexesIfPossible() is compiled out by the hybris
# patches (#ifdef DISABLED_FOR_HYBRIS_SUPPORT around SetupMountNamespaces).
# Every dynamically linked Android binary names
# /apex/com.android.runtime/bin/linker64 as its ELF interpreter.
#
# The mount point MUST be the name declared in apex_manifest.pb, not the
# directory name: com.android.vndk.current declares com.android.vndk.v30, and
# linkerconfig looks for /apex/com.android.vndk.v30/etc/llndk.libraries.30.txt.
for apex in /system/apex/*/; do
    [ -d "$apex" ] || continue
    dir=$(basename "$apex")
    name=$(strings "$apex/apex_manifest.pb" 2>/dev/null | head -1)
    case "$name" in
        com.android.*) ;;
        *) name=${dir%.release} ;;
    esac
    [ -e "/apex/$name/etc" ] && continue
    mkdir -p "/apex/$name"
    mount --bind "$apex" "/apex/$name"
done

# 2b. Stop apexd from shadowing /apex.
# apexd-bootstrap mounts an empty tmpfs on /apex (nosuid,nodev,noexec,mode=755)
# and then exits with "This device does not support updatable APEX", because
# ro.apex.updatable=false. That empty tmpfs hides every bind mount made above,
# so /apex looks empty to init and every dynamically linked Android binary
# fails execv with ENOENT (its interpreter is
# /apex/com.android.runtime/bin/linker64). apexd does nothing useful on a
# flattened-APEX device, so shadow its rc file to keep it from running.
grep -q " /system/etc/init/apexd.rc " /proc/mounts || mount -o bind "$E" /system/etc/init/apexd.rc

# 3. Neutralise the BoringSSL self-test: on failure init reboots the device with
# reason boringssl-self-check-failed. Declared in BOTH the hybris init.rc and
# /vendor/etc/init/boringssl_self_test.rc; the vendor copy is on a read-only
# partition, so shadow it with bind mounts.
grep -q " /vendor/etc/init/boringssl_self_test.rc " /proc/mounts || mount -o bind "$E" /vendor/etc/init/boringssl_self_test.rc
grep -q " /vendor/bin/boringssl_self_test64 " /proc/mounts || mount -o bind "$K" /vendor/bin/boringssl_self_test64
grep -q " /vendor/bin/boringssl_self_test32 " /proc/mounts || mount -o bind "$K" /vendor/bin/boringssl_self_test32

# 4. Android init aborts first stage if this node already exists (devtmpfs
# created it). Only the WORLD_WRITABLE_KMSG CHECKCALL survives the hybris
# patches in first_stage_init.cpp, and it is fatal on any restart.
rm -f /dev/kmsg_debug

# 6. USB gadget: leave Android's USB rc files alone.
# These used to be shadowed to stop the HAL reconfiguring the gadget and
# tearing down the initramfs rndis0 (which cost us telnet the moment the HAL
# came up). That trade no longer makes sense: usb-moded owns USB on Sailfish
# and its developer_mode-android dyn-mode drives the gadget through these very
# rc triggers, so shadowing them left usb-moded with nothing to configure and
# rndis0 vanished altogether. Let Android's USB rc load and let usb-moded
# manage the mode.

# 7. Disable Android's surfaceflinger and bootanimation.
# This is a Sailfish port: lipstick owns the display through
# qt5-qpa-hwcomposer-plugin talking to hwcomposer via libhybris. Android's
# surfaceflinger would contend for the same display, and bootanimation is
# pointless here - together they deadlocked the device with everything stuck in
# binder_ioctl_write_read / futex_wait_queue_me while the boot spinner stayed on
# screen. The graphics.composer@2.2 and graphics.allocator@2.0 HALs are kept:
# those are what libhybris actually needs.
for f in /system/etc/init/surfaceflinger.rc /system/etc/init/bootanim.rc; do
    [ -e "$f" ] || continue
    grep -q " $f " /proc/mounts || mount -o bind "$E" "$f"
done

# 8. Log fatal signals.
# systemd-tmpfiles and systemd-logind both die with SIGSEGV, but arm64 does not
# log unhandled signals by default, so dmesg showed nothing. With this on, the
# kernel prints the faulting pc/library for each crash, which is what we need to
# identify the shared cause.
echo 1 > /proc/sys/kernel/print-fatal-signals 2>/dev/null

# 9. Guarantee the Sailfish session bootstate exists.
# /usr/lib/tmpfiles.d/jolla-session-tmp.conf creates /run/systemd/boot-status,
# but systemd-tmpfiles was SIGSEGVing (selinuxfs), so the directory never
# appeared. initial-bootstate.service has ConditionPathExists=/run/systemd/
# boot-status, so it was silently skipped, and /run/systemd/boot-status/bootstate
# - which defines SESSION_TARGET - was never written. user@.service then runs
#     ExecStart=/usr/lib/systemd/systemd --user --unit=${SESSION_TARGET}
# with an empty unit name and exits 1, taking the whole session (and lipstick)
# down with it. Create both here so the session no longer depends on tmpfiles
# having succeeded, or on unit ordering.
mkdir -p /run/systemd/boot-status
if [ ! -s /run/systemd/boot-status/bootstate ]; then
    if grep -q actdead /proc/1/cmdline 2>/dev/null; then
        printf 'BOOTSTATE=ACT_DEAD\nSESSION_TARGET=actdead-session.target\n' > /run/systemd/boot-status/bootstate
        : > /run/systemd/boot-status/ACT_DEAD
    else
        printf 'BOOTSTATE=USER\nSESSION_TARGET=default.target\n' > /run/systemd/boot-status/bootstate
        : > /run/systemd/boot-status/USER
    fi
fi

# Keep Android's audioserver from ever starting.
#
# /system/etc/init/audioserver.rc defines "service audioserver ... class core",
# so droid-hal-init starts it unconditionally. On a hybris port that is wrong:
# PulseAudio's module-droid-card opens the audio HAL *directly* through
# libhybris, and Android's audioserver opens the very same HAL and drives the
# mixer itself. The two fight over the hardware and the result is silence -
# PulseAudio happily accepts streams, reports routing=2 (speaker) and volume
# 1.0, the sink leaves SUSPENDED, and nothing comes out of the speakers.
#
# That audioserver should not be running here is also why
# audiosystem-passthrough exists at all: it provides a *fake* AudioFlinger for
# Android services to talk to. With the real one running,
# audiosystem-passthrough-dummy-af cannot even register and dies with
#   ERROR: Failed to add media.audio_flinger (-2147483647)
#
# This has to happen before droid-hal-init parses the .rc files, hence here
# rather than in droid-apex-bind.sh (which runs from `on early-init`, i.e.
# after parsing). Bind an empty file over the .rc so the service is never
# defined; /system is read-only, but a bind mount over a file works anyway.
if [ -f /system/etc/init/audioserver.rc ] && \
   [ -s /system/etc/init/audioserver.rc ]; then
    : > /var/lib/hybris-fix/empty.rc 2>/dev/null || :
    [ -e /var/lib/hybris-fix/empty.rc ] && \
        /bin/mount --bind /var/lib/hybris-fix/empty.rc \
                          /system/etc/init/audioserver.rc 2>/dev/null
fi

# Keep Android's cameraserver from starting, for the same reason.
#
# On a hybris port the camera service is provided by droidmedia's
# minimediaservice, which talks to the camera provider HAL itself. Android's
# /system/bin/cameraserver was running as well - both are clients of
# vendor.samsung.hardware.camera.provider@3.0 and both want media.camera.
# Upstream droid-configs-device disables it on every Android base
#   sparse-11/usr/libexec/droid-hybris/system/etc/init/disabled_services.rc:
#   service cameraserver cameraserver_HYBRIS_DISABLED
# but that file only ships when the spec defines android_version_major, which
# ours does not. Enabling that wholesale is not an option: the same file also
# disables vendor.usb-hal-1-2 and netd, and usb-moded depends on the Android USB
# rc for the RNDIS gadget (see section 6 above).
if [ -s /system/etc/init/cameraserver.rc ]; then
    grep -q " /system/etc/init/cameraserver.rc " /proc/mounts || \
        /bin/mount --bind "$E" /system/etc/init/cameraserver.rc 2>/dev/null
fi

# Give droidmedia's camera service the hybris-patched libcameraservice.
#
# minimediaservice (32-bit, droidmedia) resolves libcameraservice.so through
# the linker's "system" section (see droid-apex-bind.sh, 2b), i.e. from
# /system/lib. On this port /system is the stock LineageOS ROM's, built
# WITHOUT hybris-patches, and its CameraService::loadSoundLocked() creates an
# Android MediaPlayer for the record-start beep. That waits forever for
# media.audio_flinger, which never exists here (PulseAudio owns audio):
#     Camera2Client::startRecordingL -> CameraService::playSound
#     -> loadSoundLocked -> newMediaPlayer -> AudioSystem::get_audio_flinger
#     -> ServiceManager getService() -> usleep, forever
# startRecording never returns, the client lock stays held, and video
# recording hangs with "Camera is not responding" (stills are unaffected:
# gst-droid disables the shutter sound, the record sound is unconditional).
# hybris-patches frameworks/av/0001 compiles that body out; droid-hal ships
# the patched build as /usr/libexec/droid-hybris/system/lib/libcameraservice.so.
# Bind it over the ROM's copy before droid-hal-init starts minimediaservice.
HCS=/usr/libexec/droid-hybris/system/lib/libcameraservice.so
SCS=/system/lib/libcameraservice.so
if [ -f "$HCS" ] && [ -f "$SCS" ]; then
    grep -q " $SCS " /proc/mounts || /bin/mount --bind "$HCS" "$SCS" 2>/dev/null
fi

# Stop Samsung's HWC event thread spinning on the DECON vsync nodes.
#
# Symptom: one CPU core pinned from boot to shutdown, SoC at 76 C, battery at
# 44 C, and the phone charging at ~20 mA out of an 875 mA USB budget even with
# the screen off.
#
# Samsung's HWC (libexynosdisplay.so, loaded in-process by lipstick) runs
# hwc_eventHndler_thread(). Disassembly of that function shows one poll with no
# timeout over three descriptors:
#     fds[0] = uevent_get_fd(), events = POLLIN
#     fds[1] = 19030000.decon_f/vsync, events = POLLPRI
#     fds[2] = 19050000.decon_t/vsync, events = POLLPRI
# Reading the live pollfd array out of /proc/<lipstick>/mem confirms it, and
# shows decon_f permanently returning revents = POLLPRI|POLLERR.
#
# A sysfs attribute reports POLLERR|POLLPRI until the reader clears it with
# lseek()+read() on the SAME open file description, and POLLERR is delivered
# regardless of the events mask. This HWC never reads either node - ftrace on
# the thread counts 21207 syscalls in a second, all of them ppoll, zero reads -
# so the condition never clears and poll() returns instantly forever. The rate
# is identical with the screen on and off, so vsync genuinely does not flow
# through these nodes on this device; the compositor gets it another way.
#
# Binding a plain file over each attribute fixes it without touching the
# kernel: a regular file never reports POLLPRI or POLLERR, so the poll blocks
# as intended. Verified on decon_t first (its entry went from revents=10 to
# revents=0 while the node still reads normally).
#
# This must happen before lipstick opens the nodes, which is why it lives here
# rather than in a later unit: a bind only affects opens made after it.
FAKE_VSYNC=/var/lib/hybris-fix/fake-vsync
if [ -f /vendor/lib64/libexynosdisplay.so ]; then
    mkdir -p /var/lib/hybris-fix
    printf '0\n' > "$FAKE_VSYNC" 2>/dev/null
    chmod 444 "$FAKE_VSYNC" 2>/dev/null
    # BOTH controllers. decon_t is the dead second one and was always safe.
    # decon_f is the live node and is the one that actually latches: binding it
    # stops the spin completely, but it also costs the compositor its vsync,
    # because that busy poll is what drives the vsync callback here. On its own
    # that dropped the display to ~17-18 fps - the qt5-qpa-hwcomposer-plugin
    # falling back to its vsync timeout (hwcomposer_backend_v11.cpp
    # m_vsyncTimeout), which upstream hardcodes to 50 ms.
    #
    # That timeout is now configurable (our patch to the plugin) and set to one
    # display period by QPA_HWC_VSYNC_TIMEOUT=16 in the compositor environment,
    # so the frame clock becomes a 60 Hz timer and the core stops spinning.
    #
    # Both parts are required together: bind these without the patched plugin
    # and the UI runs at 20 fps; ship the patch without the bind and the HWC
    # event thread keeps a core busy from boot (d2s-hwc-affinity.service then
    # only makes it cheaper, not free).
    for vs in /sys/devices/platform/19050000.decon_t/vsync \
              /sys/devices/platform/19030000.decon_f/vsync; do
        [ -e "$vs" ] || continue
        grep -q " $vs " /proc/mounts || \
            /bin/mount --bind "$FAKE_VSYNC" "$vs" 2>/dev/null
    done
fi

# Android's /dev/stune, which init.rc normally creates and droid-hal-init does
# not. The kernel has the schedtune cgroup (it is mounted at
# /sys/fs/cgroup/schedtune), but Samsung's performance HAL looks for the
# Android path and logs on every single boost attempt:
#
#     W libperfmgr: Failed to write to node: /dev/stune/top-app/schedtune.boost
#
# Bind the cgroup where it expects it and create the boost groups, so the
# vendor HAL works as designed instead of failing constantly. Note nothing on
# Sailfish classifies apps into these groups the way Android's ActivityManager
# does, so this stops the failures rather than changing scheduling on its own.
if [ -d /sys/fs/cgroup/schedtune ]; then
    mkdir -p /dev/stune
    grep -q " /dev/stune " /proc/mounts || \
        /bin/mount --bind /sys/fs/cgroup/schedtune /dev/stune 2>/dev/null
    for grp in top-app foreground background rt; do
        mkdir -p "/dev/stune/$grp" 2>/dev/null
    done
    chown -R system:system /dev/stune 2>/dev/null
    chmod -R 0775 /dev/stune 2>/dev/null
fi

# Hostname.
#
# jolla-common-configurations ships /etc/hostname containing the literal string
# "UNKNOWN" as a placeholder, expecting systemd-hostnamed to replace it. Here
# hostnamed SIGSEGVs inside libselinux's selabel_open() error path and never
# runs, so the placeholder sticks and every journal line is tagged UNKNOWN.
#
# This is done here rather than by shipping our own /etc/hostname because that
# path belongs to jolla-common-configurations, and a second package owning it
# would be an rpm file conflict at image build time.
#
# Only replace the known placeholder, so a hostname the user sets themselves is
# left alone.
if [ ! -s /etc/hostname ] || [ "$(cat /etc/hostname 2>/dev/null)" = "UNKNOWN" ]; then
    echo 'GalaxyNote10Plus' > /etc/hostname
fi
/bin/hostname -F /etc/hostname 2>/dev/null || \
    /bin/hostname "$(cat /etc/hostname)" 2>/dev/null

exit 0
