# d2s droid-configs sparse overlay

Device-specific `sparse/` overlay for the Sailfish OS 5.1.0.11 port to the
Samsung Galaxy Note 10+ (**d2s** / SM-N975F, Exynos 9825), built on
hybris-18.1 (LineageOS 18.1 / Android 11).

This directory is not itself a hybris-porting patch against an upstream
project — it's the new, device-specific content that
[hybris/droid-configs-device](https://github.com/mer-hybris/droid-hal-configs)
templates get overlaid with when `rpm/dhd/helpers/build_packages.sh -d`
assembles `hybris/droid-configs` during a HADK build. Everything under
[`sparse/`](sparse/) gets installed verbatim into the target image.

## What's in here

- **Audio** — the vendor Android audio HAL on this device is 32-bit only and
  can't be `dlopen()`'d by 64-bit PulseAudio, so audio is driven directly:
  ALSA mixer routing flattened from Samsung's own `mixer_paths_r18.xml`,
  a `module-alsa-sink`-based PulseAudio sink, mic capture/gain tuning, and an
  in-call audio bridge that drives the vendor HAL's `IPrimaryDevice` over
  binder to perform the CP-side call activation normally done through a rild
  socket this port is refused on.
- **Sensors & input** — a uinput bridge republishing proximity readings
  sensorfw's type-based dispatch can never see (the HAL tags them with a
  device-private sensor type), and a double-tap-to-wake bridge translating
  the touch panel's `KEY_WAKEUP` into the `KEY_POWER`-on-a-dbltap-class-device
  sequence mce actually needs.
- **Connectivity** — WiFi MAC provisioning before connman starts, a
  bluebinder restart workaround, and an ofono systemd drop-in that fixes a
  crash-handling foot-gun (`rich-core-dumper` + a piped `core_pattern` made a
  crash look exactly like a multi-minute D-Bus hang).
- **Boot plumbing** — binding the flattened APEXes and generating
  `/linkerconfig` before anything in init needs them, SELinux/vibrator
  permission fixups, and device identity strings.

See each commit message for the full root-cause writeup.

## Related repos

The rest of this port's patches live as branches on forks of the projects
they modify (kernel, droidmedia, hybris-boot, qt5-qpa-hwcomposer-plugin,
libhybris, droid-hal-configs, and various AOSP/LineageOS trees), each on a
branch named `d2s-sailfish-port`.

## License

New files in this repository are licensed under the GNU General Public
License v3.0 or later — see [LICENSE](LICENSE). This overlay contains no
code copied from the Android/hybris trees it's deployed alongside; it's
config files, systemd units and small standalone scripts written for this
port.
