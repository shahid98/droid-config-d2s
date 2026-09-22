# Waydroid on d2s (Galaxy Note 10+, Sailfish OS 5.1.0.11)

Waydroid 1.4.3 runs an archived LineageOS 18.1 (Android 11) system image on the
HALIUM_11 vendor shim. This matching system/vendor pair keeps shared storage
and the camera working; the current upstream Android 13 image does not. The
setup defaults to the Android 11 GApps image so Play services and FCM work.

Set it up on a freshly flashed phone with:

    devel-su /usr/bin/d2s-waydroid-setup.sh

Pass `--vanilla` only if an image without Google services is wanted. Re-running
the script with a different image type replaces the system image and forces
Waydroid to reinitialise instead of silently retaining the old image.

That script is the executable version of this document. Everything else here is
why it does what it does, and what to check when something breaks.

---

## What the image already provides

The kernel side is in the port, so a clean flash needs no kernel work:

| Kernel option | Why |
|---|---|
| `CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder,anbox-binder,anbox-hwbinder,anbox-vndbinder"` | The container needs its **own** binder domain. `/dev/binder` belongs to the phone's own Android HALs (camera, sensors, telephony); a second Android system on the same nodes would fight them. Waydroid looks for `anbox-binder` **before** plain `binder` on non-mainline devices, so it finds these and leaves the host's alone. |
| `CONFIG_ASHMEM=y` | Android shared memory; Waydroid refuses to start without `/dev/ashmem`. |
| `CONFIG_NETFILTER_XT_TARGET_CHECKSUM=y` | Added for Waydroid (2026-09-18). Its `waydroid-net.sh` ends with an iptables `CHECKSUM --checksum-fill` rule for DHCP; without the target that rule fails, the script returns non-zero, and **the container never starts** — the visible symptom is `Failed to setup waydroid-net` and a session that stays `STOPPED`. |
| `CONFIG_VETH`, `CONFIG_BRIDGE`, `CONFIG_IP_NF_TARGET_MASQUERADE`, `CONFIG_FUSE_FS`, `CONFIG_SQUASHFS`, `CONFIG_BLK_DEV_LOOP`, the namespace and cgroup options | Standard LXC/Waydroid requirements; all were already set. |

Cross-checked against the nabu port (`sailfish-on-nabu/android_kernel_xiaomi_nabu`,
`nabu_user_defconfig`), which enables the same set. Two things they have that we
do not, neither of which is needed here:

- `CONFIG_ANDROID_BINDERFS=y` — lets Waydroid *create* binder nodes on demand
  instead of relying on static ones. With the static `anbox-*` nodes we do not
  need it, but it is the more future-proof option if the kernel is touched again.
- The `puddlejumper` node names — Waydroid's newer naming for the same idea. It
  searches `anbox-binder` first, so ours are found.

Their `droid-config-nabu` ships **no** Waydroid files at all, i.e. the userspace
side there is also "install the Chum packages and run `waydroid init`". This
port follows the same shape, with the setup script to make it one command.

## What the setup script does, and why

1. **Verifies the kernel side** — the three `anbox-*` nodes, `/dev/ashmem`, and
   that an iptables CHECKSUM rule can actually be added. Failing here early is
   much clearer than Waydroid's "Failed to setup waydroid-net" later.
2. **Adds the Chum repository** (`sailfishos:/chum/5.1_aarch64`). Waydroid for
   Sailfish lives there; `lxc` itself comes from Jolla's own repo (6.0.3),
   because Jolla ships LXC for their own Android App Support.
3. **Installs** `waydroid`, `waydroid-settings`, `waydroid-sensors`,
   `waydroid-gbinder-config-hybris`, `waydroid-runner`, `python3-gbinder`,
   `dnsmasq`, `lxc`.

   The setup script refreshes Chum specifically, not every configured
   repository. A root SSH session cannot obtain the Jolla Store credential
   from the user's session bus; a blanket `zypper refresh` otherwise aborts
   with `Store credentials not received` even though Waydroid comes from Chum.
4. **Disables the system-wide dnsmasq.** The package enables a resolver that
   binds `0.0.0.0:53`. Waydroid starts its own dnsmasq bound to the container
   bridge and it then cannot bind — `failed to create listening socket for
   192.168.240.1: Address already in use` — and the container does not start.
5. **Hides the second launcher icon.** Two icons named "Waydroid" get
   installed:
   - `waydroid.desktop` runs `waydroid show-full-ui`, which connects straight to
     lipstick. Android renders and you see the launcher, but **lipstick routes
     no touch to that surface**, so it looks frozen. This one is hidden.
   - `waydroid-runner.desktop` is the Sailfish app to use. It is a Silica app
     that runs its **own nested Wayland compositor** (it links
     `libQt5Compositor`), so it receives touch like any other app and forwards
     it to the container. In its log you will see
     `Current Wayland socket: "../../display/wayland-3"` — that is the nested
     one, not lipstick's.
6. **Installs Android 11 GApps and runs `waydroid init`**, which downloads
   about 850 MB. It detects
   `vendor_type = HALIUM_11` from `ro.vndk.version=30` and writes
   `binder = anbox-binder` (and the vnd/hw equivalents) into
   `/var/lib/waydroid/waydroid.cfg` on its own.

