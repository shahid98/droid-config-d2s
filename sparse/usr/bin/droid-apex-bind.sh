#!/bin/sh
# Invoked from `on early-init` in the hybris init.rc.
#
# It MUST run from inside init, not from a systemd unit beforehand: init.cpp
# mounts an empty tmpfs over BOTH /apex and /linkerconfig in SecondStageMain
# (the hybris patches comment out most CHECKCALLs there but not those), which
# hides anything bind-mounted earlier. Everything below is layered on top.
#
# init's PATH has no /usr/bin, so use absolute paths throughout.
B=/usr/bin/busybox

# 1. Flattened APEX.
# ro.apex.updatable=false here, so apexd exits without doing anything, and
# init's ActivateFlattenedApexesIfPossible() is compiled out by
# DISABLED_FOR_HYBRIS_SUPPORT. Without this /apex stays empty and every
# dynamically linked Android binary fails execv with ENOENT, because its ELF
# interpreter is /apex/com.android.runtime/bin/linker64.
#
# Mount under the name from apex_manifest.pb, not the directory name:
# com.android.vndk.current declares com.android.vndk.v30, and linkerconfig
# needs /apex/com.android.vndk.v30/etc/llndk.libraries.30.txt or it aborts with
#   Check failed: !"undefined var" LLNDK_LIBRARIES_VENDOR is not defined
for apex in /system/apex/*/; do
    [ -d "$apex" ] || continue
    dir=$($B basename "$apex")
    # NOTE: busybox has no "strings" applet - use the real binutils one,
    # otherwise this silently returns empty and the fallback picks the
    # directory name, which is wrong for the VNDK apex.
    name=$(/usr/bin/strings "$apex/apex_manifest.pb" 2>/dev/null | $B head -1)
    case "$name" in
        com.android.*) ;;
        *) name=${dir%.release} ;;
    esac
    [ -e "/apex/$name/etc" ] && continue
    $B mkdir -p "/apex/$name"
    /bin/mount --bind "$apex" "/apex/$name"
done

# 2. Full linker config.
# droid-hal ships linkerconfig.mount, and init.rc only generates the *bootstrap*
# config (linkerconfig --target /linkerconfig/bootstrap). Without the full
# ld.config.txt, binaries exec fine but cannot resolve libraries that live
# inside the apexes, e.g.
#   CANNOT LINK EXECUTABLE "/system/bin/lmkd":
#   library "libstatssocket.so" not found
# Generate it here: we run inside init, so the property service is already up
# and linkerconfig can read ro.vndk.version (running it earlier, from a systemd
# unit, aborts with "VENDOR_VNDK_VERSION is not defined").
if [ ! -e /linkerconfig/ld.config.txt ] && [ -x /system/bin/linkerconfig ]; then
    /system/bin/linkerconfig --target /linkerconfig
fi

# 2b. Teach the linker about the droid-hybris bin directory.
#
# ld.config.txt selects which config section (and therefore which namespaces)
# an executable gets by matching its path against the "dir.<section>" entries.
# linkerconfig only ever emits Android's own paths:
#   dir.system = /system/bin/ , /system/xbin/ , /system/system_ext/bin/ , ...
#   dir.vendor = /odm/bin/ , /vendor/bin/ , /data/...
# Binaries shipped by droidmedia live under /usr/libexec/droid-hybris/system/bin
# and match NONE of them, so bionic falls back to a config with no additional
# namespaces at all. The system section links the default namespace to the ART
# apex and imports libandroidicu.so from it:
#   namespace.default.link.com_android_art.shared_libs = libandroidicu.so
# but the fallback has no such link, so minimediaservice died at startup with
#   CANNOT LINK EXECUTABLE ".../minimediaservice":
#   library "libandroidicu.so" not found: needed by /system/lib/libmedia.so
# (libandroidicu.so lives in the ART apex on this base - com.android.i18n ships
# only etc/icu here, no lib/ or lib64/ at all).
#
# droid-hal-init respawns minimedia/minisf every 5s, so this showed up as an
# endless "Service 'minimedia' exited with status 1" loop, no droidmedia, and
# a camera that could never start.
#
# Map that directory to the system section so those binaries get the same
# namespaces as any other /system/bin executable.
# Prepend by rewriting rather than `sed -i`: busybox sed's insert command has
# fussier syntax than GNU sed's, and this runs too early to debug comfortably.
#
# The chmod is NOT optional. linkerconfig writes ld.config.txt world-readable,
# and it has to stay that way: minimedia runs as user "media" (see the rc in
# droidmedia), and the linker reads this file as that user. Recreating it here
# gives it the shell's umask - 0600 - and then the linker cannot read it:
#   WARNING: linker: couldn't read "/linkerconfig/ld.config.txt" ...
#   error reading file ...: Permission denied
# It silently falls back to the default configuration, which has no namespaces,
# and we are back to the exact libandroidicu.so failure this block exists to
# prevent - but only for non-root services, so it still works when tested by
# hand as root.
if [ -e /linkerconfig/ld.config.txt ] && \
   ! $B grep -q 'droid-hybris' /linkerconfig/ld.config.txt; then
    {
        echo 'dir.system = /usr/libexec/droid-hybris/system/bin/'
        $B cat /linkerconfig/ld.config.txt
    } > /linkerconfig/ld.config.txt.new && \
    $B chmod 0644 /linkerconfig/ld.config.txt.new && \
    $B mv /linkerconfig/ld.config.txt.new /linkerconfig/ld.config.txt
fi

# 2c. Make the ART apex's ICU libraries reachable by libhybris.
#
# Same missing library as 2b, but a different consumer and a different fix.
# 2b covers real Android executables, which the bionic linker resolves using
# the dir.<section> entries in ld.config.txt. libhybris does NOT use that
# mechanism: when a *glibc* process (gst-inspect, jolla-camera, ...) pulls in
# an Android .so, hybris resolves it from its own search path, so adding a
# dir.system entry for /usr does nothing at all - verified on device.
#
# The result was that /usr/lib64/gstreamer-1.0/libgstdroid.so failed to load:
#   attempt to load plugin ".../libgstdroid.so"
#   library "libandroidicu.so" not found
#   Aborted (core dumped)
# GStreamer then blacklisted the plugin, droidcamsrc never registered, and
# jolla-camera reported "No front camera detected" and fell back to
# videotestsrc - which is why the viewfinder showed SMPTE colour bars with an
# animating noise block on BOTH cameras, and why nothing camera-related ever
# appeared in logcat: the Android camera stack was never reached.
#
# libdroidmedia.so lives in the droid-hybris lib dir, which hybris does search,
# so linking the ICU libraries in beside it is enough. Symlinks are fine even
# though /apex is mounted above - they resolve when used, not when created.
HYBLIB=/usr/libexec/droid-hybris/system/lib64
if [ -d "$HYBLIB" ]; then
    for l in libandroidicu.so libicuuc.so libicui18n.so libicu_jni.so; do
        [ -e "$HYBLIB/$l" ] || \
            /bin/ln -sf "/apex/com.android.art/lib64/$l" "$HYBLIB/$l"
    done
fi

# 3. Android's lmkd expects the memory cgroup at /dev/memcg; systemd mounts it
# at /sys/fs/cgroup/memory instead.
if [ ! -e /dev/memcg/memory.stat ] && [ -e /sys/fs/cgroup/memory/memory.stat ]; then
    $B mkdir -p /dev/memcg
    /bin/mount --bind /sys/fs/cgroup/memory /dev/memcg
fi

exit 0
