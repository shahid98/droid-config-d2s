# Feel free to disable non-critical HA parts during devel by commenting lines out
# Generated in hadk by executing: rpm/dhd/helpers/add_new_device.sh

%package -n patterns-sailfish-device-adaptation-d2s
Summary: Jolla HW Adaptation d2s
Requires: droid-hal-d2s
Requires: droid-hal-d2s-img-boot
Requires: droid-hal-d2s-kernel-modules
Requires: droid-config-d2s-sailfish
Requires: droid-config-d2s-pulseaudio-settings
Requires: droid-config-d2s-policy-settings
Requires: droid-config-d2s-preinit-plugin
Requires: droid-config-d2s-flashing
Requires: droid-config-d2s-bluez5
Requires: droid-hal-version-d2s

# Bluetooth transport. droid-config-d2s-bluez5 only supplies BlueZ *config*;
# on a binderized base there is no kernel HCI transport at all, so bluetoothd
# finds zero adapters and Settings shows Bluetooth permanently off. bluebinder
# talks to android.hardware.bluetooth@1.0 over binder and presents the result
# as /dev/vhci, which is the hci0 BlueZ then attaches to. Nothing else pulls
# it in - it has to be requested explicitly.
Requires: bluebinder

# Hybris packages
Requires: libhybris-libEGL
Requires: libhybris-libGLESv2
Requires: libhybris-libwayland-egl

# Qt platform plugin. WITHOUT THIS THERE IS NO UI: lipstick is started with
# QT_QPA_PLATFORM=hwcomposer (set in
# /var/lib/environment/compositor/droid-hal-device.conf) and aborts if the
# plugin is missing. It is not pulled in by any other dependency because it is
# device-specific, so it has to be requested explicitly here.
Requires: qt5-qpa-hwcomposer-plugin

# Telephony. ofono-configs-binder gets pulled in indirectly and drops
# /etc/ofono/binder.conf + binder.d/ on the system, but nothing pulls in the
# plugin that reads them, so /usr/lib/ofono/plugins/ does not even exist.
# ofonod then starts clean, loads no modem driver at all (the log shows only
# "Excluding <builtin> driver" lines and no binder plugin init), and
# org.ofono.Manager.GetModems returns an empty array - no SIM, no signal, no
# calls - even though rild is running with libsec-ril.so.
Requires: ofono-binder-plugin

# Audio. This device gets its sound through plain ALSA rather than
# module-droid-card, because the only real audio HAL is 32-bit and PulseAudio
# is 64-bit (see sparse/etc/pulse/arm_droid_card_custom.pa). The routing that
# the vendor HAL would normally set up is applied by droid-alsa-mixer.service,
# which drives amixer, so alsa-utils has to be in the image - nothing else
# pulls it in.
Requires: alsa-utils

# Sensors
Requires: hybris-libsensorfw-qt5

# Vibra
Requires: ngfd-plugin-native-vibrator
Requires: libngf-qt5-qtfeedback

# Needed for /dev/touchscreen symlink
Requires: qt5-plugin-generic-evdev

# Kept for droid.pa and the PulseAudio droid plumbing, even though
# module-droid-card itself is never loaded on this device.
Requires: pulseaudio-modules-droid

# pulseaudio-modules-droid-hidl is deliberately NOT required here.
#
# It needs module-droid-card to have loaded a hw module, and this device has
# no usable droid card - its audio HAL is 32-bit while PulseAudio is 64-bit,
# so audio goes through plain ALSA (see sparse/etc/pulse/). Loading the module
# without a droid card does not merely fail, it aborts the daemon:
#   module-droid-hidl.c: Couldn't get hw module functions...
#   protocol-dbus.c: Assertion 'p' failed ... Aborting.
# which crash-looped PulseAudio with the working ALSA sink already created.
# The module has no use here anyway: it only forwards set_parameters() out of
# PulseAudio to a droid hw module that does not exist.
#Requires: pulseaudio-modules-droid-hidl

# The -dummy-af is needed for newer devices that run the main
# audiosystem-passthrough in qti mode (e.g. >=Android 9 Qualcomm),
# to fix non-responding Camera app and/or voice during a phone call:
#Requires: audiosystem-passthrough-dummy-af

# for audio recording to work:
Requires: qt5-qtmultimedia-plugin-mediaservice-gstmediacapture

# These need to be per-device due to differing backends (fbdev, eglfs, hwc, ..?)
Requires: qt5-qtwayland-wayland_egl
Requires: qtscenegraph-adaptation

# For hybris devices with droidmedia, see HADK pdf for more information
Requires: gstreamer1.0-droid
Obsoletes: gmp-droid

# This is needed for notification LEDs
Requires: mce-plugin-libhybris

# USB mode controller
Requires: usb-moded

# hammerhead, grouper, and maguro use this in scripts, so include for all
Requires: rfkill

# enable device lock and allow to select untrusted software.
#
# sailfish-devicelock-fpd instead of jolla-devicelock-daemon-encsfa: the two
# conflict, and the fpd variant is the same encsfa daemon *with* fingerprint
# support (the unit it installs is sailfish-devicelock-encsfa-fpd.service), so
# nothing is given up by using it. Without it the fingerprint sensor works at
# the daemon level but Settings never offers to enrol one.
Requires: sailfish-devicelock-fpd

# Fingerprint: this phone's ultrasonic sensor (Qualcomm qbt2000) works under
# Sailfish through sailfish-fpd-community, which speaks the same D-Bus API as
# Jolla's closed sailfish-fpd and talks to the hardware through the AOSP
# android.hardware.biometrics.fingerprint@2.1 HIDL interface - which Samsung's
# own service registers alongside its vendor 3.0 one. droid-biometry-fp carries
# both the libbiometry_fp_api glue and that HIDL client library, because
# LineageOS does not ship the latter. Verified on device: enrolment reached
# progress 1.0 and authentication matched the finger.
Requires: sailfish-fpd-community
Requires: droid-biometry-fp

# Enable home encryption
#Requires: sailfish-device-encryption

# For GPS
Requires: geoclue-provider-hybris

# For FM radio on some QCOM devices
#Requires: qt5-qtmultimedia-plugin-mediaservice-irisradio
#Requires: jolla-mediaplayer-radio

# NFC support
# 1. binder plugin requires Android 8 or a newer base
# 2. pn54x plugin talks directly to pn54x driver
# These plugins are mutually exclusive, you need to pick one:
#Requires: nfcd-binder-plugin
#Requires: nfcd-pn54x-plugin

%description -n patterns-sailfish-device-adaptation-d2s
Pattern with packages for d2s HW Adaptation

%files -n patterns-sailfish-device-adaptation-d2s