Then open the **Waydroid** app. First start takes about a minute.

## State on this port

| Area | State | Notes |
|---|---|---|
| Container boot | Working | Verified 2026-09-21 with the GApps image: `sys.boot_completed=1`, Android 11 (SDK 30), Google Play Store / Play services / GSF installed. |
| Touch, keyboard | Working | Through `waydroid-runner`'s nested compositor. Inside the container the devices are `/dev/input/wl_touch_events`, `wl_pointer_events`, `wl_keyboard_events`. |
| Browser, general apps | Working | |
| Networking | Working | `waydroid0` bridge, container at 192.168.240.112 in the verification run, NAT to the phone's connection; direct Internet ping succeeded. |
| Sensors | Bridged | `waydroid-sensord` runs on the **host** against `/dev/anbox-hwbinder` and registers `android.hardware.sensors@1.0` into the container. This is the pattern any other host HAL would have to follow. |
| Shared storage (Gallery, Documents, `/storage/emulated/0`) | Working **on the Android 11 image** | A file written to `/sdcard/Download` was immediately visible at `~/.local/share/waydroid/data/media/0/Download` on the host. Broken on the stock Android 13 image - see "The system image matters" below. |
| Camera | Working on Android 11, **but never select 4K** | Photos and preview work from the container on the Android 11 image (5 devices enumerated). Setting video quality to **UHD 4K kills the container's camera provider**: the HAL returns error 3, `vendor.camera-provider-2-4` goes to `stopped`, `Number of camera devices` drops to 0, and every subsequent open fails with "Can't connect to the camera". It does **not** recover - `ctl.start`/`ctl.restart` and even a full session restart leave it at `getProviderImpl: camera provider init failed!`, so a phone reboot is needed. Keep Waydroid's video at 1080p; the phone's own camera does 4K fine. |
| GPS | Working, via Play services | There is no GNSS HAL in the container and Android 11's `cmd location` has no test-provider commands, so nothing feeds the `gps` provider - but with GApps installed, Play services' network location is enough for Maps to place the device. A real GNSS bridge (a host process registering `android.hardware.gnss` on `/dev/anbox-hwbinder`, the pattern `waydroid-sensord` uses) would be needed for a true fix. |
| Notifications | Working, bridged | Waydroid bridges the clipboard but not notifications. `d2s-waydroid-notify.service` polls `dumpsys notification` and re-posts new ones to the host's `org.freedesktop.Notifications`, so Android notifications reach the Sailfish events view - for every app, not just messengers. See `usr/bin/d2s-waydroid-notify.py` for the limits of that approach. |
| WhatsApp voice calls | Working | Two-way, with the microphone. |
| Audio out | Working, capped to the clean range | Waydroid talks to PulseAudio directly. Android's stock 0..15 media range overdrives this port's fixed speaker path; the upper steps clip and crackle as if volume were at 200%. The setup script now writes `ro.config.media_vol_steps=11` to `waydroid_base.prop`, so AudioService, Android's slider, and volume keys all use 0..11. This supersedes the ineffective old `settings put system volume_music 11`: the active device-specific key was `volume_music_speaker=15`, and the running service still exposed a maximum of 15. Verified live after a container restart: `STREAM_MUSIC Max: 11`, current 11, and an attempt to set 15 is rejected as outside `[0..11]`. Do **not** cap the PulseAudio stream: `module-stream-restore-nemo` keys it by the shared `x-maemo` role and would also lower native Sailfish media. |
| Microphone | Working | Confirmed in the container and during a WhatsApp call. It needs `droid-alsa-mixer.service` to have applied Samsung's mic route - that service was silently failing on every boot (`203/EXEC`, a missing executable bit in the package) and the mic recorded silence until it was fixed. Gain is now `IN3R Digital Volume` 191. |
| Battery level | **Wrong, and not ours** | The container reads the real battery fine (`/sys/class/power_supply/battery/capacity` is correct inside it), but `dumpsys battery` reports level 85, voltage 3600, temperature 350 - hardcoded stubs in Waydroid's own `android.hardware.health@2.0-service.waydroid`, which never reads the host. Only a patched vendor image or a host bridge (as `waydroid-sensord` does for sensors) would fix it. |
| WiFi | Shows nothing, by design | The container's active network is **Ethernet** (`eth0` on the `waydroid0` bridge); it has no WiFi hardware, so the WiFi screen is always empty. Apps see a connected network and work. `persist.waydroid.fake_wifi` makes named apps believe they are on WiFi, for apps that refuse to act otherwise. |

### The system image matters: use Android 11, not the stock Android 13

`waydroid init` downloads the current LineageOS **20** image (Android 13) and
pairs it with the **HALIUM_11** vendor shim, i.e. an Android 13 system on an
Android 11 vendor. Two things break on that combination, and both work when the
system image matches the vendor:

