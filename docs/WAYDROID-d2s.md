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
| **Shared storage** (Gallery, Documents, anything under `/storage/emulated/0`) | **Broken** | See below. |
| **Camera** | **Broken** | See below. |

### Shared storage

`/storage/emulated/0` is empty in the container and no FUSE mount ever appears.
`vold` logs `Mounting emulated fuse volume`, then after 20 s
`StorageSessionController: Failed to start session: [SessionId: emulated;0.
UpperPath: /storage/emulated. LowerPath: /data/media]`, then
`ActivityManager: Timeout executing service ... ExternalStorageServiceImpl`,
and `com.android.providers.media.module` is killed and restarted forever
(4 s, 16 s, 64 s backoff). Gallery and Documents hang waiting on it;
`com.android.externalstorage.documents` returns no roots.

Ruled out:

- `/dev/fuse` **is** present in the container (10, 229) and `CONFIG_FUSE_FS=y`.
- The kernel **does** carry the Android FUSE extensions (`FUSE_CANONICAL_PATH`
  is in `include/uapi/linux/fuse.h` and `fs/fuse/dir.c`), so this is not simply
  an unpatched mainline FUSE.
- `persist.sys.fuse=false` + restarting MediaProvider changes nothing; Android
  13 no longer honours it.
- No tombstone and **no FuseDaemon output at all** — the daemon hangs before it
  logs anything, rather than crashing.

Most likely the mismatch itself: an Android 13 MediaProvider FUSE daemon on a
4.14 Samsung kernel whose own storage stack is `sdcardfs` (`CONFIG_SDCARD_FS=y`).
Next things to try, in order of cost: strace the FuseDaemon inside the container;
check whether LXC's seccomp profile (`/var/lib/waydroid/lxc/waydroid/waydroid.seccomp`)
blocks its `mount`; or initialise with an older Android 11 system image, which
matches the HALIUM_11 vendor and predates mandatory FUSE storage (upstream only
serves lineage-20 now, but the archive on SourceForge still has 17.1/18.1
images).

### Camera

The container ends up with **0 cameras**. Its provider is
`vendor.camera-provider-2-4` from Waydroid's HALIUM vendor image — the AOSP
*legacy passthrough* provider, which `dlopen`s a legacy `camera.<hw>.so` module:

    CamPrvdr@2.4-legacy: Could not load camera HAL module: -2 (No such file or directory)
    android.hardware.camera.provider@2.4-service: getProviderImpl: camera provider init failed!

and then restarts every 5 s forever (`init.svc.vendor.camera-provider-2-4:
restarting`). This phone has no legacy camera module: its camera is a HIDL
service, `vendor.samsung.hardware.camera.provider@3.0-service`, which runs on
the **host** and serves the host's binder domain — the container cannot see it.

That explains the behaviour exactly: a camera app catches the provider during
one of its brief alive windows, gets a few frames from one rear sensor, and then
hangs when the provider dies again (`DIED client(s) ... Binder died
unexpectedly`).

Fixing this properly means bridging the camera the way sensors are bridged: a
host-side process that registers a camera provider into `/dev/anbox-hwbinder`
and proxies to Samsung's provider, or running a camera provider inside the
container against the host's `/vendor` libraries (`/dev/video*` **are** already
visible in the container). Both are real projects, not configuration. Until then
Waydroid has no camera — the phone's own camera app is unaffected.

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
