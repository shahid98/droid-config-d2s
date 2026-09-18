# Sailfish OS 5.1.0.11 for the Galaxy Note 10+ (SM-N975F) — community alpha

An unofficial port of Sailfish OS 5.1.0.11 "Pispala" to the Exynos Galaxy
Note 10+ (`d2s`), built on a hybris-18.1 (LineageOS 18.1 / Android 11) base.

**This is an alpha.** The phone works as a phone — calls, SMS, mobile data,
WiFi, camera, GPS — but there are real gaps, listed below. Installing wipes the
device, and there is no Android app support. Read the whole post before you
flash.

- **Model:** SM-N975F only (Exynos 9825). **Not** SM-N975U / N975W
  (Snapdragon) and **not** the N976 5G variants.
- **Release:** `sailfishos-d2s-release-5.1.0.11.zip`
- **sha256:** `34bf8c1c92513cd619669357d19bf94b3430770b7209fea40d1aac215d433581`

---

## What works

**Phone and data**
- Voice calls, with two-way audio through the earpiece (emergency calling
  reaches a dispatcher). The call audio path is set up by a service written for
  this port — Sailfish's usual route needs a 64-bit vendor HAL this phone does
  not have.
- SMS.
- Mobile data on LTE, including after a reboot. Your carrier's APN may need
  fixing by hand — see *After installing*.
- WiFi, with the correct MAC address.
- Bluetooth: powers on and finds devices.

**Screen and input**
- 1440 × 3040 display at full resolution, correct scaling, auto-rotation.
- Double-tap to wake.
- Proximity (the screen blanks against your ear), ambient light,
  accelerometer, gyroscope, magnetometer.
- The punch-hole camera is accounted for, so the status bar clock is not
  hidden behind it.

**Camera**
- Stills and video with sound, front and back.
- All three rear lenses are selectable in the camera app: **1.0** main (12 MP),
  **0.5** ultra-wide (16 MP) and **2.0** telephoto (12 MP). Samsung's camera
  service hides the telephoto from ordinary apps; this port asks for it
  explicitly.
- The front camera uses the full 10 MP sensor (4K video), not the cropped mode
  Android hands out first.
- 4K recording at a sensible bitrate (about 19 Mbit/s).

**Media**
- Hardware video decoding: 1080p and 1440p play smoothly in the browser, and
  VP9 works in third-party YouTube clients.
- Audio playback through the speakers, microphone recording, vibration.

**Location**
- GPS works, including assistance data so a fix does not take minutes every
  time. Indoors, a cold start took about two minutes and was accurate to 16 m;
  outdoors it is much quicker. **Location has to be switched on in Settings.**

**USB**
- **MTP** file transfer (measured about 60 MB/s writing, 34 MB/s reading).
- **Developer mode** (USB network + SSH).
- **Charging only.**

**Battery**
- Charge level and charging state are correct, and the phone idles properly —
  an earlier build kept one CPU core busy from boot; that is fixed.

---

## What does not work

- **No Android app support.** Jolla's Alien Dalvik is licensed only to
  officially supported devices. Waydroid is not included or tested; the kernel
  has what it needs, but nobody has run it yet.
- **Audio routing is fixed to the speakers.** Headphones, the earpiece for
  media, and Bluetooth audio are not switched automatically. Bluetooth
  connects, but it will not play your music.
- **The in-call volume slider does nothing**, and the in-call speaker button is
  not wired to the routing this port uses.
- **The fingerprint reader does not work** (Sailfish has no driver for this
  ultrasonic sensor).
- **NFC and the S-Pen are untested** — assume they do not work.
- **IPv6 on mobile data is not usable** (no default route); everything falls
  back to IPv4, which is fine in practice.
- **USB tethering is not included.**
- **4K60 video in the browser stutters slightly.** 1080p and 1440p are fine.
- **The boot splash is a still image, not an animation.** The Sailfish OS
  logo appears a few seconds after the Samsung logo and stays until the UI is
  up.

---

## Things worth knowing before you flash

- **Everything on the phone is erased**, including internal storage.
- **The base ROM matters.** This port is built against the vendor files of the
  unofficial LineageOS 18.1 build for d2s by *ivanmeler*. A different
  LineageOS build or a different stock firmware can bring back a black camera
  viewfinder, because the camera driver and the vendor camera library have to
  match.
