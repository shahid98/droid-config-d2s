#!/bin/sh
# Let the Dialler place calls on a modem that reports no signal strength.
#
# WHY THIS EXISTS
#
# Every non-emergency call failed instantly with "No network coverage" while
# ofono was fully registered (verified on two SIMs: Jio roaming on TELUS, and
# Bell at home on LTE). The block is in the UI, before any daemon is contacted.
# /usr/share/voicecall-ui-jolla/AppVoiceCallManager.qml has:
#
#   property bool noNetwork: status != "registered" && status != "roaming" || strength === 0
#
# and isError() refuses to dial when registration.noNetwork is true. Everything
# else in that check is fine here - SIM present, no PIN, callingPermitted true
# (defaultuser is in the sailfish-phone group), offlineMode false, no MDM
# filter - so `strength === 0` was the only failing term.
#
# Strength is 0 because ofono's NetworkRegistration has no Strength property at
# all: the vendor RIL's signal-strength struct fails libril's size check on both
# paths, every time -
#
#   getSignalStrengthResponse_1_2: Invalid response   (34 of 34 requests)
#   currentSignalStrengthInd_1_2: invalid response    (200+ indications)
#
# because this Shannon 5000 RIL advertises `nr` and emits a larger NR-extended
# struct than RIL_SignalStrength_v8/v10, the only two sizes libril accepts in
# its indication path. That libril lives on the vendor partition from the
# LineageOS ROM, not in our build (ours is a different size entirely, and
# BOARD_PROVIDES_LIBRIL is set nowhere in device/samsung), so it cannot be
# fixed from this tree. Asking ofono for an older interface does not help
# either: radioInterface=1.1 and 1.0 were both measured, neither delivers a
# Strength.
#
# So the gate is dropped instead. Consequence: no signal-strength readout in
# the Dialler (the status bar is unaffected), and a genuinely out-of-coverage
# call attempt fails at the network instead of being refused up front. That is
# a better trade than a phone that cannot dial at all.
#
# WHAT IT DOES
#
# Removes the `|| strength === 0` term, idempotently, keeping one backup. The
# QML belongs to the voicecall-ui-jolla package, so a sparse file would clash
# with it on update; patching in place at boot is the least invasive option.
# If a Sailfish update rewrites the file, this simply patches it again.
#
# Revisit if ofono ever reports a real Strength - then drop this entirely.

Q=/usr/share/voicecall-ui-jolla/AppVoiceCallManager.qml
LOG=/var/lib/hybris-fix/voicecall-gate.log

mkdir -p /var/lib/hybris-fix 2>/dev/null
log() { echo "$(cut -d. -f1 /proc/uptime)s $*" >> "$LOG"; }

[ -f "$Q" ] || { log "no $Q - voicecall-ui not installed?"; exit 0; }

if ! grep -q 'strength === 0' "$Q"; then
    log "already patched (no strength gate present)"
    exit 0
fi

[ -f "$Q.orig-strength-gate" ] || cp -a "$Q" "$Q.orig-strength-gate"

if sed -i 's/ || strength === 0//' "$Q"; then
    if grep -q 'strength === 0' "$Q"; then
        log "FAILED: gate still present after sed"
        exit 0
    fi
    log "patched: $(grep -a 'property bool noNetwork' "$Q" | sed 's/^[[:space:]]*//')"
else
    log "FAILED: sed could not write $Q"
fi

exit 0
