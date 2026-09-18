# Waydroid on d2s (Galaxy Note 10+, Sailfish OS 5.1.0.11)

Android 13 runs in a container on this port: Waydroid 1.4.3 with the LineageOS
20 system image on Waydroid's HALIUM_11 vendor shim. Apps install and run, touch
and the browser work. Camera and anything that touches shared storage (Gallery,
Documents) do not — both are diagnosed below.

Set it up on a freshly flashed phone with:

    devel-su /usr/bin/d2s-waydroid-setup.sh

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
6. **Runs `waydroid init`**, which downloads ~1 GB. It detects
   `vendor_type = HALIUM_11` from `ro.vndk.version=30` and writes
   `binder = anbox-binder` (and the vnd/hw equivalents) into
   `/var/lib/waydroid/waydroid.cfg` on its own.

Then open the **Waydroid** app. First start takes about a minute.

## State on this port

| Area | State | Notes |
|---|---|---|
| Container boot | Working | `sys.boot_completed=1`, Android 13 (SDK 33), ~1.75 GiB RAM while running. |
| Touch, keyboard | Working | Through `waydroid-runner`'s nested compositor. Inside the container the devices are `/dev/input/wl_touch_events`, `wl_pointer_events`, `wl_keyboard_events`. |
| Browser, general apps | Working | |
| Networking | Working | `waydroid0` bridge, container at 192.168.240.x, NAT to the phone's connection. |
| Sensors | Bridged | `waydroid-sensord` runs on the **host** against `/dev/anbox-hwbinder` and registers `android.hardware.sensors@1.0` into the container. This is the pattern any other host HAL would have to follow. |
| Shared storage (Gallery, Documents, `/storage/emulated/0`) | Working **on the Android 11 image** | Broken on the stock Android 13 image - see "The system image matters" below. |
| Camera | Enumerates on Android 11 | 5 devices visible where Android 13 showed 0; a working preview is **not yet confirmed**. |
| Audio out | Working, capped | Waydroid talks to PulseAudio directly, so Sailfish's volume policy does not apply: it arrives at 95% of full scale and the speaker amps clip, which sounds like the volume is stuck at 200%. `d2s-bt-audio.service` caps the stream at 45%, the level where it came back clean by ear on both the speaker and a Bluetooth headset. Android's own volume slider still works underneath. |
| Microphone | Unverified | Android reports `Input device: 0 (AUDIO_DEVICE_NONE)` when idle, which is inconclusive; needs a recording test. VoIP (WhatsApp calls) depends on this. |
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
