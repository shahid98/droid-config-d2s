#!/bin/sh
# Set up the audio routing that Samsung's HAL would normally do, using plain
# ALSA, because on this device that HAL can never be loaded.
#
# WHY THIS EXISTS
#
# The only real audio HAL here is /vendor/lib/hw/audio.primary.exynos9825.so
# and it ships 32-bit ONLY - as does /vendor/bin/hw/android.hardware.audio@
# 2.0-service. /vendor/lib64/hw/ holds nothing usable:
#
#   audio.primary.default.so       64-bit, 15 KB   AOSP stub, no implementation
#   audio.sec_primary.default.so   64-bit, 15 KB   Samsung shim, not an impl
#   audio.primary.exynos9825.so    32-bit, 123 KB  the real one, /vendor/lib/hw
#
# Sailfish's PulseAudio is 64-bit and cannot dlopen a 32-bit library, so
# module-droid-card could only ever reach the AOSP stub, which accepts audio
# and discards it. That is why the device was silent while PulseAudio looked
# perfectly healthy. It is also the EINVAL that looked unexplained for a long
# time: the Samsung shim loads the primary HAL, finds the stub instead of the
# Samsung one, logs "The audio hal does not support to samsung audio hal" and
# returns -EINVAL. It was right.
#
# None of that is fixable by configuration, so we skip the Android HAL and
# drive the codec directly. See tools/debug/ in the port tree for how the
# control list is generated from Samsung's own tables, and the audio section of
# STATUS-d2s-alpha.md for the full write-up.
#
# WHAT IT DOES
#
# Applies 189 mixer controls, flattened from
#   /vendor/etc/mixer_paths_r18.xml   (the initial block + media-dual-speaker)
#   /vendor/etc/mixer_gains_r18.xml   (gain-media-dual-speaker)
# which is exactly what the vendor HAL applies for media playback on both
# speakers. That routes ABOX SIFS0 to UAIF1 at 32 bit / 4 channel / 48 kHz and
# brings up both cs35l41 smart amps - the link carries two playback channels
# plus two feedback channels for speaker protection.
#
# The r18 variant is the correct one: which pair applies is selected by
# /proc/device-tree/sound/mixer-paths, and ro.revision on this handset is 24.
#
# Ordering inside the list matters. The initial block leaves SIFS0 at 24 bit /
# 2 channel and media-dual-speaker then raises it to 32 bit / 4 channel, so the
# controls must be applied top to bottom, not sorted or de-duplicated.

#
# Every *.tsv in $DIR is applied, in name order:
#   mixer-media-dual-speaker.tsv  playback -> both speakers (incl. initial block)
#   mixer-mic-main.tsv            built-in mic -> WDMA1 (hw:0,13)
# Lines starting with '#' are comments. Within a file, order is preserved.
#
# The file ORDER matters too: the speaker list starts with Samsung's initial
# block, which resets ABOX NSRC0=RESERVED and DMIC1 Switch=0. When the mic list
# was named mixer-main-mic.tsv it sorted first and was silently undone - PA's
# source opened and RUNNING, recording streams attached to it, and every file
# came back empty. Name any new list so it sorts after the speaker list.
DIR=/usr/share/droid-audio
LOG=/var/lib/hybris-fix/alsa-mixer.log
AMIXER=/usr/bin/amixer

mkdir -p /var/lib/hybris-fix 2>/dev/null
: > "$LOG"
log() { echo "$*" >> "$LOG"; }

[ -x "$AMIXER" ] || { log "no $AMIXER - is alsa-utils installed?"; exit 0; }
ls "$DIR"/*.tsv >/dev/null 2>&1 || { log "no control lists in $DIR"; exit 0; }

# The card is registered by the in-kernel Madera/ABOX driver, but the cs35l41
# amps load DSP firmware during probe, so give the card a moment to appear
# rather than assuming it is there the instant this unit runs.
i=0
while [ $i -lt 30 ]; do
    [ -e /dev/snd/controlC0 ] && break
    sleep 1
    i=$((i + 1))
done
[ -e /dev/snd/controlC0 ] || { log "no /dev/snd/controlC0 after ${i}s"; exit 0; }

TAB=$(printf '\t')
for TSV in "$DIR"/*.tsv; do
    OK=0
    FAIL=0
    while IFS="$TAB" read -r name val; do
        case "$name" in ''|'#'*) continue ;; esac
        if $AMIXER -q -c 0 cset name="$name" -- "$val" >/dev/null 2>&1; then
            OK=$((OK + 1))
        else
            FAIL=$((FAIL + 1))
            log "FAIL: $name = $val ($(basename "$TSV"))"
        fi
    done < "$TSV"
    log "$(basename "$TSV"): applied ok=$OK fail=$FAIL at $(cut -d. -f1 /proc/uptime)s uptime"
done
exit 0
