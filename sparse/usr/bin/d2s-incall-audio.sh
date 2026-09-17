#!/bin/sh
# Switch the ALSA route to Samsung's in-call path while a call is up.
#
# WHY THIS EXISTS
#
# Calls connect and the modem is happy, but nobody can hear anything: there is
# no audio in either direction. On a stock device the Samsung audio HAL swaps
# the codec route when a call starts - and that HAL can never load here (it is
# 32-bit only; see droid-alsa-mixer.sh and tools/debug/README.md). Nothing else
# was switching the route, so the codec stayed wired for media playback.
#
# Voice audio on this SoC does NOT flow through an AP-side PCM. The CP talks to
# the ABOX DSP directly, and the DSP bridges it to the codec once the routing
# controls are set, which is why no pcm device has to be opened here. What is
# missing at boot is exactly Samsung's "incall_nb-*" path:
#
#   ABOX SPUM ASRC3/ASRC4 = 1        the CP <-> codec sample-rate bridge
#   ABOX Sound Type       = VOICE    tells the DSP which use case is running
#   dev-handset/dev-dual-speaker     amps to ASP with boost off (not DSP)
#   route-cp-tx-bridge               uplink: UAIF0 -> NSRC0/1/6 -> CP
#   dev-multi-mic                    3 mics (IN3R/IN4R/IN2R) instead of one
#
# The uplink bridge deliberately sets ABOX WDMA1_EN=On and VPCMIN_DAI0_EN=On,
# which is the opposite of what mixer-mic-main.tsv wants. That is correct: the
# DSP's voice pipeline owns WDMA1 during a call, so ordinary AP recording on
# hw:0,13 cannot work at the same time. Restoring the boot lists hands WDMA1
# back to the AP.
#
# WHAT IT DOES
#
# Watches ofono on the system bus. On CallAdded it applies the in-call list, on
# CallRemoved it re-applies the boot lists (media + mic), which restores the
# pre-call state exactly - mixer settings are volatile, so nothing persists.
#
# The earpiece is the default. To test the loudspeaker route instead:
#   echo dual-speaker > /var/lib/hybris-fix/incall-route
# Sailfish's in-call speaker toggle is not wired to this yet; that needs a
# proper PulseAudio route, and this file is the groundwork for it.

DIR=/usr/share/droid-audio
INCALL=$DIR/incall
AMIXER=/usr/bin/amixer
STATE=/var/lib/hybris-fix
LOG=$STATE/incall-audio.log

mkdir -p "$STATE" 2>/dev/null

log() {
    # Keep the log small; this runs for the life of the session.
    [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ] && : > "$LOG"
    echo "$(cut -d. -f1 /proc/uptime)s $*" >> "$LOG"
}

apply_tsv() {
    tsv="$1"
    [ -f "$tsv" ] || { log "missing list: $tsv"; return 1; }
    ok=0
    fail=0
    TAB=$(printf '\t')
    while IFS="$TAB" read -r name val; do
        case "$name" in ''|'#'*) continue ;; esac
        if $AMIXER -q -c 0 cset name="$name" -- "$val" >/dev/null 2>&1; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            log "FAIL: $name = $val ($(basename "$tsv"))"
        fi
    done < "$tsv"
    log "$(basename "$tsv"): ok=$ok fail=$fail"
}

call_route() {
    r=$(cat "$STATE/incall-route" 2>/dev/null)
    case "$r" in
        dual-speaker|handset) echo "$r" ;;
        *) echo handset ;;
    esac
}

# Routing the codec is only half of call audio: the CP also has to be told to
# start sending and receiving, which the vendor audio HAL does over rild's
# @VND_Multiclient socket when Android sets AUDIO_MODE_IN_CALL. Setting the
# "ABOX Audio Mode" mixer control here does NOT do that - it only tells the
# DSP. d2s-incall-cp-audio.py drives the HAL over HIDL instead, and must keep
# IPrimaryDevice open for the whole call, so it runs as a child process.
CP_HELPER=/usr/bin/d2s-incall-cp-audio.py
CP_PID=

