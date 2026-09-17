# Sailfish OS for the Samsung Galaxy Note 10+ (d2s)

Sailfish OS 5.1.0.11, built on hybris-18.1 (LineageOS 18.1 / Android 11),
running on the Samsung Galaxy Note 10+ (**d2s**, SM-N975F, Exynos 9825/9820).

This repo holds the device-specific `sparse/` overlay — the systemd units,
scripts and mixer/config files written for this port that don't exist
anywhere upstream. The rest of the patches (kernel, droidmedia, libhybris,
the hwcomposer plugin, droid-hal-configs, and a handful of AOSP/LineageOS
trees) live as `d2s-sailfish-port` branches on forks of the projects they
modify — see [Source layout](#source-layout) below.

Status as of 2026-09-17.

## Status

| Area | State |
|---|---|
| Boot to UI, display, touch | Working |
| Audio playback (speakers) | Working — bypasses the Android HAL, drives ALSA directly |
| Telephony (SIM, registration, SMS) | Working |
| In-call audio | Route implemented, calls connect, **not yet confirmed by ear on a live call** |
| Sensors (accel/gyro/magnetometer/rotation) | Working |
| Proximity | Working |
| Double-tap to wake | Working |
| WiFi | Working |
| Bluetooth | Working (power-on, scanning, pairing) |
| USB (MTP / developer / charging) | Working |
| Battery / charging | Working |
| Vibration | Working |
| Microphone | Working |
| Camera (stills + video) | Working, including 4K recording at a real bitrate |
| GPS | Stack initializes; position fix untested |
| NFC / S-Pen | Untested |

## Notable fixes

A few of the root causes were non-obvious enough to be worth calling out
here; see individual commit messages (in this repo and the forks below) for
the full writeup on each.

- **Audio is silent through the Android HAL because it's 32-bit-only.**
  `/vendor/lib64/hw/` carries only an AOSP stub and a Samsung shim — the real
  `audio.primary.exynos9825.so` exists only in `/vendor/lib/hw/` (32-bit).
  Sailfish's PulseAudio is 64-bit and can't `dlopen()` it, so the HAL path
  silently discarded audio while reporting success. Fixed by driving ALSA
  directly (`hw:0,1`, not the obvious `hw:0,0` — the Calliope DSP accepts
  writes to RDMA0 and never signals them back) with mixer routing flattened
  straight out of Samsung's own `mixer_paths_r18.xml`.
- **Black camera viewfinder from a 40-byte kernel/HAL ABI mismatch.** The
  LineageOS kernel tree carries a newer `camera2_shot_ext` layout than the
  stock vendor camera HAL installed on this device expects, so the kernel
  read the HAL's shot magic 40 bytes off and rejected every frame. Fixed by
  restoring the stock struct layout to match the vendor blob.
- **Proximity never reached mce** because the HAL tags proximity events with
  a Samsung device-private sensor type (65592) instead of the standard type
  sensorfw dispatches on. A small uinput bridge republishes the raw sysfs
  reading as a normal evdev proximity device instead.
- **A CPU core was pinned at ~800 mA from boot** by the compositor's HWC
  thread busy-polling a vsync interrupt this SoC's HWC never actually
  raises. Fixed in `qt5-qpa-hwcomposer-plugin` with two env-gated changes: a
  configurable vsync-timeout fallback, and disabling the HWC vsync
  enable/disable calls entirely once a timer is doing the pacing instead.
- **In-call audio** needs no AP-side PCM at all on this SoC — the modem
  talks to the ABOX DSP directly — so the missing piece wasn't a mixer
  route, it was the CP-side call activation normally done over a rild
  socket this port has no access to. Solved by driving the (32-bit,
  hwbinder-hosted) vendor audio HAL's `IPrimaryDevice` over binder instead,
  from a 64-bit client — the HAL's own bitness only ever stopped PulseAudio
  from `dlopen()`-ing it in-process, and is irrelevant to a binder caller.
- **MTP was invisible to every host** because buteo-mtp only supplies
  full-/high-speed USB descriptors, and this phone's DWC3 controller always
  links at SuperSpeed — a FunctionFS function with no SuperSpeed descriptors
  is silently dropped from the gadget configuration. The kernel's
  `f_fs.c` now synthesizes a SuperSpeed descriptor set from the high-speed
  one.

## Source layout

Every listed fork carries its patches on a branch named `d2s-sailfish-port`.

| Repo | Local path in a HADK tree | What it carries |
|---|---|---|
| [droid-hal-configs](https://github.com/mer-hybris/droid-hal-configs) (fork) | `hybris/droid-configs/droid-configs-device` | ofono slot config, sensorfw proximity adaptor, compositor vsync env vars |
| [android_kernel_samsung_exynos9820](https://github.com/LineageOS/android_kernel_samsung_exynos9820) (fork) | `kernel/samsung/exynos9820` | camera ABI fix, USB SuperSpeed descriptors, Bluetooth/WiFi driver fixes, defconfig (Bluetooth, USB mass storage, vibrator firmware, Waydroid prep) |
| [droidmedia](https://github.com/sailfishos/droidmedia) (fork) | `external/droidmedia` | encoder bitrate/profile derivation, recording buffer-starvation and decoder buffer-pool fixes, AAC csd-0 rebuild |
| [qt5-qpa-hwcomposer-plugin](https://github.com/mer-hybris/qt5-qpa-hwcomposer-plugin) (fork) | `hybris/mw/qt5-qpa-hwcomposer-plugin` | configurable vsync timeout / disabling HWC vsync toggling, GLES3 header build fix |
| [hybris-boot](https://github.com/mer-hybris/hybris-boot) (fork) | `hybris/hybris-boot` | USB gadget backend detection, d2s by-name partition mapping |
| [libhybris](https://github.com/mer-hybris/libhybris) (fork) | `external/libhybris` | RPM packaging (debug/trace always on) |
| [libhybris-1](https://github.com/mlehtima/libhybris-1) (fork) | `external/libhybris/libhybris` | HWC2 null-buffer slot re-present crash fix, RELR relocation tag fix |
| [android_system_core](https://github.com/LineageOS/android_system_core) (fork) | `system/core` | early APEX bind + linkerconfig, stop blocking boot on apexd |
| [android_build](https://github.com/LineageOS/android_build) (fork) | `build/make` | fs_config_generator Python 3 port |
| [android_hardware_samsung](https://github.com/LineageOS/android_hardware_samsung) (fork) | `hardware/samsung` | disable AdvancedDisplay (needs LineageOS Settings) |
| [android_external_p7zip](https://github.com/LineageOS/android_external_p7zip) (fork) | `external/p7zip` | disable build (link failure, unused) |
| [android_vendor_lineage](https://github.com/LineageOS/android_vendor_lineage) (fork) | `vendor/lineage` | drop 7z/lib7z packages to match |

## Prerequisites

This port targets the **LineageOS 18.1 build for d2s by ivanmeler** (XDA),
running the stock `N975FXXS6DTI5` vendor partition. The kernel's camera
driver was matched byte-for-byte to that vendor's camera HAL — a different
`/vendor` will likely bring back the black-viewfinder bug described above.
Flash that ROM (and don't swap `/vendor` afterwards) before building or
flashing this port.

## Building

Standard HADK / hybris-18.1 workflow (see the
[HADK PDF](https://sailfishos.org/wiki/Hybris_Adaptation_Development_Kit_HADK)
and [Community porting docs](https://github.com/sailfishos-community/community-docs)).
Point your `.repo/local_manifests` at the forks above on the
`d2s-sailfish-port` branch in place of their default revisions, and drop
this repo's `sparse/` tree into `hybris/droid-configs/sparse` before running
`build_packages.sh -d -c`.

## Known issues / help wanted

- In-call audio: the route applies and calls connect, but audio has not
  been confirmed audible on a live call (blocked on a SIM with an active
  plan for outbound test calls).
- GPS position fix is untested (stack initializes correctly).
- NFC and S-Pen are untested.
- ofono can SEGV during SIM init after rapid `systemctl restart ofono`
  cycles exhaust the modem's logical channels; harmless in normal use.

Issues and PRs against any of the repos above are welcome.

## License

New files in this repository (everything under `sparse/`) are licensed
under the GNU General Public License v3.0 or later — see [LICENSE](LICENSE).
Patches carried on forks of other projects retain that project's own
license (GPLv2 for the Linux kernel, Apache-2.0 for most AOSP/LineageOS
trees, etc.) — see each fork's own LICENSE/COPYING file.

## Credits

Built on the work of the [SailfishOS community](https://sailfishos.org/wiki/Community),
[mer-hybris](https://github.com/mer-hybris) and [LineageOS](https://lineageos.org/),
and on **ivanmeler**'s LineageOS 18.1 build for d2s on XDA, which this port
uses as its base ROM and vendor partition.
