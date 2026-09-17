# These and other macros are documented in ../droid-configs-device/droid-configs.inc
# Feel free to cleanup this file by removing comments, once you have memorised them ;)

%define device d2s
%define vendor samsung

%define vendor_pretty Samsung
%define device_pretty Galaxy Note 10+

# Community HW adaptations need this
%define community_adaptation 1

# Pixel ratio 1.0 was originally jolla phone with 245ppi, and the devices
# should roughly have their ppi compared to that. Large displays can use
# bigger ratio if seen fit. Values are with 0.25 increments.
#
# d2s is 1440x3040 at ~498ppi, so 498/245 ~= 2.0 (same as Nexus 5).
# This macro drives three separate things, not just the theme scale:
#   - /etc/dconf/db/vendor.d/silica-configs.txt  @PIXEL_RATIO@ and @ICON_RES@
#   - /etc/xdg/QtProject/QPlatformTheme.conf     @START_DRAG_DISTANCE@ = ratio*20
# Leaving it at 1.0 and correcting only the dconf keys elsewhere still leaves
# start_drag_distance at 20px, which on this panel is half the intended
# physical distance and makes drags/flicks trigger far too easily.
#
# pixel_ratio also selects icon_res, and through it the
#   Requires: sailfish-content-graphics-z%{icon_res}
# in patterns-sailfish-device-configuration-d2s.inc. Silica sizes launcher
# icons from the icon set that is actually INSTALLED, not from the theme scale:
# an image built while this was still 1.0 got only the z1.0 graphics packages,
# and on-device Theme.iconSizeLauncher then stayed at 86 px while every other
# Theme value (fonts, paddings, iconSizeLarge...) scaled to 2.0 - tiny launcher
# icons in a 7-column grid. Raising the ratio to 2.5 did not help for the same
# reason. With z2.0 graphics installed at 2.0 the launcher gets 172 px icons.
%define pixel_ratio 2.0

# Base Android version. droid-configs.inc guards the per-version sparse trees
# with %%if 0%%{?android_version_major:1}, so without this NOTHING from
# droid-configs-device/sparse-11 is packaged - which silently dropped
# /usr/bin/droid/droid-hal-early-init.sh (the system-as-root, flattened-APEX
# and linkerconfig setup that droid-hal-init.service runs as ExecStartPre),
# droid-bootctl.sh, disabled_services.rc and ecclist.rc from the image, while
# the test device had them installed by hand. Found 2026-09-17 by diffing the
# built image against the running phone.
%define android_version_major 11

%include droid-configs-device/droid-configs.inc
%include patterns/patterns-sailfish-device-adaptation-d2s.inc
%include patterns/patterns-sailfish-device-configuration-d2s.inc

# IMPORTANT if you want to comment out any macros in your .spec, delete the %
# sign, otherwise they will remain defined! E.g.:
#define some_macro "I'll not be defined because I don't have % in front"