cp_audio_start() {
    [ -x "$CP_HELPER" ] || { log "no $CP_HELPER - CP audio will not be enabled"; return; }
    [ -n "$CP_PID" ] && return
    # Pass the same route we are about to apply, so the HAL's own idea of the
    # output device matches the mixer path (earpiece 0x1, speaker 0x2).
    python3 "$CP_HELPER" in_call "--route=$(call_route)" >> "$LOG" 2>&1 &
    CP_PID=$!
    log "CP audio helper started (pid $CP_PID, route $(call_route))"
}

cp_audio_stop() {
    [ -n "$CP_PID" ] || return
    # SIGTERM, so the helper restores AUDIO_MODE_NORMAL before dropping the
    # device - that is what tears the CP path down cleanly.
    kill -TERM "$CP_PID" 2>/dev/null
    wait "$CP_PID" 2>/dev/null
    log "CP audio helper stopped (pid $CP_PID)"
    CP_PID=
}

call_start() {
    [ "$IN_CALL" = 1 ] && return
    IN_CALL=1
    log "call started - route: $(call_route)"
    # The HAL does ALL of it: codec route, setVoicePath to the CP, and opening
    # the CP voice PCMs ("*** Started CP Voice Call ***"). The mixer lists in
    # $INCALL are therefore NOT applied during a call any more - they would
    # fight the HAL's own routing. They are kept for reference and for
    # debugging without the HAL.
    cp_audio_start
}

# The HAL sometimes leaves the CP voice PCMs running after a call: pcm4p (RX),
# pcm14c (TX) and pcm19c (TX direct). It then reports "is not ready" on the
# next call and never closes them, and because they hold ABOX DMA channels,
# camera recording and video playback break until the HAL is restarted. Check
# and restart only if it actually happened.
release_voice_pcms() {
    leaked=
    for p in pcm4p pcm14c pcm16c pcm19c; do
        s=$(head -1 "/proc/asound/card0/$p/sub0/status" 2>/dev/null)
        [ -n "$s" ] && [ "$s" != closed ] && leaked="$leaked $p"
    done
    [ -z "$leaked" ] && return
    log "voice PCMs still open after the call:$leaked - restarting vendor.audio-hal-2-0"
    setprop ctl.restart vendor.audio-hal-2-0
    i=0
    while [ $i -lt 15 ]; do
        sleep 1
        i=$((i + 1))
        still=
        for p in $leaked; do
            s=$(head -1 "/proc/asound/card0/$p/sub0/status" 2>/dev/null)
            [ "$s" != closed ] && still="$still $p"
        done
        [ -z "$still" ] && break
    done
    log "after HAL restart, still open:${still:- none} (${i}s)"
}

call_end() {
    [ "$IN_CALL" = 1 ] || return
    IN_CALL=0
    cp_audio_stop
    release_voice_pcms
    log "call ended - restoring media + mic route"
    apply_tsv "$DIR/mixer-media-dual-speaker.tsv"
    apply_tsv "$DIR/mixer-mic-main.tsv"
}

[ -x "$AMIXER" ] || { log "no $AMIXER - is alsa-utils installed?"; exit 0; }

IN_CALL=0
log "watching ofono for calls (default route: $(call_route))"

# gdbus monitor emits one line per signal, e.g.
#   /ril_0: org.ofono.VoiceCallManager.CallAdded ('/ril_0/voicecall01', {...})
# CallAdded fires while the call is still dialling or ringing, which is the
# right moment: the route must be up before the audio starts flowing.
gdbus monitor --system --dest org.ofono 2>/dev/null | while read -r line; do
    case "$line" in
        *VoiceCallManager.CallAdded*)   call_start ;;
        *VoiceCallManager.CallRemoved*) call_end ;;
    esac
done

log "gdbus monitor exited"
exit 0