- **There is a root shell over USB.** Like every hybris port, the phone runs a
  telnet debug shell on the USB network (192.168.2.15, port 2323) with no
  password. Anyone who can plug a PC into your phone has root. Keep that in
  mind before using this as a daily driver.
- **Developer tooling is included** in this build: USB defaults to developer
  mode, and the crash reporter collects dumps (they can grow to hundreds of
  MB — clear them in Settings if storage gets tight).

---

## Flashing

You need: a Linux or Windows PC, `adb`, and Heimdall (Linux) or Odin
(Windows). The bootloader must be unlocked (**OEM unlocking** in Android's
developer options, then unlock in download mode).

1. **Back up.** Everything will be wiped.
2. **Flash the stock firmware** the port was built against —
   `N975FXXS9HWG9` (Android 12) — with Heimdall or Odin. This step is what
   gives you a known-good modem and bootloader.
3. **Flash the LineageOS 18.1 build for d2s by ivanmeler**
   (`lineage-18.1-*-UNOFFICIAL-d2s.zip`) and its recovery. Boot it once to
   confirm the phone works, then go back to recovery.
4. **In recovery: Format data** (the option that types "yes", not just a wipe).
5. **Install Sailfish OS.** `adb sideload` of the zip is unreliable on this
   device — it stalls around 47% and writes nothing. The manual route works:

   ```sh
   # on the PC: unpack the release zip
   unzip sailfishos-d2s-release-5.1.0.11.zip -d sfos
   # recovery has no bzip2, so decompress the rootfs on the PC first
   bunzip2 sfos/sailfishos-d2s-release-5.1.0.11.tar.bz2

   # push both parts to the phone (in LineageOS recovery)
   adb push sfos/sailfishos-d2s-release-5.1.0.11.tar /data/sfos.tar
   adb push sfos/hybris-boot.img /data/hybris-boot.img

   # unpack the rootfs and write the boot image
   adb shell
     mkdir -p /data/.stowaways/sailfishos
     tar xvf /data/sfos.tar -C /data/.stowaways/sailfishos/
     dd if=/data/hybris-boot.img of=/dev/block/by-name/boot
     sync
     rm /data/sfos.tar /data/hybris-boot.img
     exit
   ```
6. **Reboot.** The Sailfish logo appears a few seconds in; the first boot then
   takes a few minutes to prepare the device before the welcome wizard shows.
   Later boots reach the homescreen in well under a minute.

---

## After installing

- **Mobile data:** if data does not come up, check the APN in
  *Settings → Mobile network → your SIM → Access Point Name*. Sailfish picks
  one from a public database and it is not always the right one (on Bell in
  Canada, for example, it chooses the tablet APN `inet.bell.ca` where phone
  plans need `pda.bell.ca`). **Reboot after changing it** — the APN is only
  sent to the modem when the telephony service starts.
- **GPS:** switch Location on in *Settings → Location*. It is off by default,
  and nothing will get a fix until it is on.
- **USB:** *Settings → USB* selects between MTP, developer mode and charging
  only.
- **Storage:** the crash reporter is included in this build. If you never
  intend to send logs anywhere, clear its reports occasionally.

---

## Reporting problems

Say what you did, what happened, and include:

- the exact model (`SM-N975F`) and which LineageOS build you flashed first,
- what the screen showed (the Sailfish logo, the welcome wizard, or nothing),
- for anything radio-related, your carrier and whether it was on WiFi, 4G or
  3G at the time.

---

## Credits

- **LineageOS** and *ivanmeler* for the unofficial 18.1 build for d2s, whose
  device, kernel and vendor trees this port is built on.
- **Jolla** for Sailfish OS and the HADK, and the **mer-hybris** project for
  the hybris tooling that makes ports like this possible.

The port's own changes live on `d2s-sailfish-port` branches: kernel fixes
(camera metadata layout, MTP SuperSpeed descriptors, vibrator firmware),
droidmedia fixes (recording bitrate, hardware decode), the camera service
patch that exposes the telephoto, the GPS assistance-data fix, and the device
configuration package.