| | Android 13 (lineage-20, the default) | Android 11 (lineage-18.1) |
|---|---|---|
| `/storage/emulated/0` | empty, no FUSE mount ever appears | the real Android tree, FUSE mounted, sdcardfs on `Android/data` |
| MediaProvider | killed and restarted forever (4 s, 16 s, 64 s backoff); Gallery and Documents hang | zero crashes |
| Cameras seen by `dumpsys media.camera` | 0 | 5 |

On Android 13 `vold` logged `Mounting emulated fuse volume`, then 20 s later
`StorageSessionController: Failed to start session ... UpperPath:
/storage/emulated LowerPath: /data/media`, then
`Timeout executing service ... ExternalStorageServiceImpl`. `/dev/fuse` was
present, `CONFIG_FUSE_FS=y`, the kernel carries the Android FUSE extensions
(`FUSE_CANONICAL_PATH`), and `persist.sys.fuse=false` changed nothing (Android
13 ignores it) - the FUSE daemon simply hung before logging anything. Android 13
made FUSE-based MediaProvider mandatory; Android 11 still works with the
`sdcardfs` this 4.14 Samsung kernel implements.

Upstream only serves lineage-20 now, so the 18.1 image comes from the archive:

    https://sourceforge.net/projects/waydroid/files/images/system/lineage/waydroid_arm64/
    lineage-18.1-20250628-VANILLA-waydroid_arm64-system.zip   (or -GAPPS-)

Swapping it in by hand, if `waydroid init` has already run:

    waydroid session stop
    mv /var/lib/waydroid/images/system.img /var/lib/waydroid/images/system.img.a13
    cp <the 18.1 system.img> /var/lib/waydroid/images/system.img
    mv ~defaultuser/.local/share/waydroid/data ~defaultuser/.local/share/waydroid/data.a13

**The data directory must go too.** Android 11's PackageManager cannot read
Android 13's state and system_server dies on every boot with
`NullPointerException ... Settings$VersionInfo.sdkVersion` in
`readStateForUserSyncLPr`, taking zygote with it. Note the session data lives in
the **user's** home, not in `/var/lib/waydroid/data`.

The Waydroid Updater app inside the container will offer to "upgrade" to 20.0.
Do not take it: that is the broken combination.

### Camera

The container ends up with 0 cameras **on the Android 13 image**. Its provider is
`vendor.camera-provider-2-4` from Waydroid's HALIUM vendor image - the AOSP
*legacy passthrough* provider, which `dlopen`s a legacy `camera.<hw>.so` module:

    CamPrvdr@2.4-legacy: Could not load camera HAL module: -2 (No such file or directory)
    android.hardware.camera.provider@2.4-service: getProviderImpl: camera provider init failed!

and then restarts every 5 s forever. This phone has no legacy camera module: its
camera is a HIDL service, `vendor.samsung.hardware.camera.provider@3.0-service`,
which runs on the **host** and serves the host's binder domain.

On the Android 11 image `dumpsys media.camera` reports **5 camera devices**, so
the picture is better, but a working preview is not yet confirmed. If it turns
out still not to work, the fix is to bridge the camera the way sensors are
bridged: a host-side process registering a camera provider into
`/dev/anbox-hwbinder`, or a camera provider inside the container against the
host's `/vendor` (`/dev/video*` are already visible there).

## Debugging recipes

    waydroid status                              # session/container state
    tail -f /var/lib/waydroid/waydroid.log       # host side: net setup, lxc, session
    journalctl -b -t waydroid-runner             # the Sailfish app
    lxc-info -P /var/lib/waydroid/lxc -n waydroid
    lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- /system/bin/logcat -d
    lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- /system/bin/sh -c "getprop sys.boot_completed"

Launching the runner from a root shell needs the user session's environment, and
**`QT_QPA_PLATFORM=wayland`** — without it Qt tries the `xcb` plugin and the app
aborts with SIGABRT and an empty log:

    su defaultuser -c 'export XDG_RUNTIME_DIR=/run/user/100000 \
      WAYLAND_DISPLAY=../../display/wayland-0 \
      DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket \
      HOME=/home/defaultuser QT_QPA_PLATFORM=wayland; \
      setsid /usr/bin/waydroid-runner > /tmp/waydroid-runner.log 2>&1 &'

Only one session can hold the container. If the runner shows *"Android session
started already"*, something else (a `waydroid session start`, or a previous
runner) owns it: `waydroid session stop` first.

## Notes

- The script also masks `lxc@multi-user.service` (a template unit from the lxc
  package for a container this device does not have) and comments out `veth`
  and `xt_CHECKSUM` in `/etc/modules-load.d/waydroid.conf` — both are built into
  this kernel rather than modules, so `modprobe` fails and takes
  `systemd-modules-load.service` with it. Neither breaks anything; they just sit
  in `systemctl --failed` forever.

- `waydroid-container.service` is enabled into `graphical.target` by the
  package, so it starts on every boot. It is only a D-Bus service — the
  container itself starts when a session does — but disable it with
  `systemctl disable waydroid-container` if you want Waydroid fully dormant.
- The images live in `/var/lib/waydroid/images` (~2 GB) and app data in
  `/var/lib/waydroid/data`. `waydroid init -f` re-downloads; removing
  `/var/lib/waydroid` resets everything.
