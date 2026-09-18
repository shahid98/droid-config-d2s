#!/bin/sh
# Route audio to a Bluetooth headset when one connects.
#
# On this port nothing did that. module-droid-card is not loaded at all (the
# only real audio HAL is 32-bit - see /etc/pulse/arm_droid_card_custom.pa), and
# Sailfish's routing is built around it: module-policy-enforcement resolves
# devices through droid.* sink properties, so it has no idea what a bluez sink
# is. Media therefore stayed on the speaker with a headset connected and
# playing.
#
# Three things are needed, and all three are missing without this:
#
#   1. A card at all. default_sailfish.pa's stock `headset=droid` backend never
#      produced one; /etc/pulse/bluez5_discover_custom.pa switches that to
#      `native`, and PulseAudio then creates bluez_card.<addr> on connect.
#   2. An active profile. The card comes up with "Active Profile: off", so no
#      sink exists until something selects a2dp_sink.
#   3. The streams themselves. They must be moved to the new sink, and
#      **unmuted**: the policy leaves a stream muted when it is moved to a sink
#      it does not recognise, which looks exactly like a dead headset - the
#      transport is active, the sink is at 100%, and nothing plays.
#
# Only streams this script moves are unmuted, so a stream the user muted on
# purpose on the speaker stays muted there.
#
# Reverting needs no work: when the headset disconnects PulseAudio moves the
# streams off the vanishing sink by itself. This only puts the default back.

#
# It also caps Waydroid's playback stream. Waydroid talks to PulseAudio
# directly, so nothing in Sailfish's volume policy applies to it: it arrives at
# 95% of full scale and the cs35l41 amps clip, which sounds like the volume is
# stuck at 200% - crackling and distorted on the speaker whatever Android's own
# slider says. 45% was the level where it came back clean on this device, by
# ear, on the speaker and on a Bluetooth headset. Android's own volume control
# still works normally underneath it, and the phone's volume keys still move
# the sink, so this only removes headroom that was never usable.

PATH=/usr/bin:/bin:/usr/sbin:/sbin
SPEAKER=sink.primary-out
WAYDROID_MAX=45      # percent; above this the speaker amps clip

pa() { pactl "$@" 2>/dev/null; }

# Clamp Waydroid's stream, whichever sink it is on.
cap_waydroid() {
    pa list sink-inputs | awk -v max="$WAYDROID_MAX" '
        /^Sink Input #/ { id = substr($3, 2); vol = "" }
        /Volume: front-left/ { for (i = 1; i <= NF; i++) if ($i ~ /%$/) { vol = $i + 0; break } }
        /application.name = "Waydroid"/ { if (vol > max) print id }
    ' | while read -r id; do
        echo "capping Waydroid stream $id to ${WAYDROID_MAX}%"
        pa set-sink-input-volume "$id" "${WAYDROID_MAX}%"
    done
}

bt_card() { pa list cards short | awk '/bluez_card/ {print $2; exit}'; }

card_profile() {
    pa list cards | awk -v c="$1" '
        $1 == "Name:" && $2 == c { f = 1; next }
        f && $1 == "Active" && $2 == "Profile:" { print $3; exit }'
}

reroute() {
    cap_waydroid

    card=$(bt_card)
    if [ -z "$card" ]; then
        pa set-default-sink "$SPEAKER"
        return
    fi

    if [ "$(card_profile "$card")" = "off" ]; then
        echo "activating a2dp_sink on $card"
        pa set-card-profile "$card" a2dp_sink
        sleep 1
    fi

    idx=$(pa list sinks short | awk '/bluez_sink/ {print $1; exit}')
    name=$(pa list sinks short | awk '/bluez_sink/ {print $2; exit}')
    [ -z "$name" ] && return

    pa set-default-sink "$name"
    pa list sink-inputs short | while read -r id sink _rest; do
        [ "$sink" = "$idx" ] && continue
        echo "moving stream $id to $name"
        pa move-sink-input "$id" "$name" && pa set-sink-input-mute "$id" 0
    done
}

# Wait for PulseAudio: this starts with the user session and pactl is useless
# until the daemon is up.
i=0
while ! pa info >/dev/null 2>&1; do
    i=$((i + 1))
    [ $i -gt 60 ] && exit 1
    sleep 2
done

reroute

# Our own moves generate events, so debounce rather than reacting to each one.
pa subscribe | while read -r event; do
    case "$event" in
        *" on card"*|*" on sink "*|*" on sink#"*|*" on sink-input"*)
            sleep 1
            reroute
            ;;
    esac
done
