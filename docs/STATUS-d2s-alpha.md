# Sailfish OS 5.1.0.11 on Samsung Galaxy Note 10+ (d2s / SM-N975F / Exynos 9825)

Status as of 2026-09-10. Base: hybris-18.1 (LineageOS 18.1 / Android 11).

---

**Reboot check 2026-09-17** (after the DNS, SELinux, signal-strength, camera-lens and GPS changes): clean `systemctl reboot`, UI up at ~127 s, no failed units, `/etc/resolv.conf` -> resolved stub with the connected network's servers, browser sandbox sees `127.0.0.53`, ofono on IRadio 1.4 (LTE with a real strength a minute after boot; the first reading was HSPA at 1% while the modem was still registering), camera service lists main / ultra-wide / front / telephoto, Location stays on.

**Image packed 2026-09-17 17:05** (rebuilt after the audit below) —
`SailfishOScommunity-release-5.1.0.11-d2s/`:
`sailfishos-d2s-release-5.1.0.11.zip` (556 MB, sha256 34bf8c1c92513cd6…) and
`sfe-d2s-5.1.0.11.tar.bz2` (541 MB, sha256 f189d507b543d579…). Earlier images
kept as `…-d2s.old-20260910/` (first release) and `…-d2s.incomplete-1629/` (the
16:29 build, before the audit fixes). Contents verified: `hybris-boot.img` in the
zip is byte-identical to the kernel currently flashed and tested; packages are
droid-config-d2s 1-202609172055, droid-hal-d2s 0.0.6-202609172051, droidmedia
0.20260902.0+3+g2a96237, gecko-camera-droid-plugin, qt5-qpa-hwcomposer-plugin and
geoclue-provider-hybris-binder 0.3.0+d2s, with no usb-moded-defaults /
usb-moded-developer-mode. Present in the rootfs: droid-hal-early-init.sh, the
system-as-root mount units (+ their local-fs.target.wants links), an init.rc with
the boringssl self tests disarmed, ecclist.rc, `/etc/gps_xtra.ini`,
`d2s-camera.rc`, the SELinux `file_contexts`, the resolved drop-in,
`droid-net-fixup.sh`, `25-configfs-d2s.ini` (mass_storage.usb0), the dconf
adaptation file and the patched `geoclue-hybris`. Absent by design:
disabled_services.rc, droid-bootctl, 50-d2s-gst.conf.
**The image itself has not been flashed or booted.**

**Image audit 2026-09-17** — "is every patch in the build?" checked by diffing the
running phone against the image, not by assuming: `rpm -Va` for package files the
device had modified, a sweep for files owned by no package, then comparing each
against the rootfs archive. **Four things were missing or wrong and are now fixed
in the tree:**

1. `droid-configs-device/sparse-11` was never packaged — `droid-config-d2s.spec`
   lacked `%define android_version_major`, which guards those trees. That dropped
   `/usr/bin/droid/droid-hal-early-init.sh`, the system-as-root / flattened-APEX /
   linkerconfig setup that `droid-hal-init.service` runs as ExecStartPre. On the
   test device it had been installed by hand, so nothing showed it was missing; a
   fresh flash would have booted without it.
2. `system_root.mount` + `system.mount` (mount the system partition on
   `/system_root`, bind its nested `system/` over `/system`) existed only in the
   device's `/etc`. droid-hal's packaged `system.mount` puts the partition
   directly on `/system`, which is the `/system/bin` symlink loop. Now shipped in
   `sparse/etc/systemd/system/` with their `local-fs.target.wants` links.
3. `init.rc` still ran Android's boringssl self tests with
   `reboot_on_failure reboot,boringssl-self-check-failed` — removed by hand on the
   device during bring-up. Now disabled in `system/core/rootdir/init.rc` (triggers
   commented out, reboot action dropped) and rebuilt into `out/`.
4. `sparse-11`'s `disabled_services.rc` and `droid-bootctl` are deliberately
   **excluded** via `droid-configs-device/delete_file_sparse-11.list`: everything
   in this port was verified with the Android services (netd, surfaceflinger,
   audioserver, ...) running, and d2s has no A/B slots.

Also: the device's `/etc/systemd/user.conf.d/50-d2s-gst.conf`
(`GST_PLUGIN_FEATURE_RANK=droidvdec:128,avdec_h264:256`) was a leftover of the
software-decode workaround this doc says was removed; it is not in the image and
was moved aside on the device (hardware `droidvdec` playback re-verified after).
`/etc/pam.d/autologin` differs only by a commented-out `pam_console.so` line
(optional module, not shipped).

**Verified identical between device and image**: libstagefright (32 + 64),
libhwc2_compat_layer, libhybris `linker/q.so`, libcameraservice, the
qt5-qpa-hwcomposer plugin, the gecko-camera droid plugin, geoclue-hybris and all
droid-config files. droidmedia's rpm digest differs from the built .so only
because rpmbuild rewrites debug paths - the `.text` sections are identical and
all three patch markers are present.

**Packaging fixes 2026-09-17** (found while packing the image): droid-config packaged `/.gitignore` and `/usr/bin/__pycache__/*.pyc` (including one for the deleted d2s-hwc-affinity script) - removed from the sparse tree. `droid-hal-version-d2s.spec` moved from `$ANDROID_ROOT/rpm/` to `hybris/droid-hal-version-d2s/rpm/`, where `build_packages.sh --version` looks for it; at the old path the build failed *after* deleting the existing package from droid-local-repo.

## What works

| Area | State | Notes |
|---|---|---|
| Boot to UI | Working | Lipstick, homescreen, app grid. **Boot time (2026-09-18): lipstick starts at 22 s**, down from 72 s. The missing minute was `bluebinder.service`: its first instance after a cold boot hangs in the vendor HAL after "Turning bluetooth on" and is killed by systemd's 60 s `TimeoutStartSec`, and it sits in the critical path (`Before=bluetooth.service`, and the user session waits for `network.target` behind it). `sparse/etc/systemd/system/bluebinder.service.d/50-d2s-start-timeout.conf` cuts that timeout to 10 s - a healthy instance takes ~1.7 s, and the doomed one is doomed however long it is given |
| Display | Working | 1440x3040 at pixel_ratio 2.0. Launcher icons were stuck at 86 px (7-column grid) because the first image shipped only the z1.0 graphics packages; Silica sizes launcher icons from the installed set. Needs `sailfish-content-graphics-z2.0`, which the pattern pulls via icon_res once pixel_ratio is 2.0 |
| Touch | Working | |
| Waydroid (Android apps) | Partly working | **Android 13 runs in a container** (Waydroid 1.4.3, LineageOS 20 system image on the HALIUM_11 vendor shim). Touch, keyboard, browser and app installs work; camera and shared storage (Gallery, Documents) do not. Not in the image - `sparse/usr/bin/d2s-waydroid-setup.sh` installs it from Chum on demand. The kernel needed one addition, `CONFIG_NETFILTER_XT_TARGET_CHECKSUM` (without it `waydroid-net.sh` fails on its DHCP checksum rule and the container never starts); the binder side needed nothing, since `ANDROID_BINDER_DEVICES` already carries the `anbox-*` nodes Waydroid prefers, so the container gets its own binder domain. Touch only works through `waydroid-runner` (a Silica app with its own nested compositor) - upstream's `waydroid show-full-ui` renders but gets no input from lipstick. Full write-up, including what has been ruled out for the camera (the container's legacy passthrough provider has no `camera.*.so` to load; this phone's camera is a HIDL service on the host) and for storage (MediaProvider's FUSE session times out; `/dev/fuse` and the Android FUSE kernel extensions are both present), in docs/WAYDROID-d2s.md |
| Boot splash | Working (see note) | The Sailfish OS logo is drawn by the initrd a few seconds after the Samsung logo, so the screen is no longer blank all the way to lipstick. `HYBRIS_BOOTLOGO := 1` in `hybris/hybris-boot/Android.mk`; artwork generated by `make-d2s-bootsplash.py` from `d2s-bootsplash-logo.png` (the cyan Sailfish splash by taalojarvi, XDA) into `initramfs/bootsplash.ppm.gz`. **Upstream's `zcat /bootsplash.gz > /dev/fb0` cannot work on this kernel**: decon allocates the framebuffer as a dma_buf, vmaps it once to zero it and then sets `screen_base = NULL` (`decon_core.c`, `decon_fb_alloc_memory`), and `decon_fb_write` is a stub returning 0, so fbmem rejects the write with ENODEV before the driver sees it - the splash was silently lost. decon only implements `fb_mmap`, so the init script draws with busybox `fbsplash` (which mmaps, hence a PPM and not a raw dump), after waiting for `/dev/fb0` and unblanking it. A small log lands at `/var/log/bootsplash.diag` because the kernel ring buffer has wrapped by the time the UI is up; it reads `fbsplash rc=0`. **Not yet in a packed image** - flashed to the device's boot partition only |
| **Audio playback** | **Working** | Speakers. Bypasses the Android HAL entirely and drives ALSA directly — see below. Routing is static (both speakers); headphone/earpiece/BT switching is not wired up yet |
| **Telephony** | **SIM, registration and SMS working** | Verified 2026-09-12 with a Jio SIM (roaming on TELUS, HSPA): `Present=true`, ICCID/IMSI/MSISDN read, `PinRequired=none`, `Status=roaming`, incoming SMS delivered to Messages. One fix was needed: ofono uses **ofono-binder-plugin**, whose slots come from `/etc/ofono/binder.d/*.conf` (the `ril_subscription*` files in `sparse-1X` are for the old ril plugin and are dead weight here). That file listed `slot2` only, so ofono bound `IRadio/slot2`, the sole modem was `/ril_1`, `/ril_0` never existed and a card in the **first** tray was invisible - `ril.hasisim=0,0` and `SimManager.Present=false` on every slot. Declaring *both* slots made the SIM appear on `/ril_0` but was still wrong: `org.ofono.Manager.GetModems` then returned only `/ril_1`, the empty slot. The Sailfish extension (`org.nemomobile.ofono.ModemManager`) listed both, so Settings showed the carrier correctly while anything using the plain ofono modem list got a modem with no SIM - the Dialler read "No network coverage" over a fully registered network, outgoing SMS failed with `sms send error SYSTEM_ERR`, and `defaultDataModem` stayed empty. The hardware only looks dual-SIM (two rilds, `IRadio` for slot1 *and* slot2) - the tray is a hybrid SIM + microSD - so the config now declares **only `slot1` -> `/ril_0`**. `GetModems` returns `/ril_0`, voice and data default to it, and the phantom "SIM2 | Unknown" entry is gone. Verified with two SIMs: Jio (roaming on TELUS) and Bell (`Status=registered`, LTE). Outgoing calls connect (911 reached a dispatcher); **in-call audio is confirmed working by ear** (user, 2026-09-18) - see Audio routing. Mobile data is untested. **Open issue: ofono SEGVs during SIM init** after `Open logical channel failure: MISSING_RESOURCE` (seen with the Bell SIM). It appears self-inflicted - repeated `systemctl restart ofono` leaks SIM logical channels until the modem runs out - and it settles once ofono is left alone (0 crashes in a 180 s idle window, registered on Bell throughout). Two things made it far worse than it should have been, both now handled by `sparse/etc/systemd/system/ofono.service.d/50-d2s-telephony-robust.conf`: `core_pattern` pipes cores to `rich-core-dumper`, and dumping ofono's 14 threads held the process in `do_coredump` for minutes while systemd still called the unit `active` and every D-Bus call timed out (a crash that looks exactly like a deadlock); and once crashes became fast, systemd's default start-rate limit left the unit `failed` permanently. The drop-in sets `LimitCORE=1` (**not** 0 - for a piped `core_pattern` the kernel ignores RLIMIT_CORE; only 1 is special-cased, measured: 24 s+ at 0 versus under 2 s at 1) plus `StartLimitIntervalSec=0` and `Restart=always` **Signal strength (fixed 2026-09-17):** ofono had no `Strength` at all because it used IRadio 1.2, and the vendor libril (ROM vendor partition) drops any strength report whose size is not exactly 60/80/100 bytes for 1.0/1.2/1.4; this RIL sends the 100-byte 1.4 layout. The vendor manifest publishes `@1.4::IRadio`, so `binder.d/dual-sim.conf` now sets `radioInterface = 1.4`, and the reports arrive. ofono-binder 1.1.25 then maps the LTE RSRP linearly onto -100..-60 dBm (an RSSI range), so -95 dBm showed 12% = 1 of 5 bars; `signalStrengthRange = -115,-85` reproduces newer ofono-binder's RSRP map and gives 46-66% (3-4 bars) at -95..-100 dBm. Status bar bars = floor((strength+19)/20). After the switch: LTE registration, data, SIM and the SMS service centre re-checked; a voice call on 1.4 still needs a manual test. The Dialler strength-gate patch (`d2s-voicecall-gate.sh`) is kept as a safety net |
| **Mobile data (LTE)** | **Working** | Verified 2026-09-17 on Bell: LTE attached, `rmnet0` IPv4+IPv6, HTTPS over mobile data, survives a cold boot. It showed 3.5G and never passed traffic; five separate problems were fixed, (4) and (5) found after data first worked. (1) ofono-binder enables every technology its radio HAL permits and kept requesting preferred network type 26 (NR_LTE_GSM_WCDMA) from this LTE-only modem (`expected nr` / `setting rat mode 26`); `binder.d/dual-sim.conf` now says `technologies = gsm,umts,lte` (mode 9). (2) ofono provisioned Bell's internet context as `inet.bell.ca` (the tablet/mobile-internet APN) and sends the internet context as the LTE initial-attach APN; the default bearer never came up, so data registration on LTE stayed `unregistered` and the modem bounced LTE<->HSPA. With `pda.bell.ca` (Bell's phone-plan APN) LTE data registers and stays. This is carrier provisioning, not port code - but note ofono only sends the attach APN when it starts, so after changing the APN in Settings a reboot may be needed. (3) `droid-net-fixup.sh` wrote `/etc/resolv.conf` from the first **wifi** service whether connected or not, so on mobile data DNS pointed at the home ISP's resolvers and nothing loaded by name; it now follows whichever service is online/ready (wifi or cellular), IPv4 first, skipping link-local `fe80::` servers. (4) IPv6 was unusable: netd's policy-rule scheme covers IPv6 too, but the fixup only restored the main-table lookup for IPv4, so every IPv6 connect failed with ENETUNREACH despite a global address and default route - fast.com (dual-stack API) did not work in the browser. `apply()` now adds the rule for both families and resets `ip6tables` as well; verified fast.com API and test server over IPv6. Throughput measured 4-5 Mbit/s on Bell band 2 (EARFCN 900, RSRP about -96 dBm, RSRQ -10 dB, CQI 8), with the phone's CPU nearly idle: the radio link, not the port. (5) Pages would not load in the browser on LTE even though everything outside it worked: sailjail's Internet permission gives each sandboxed app a private **copy** of `/etc/resolv.conf` made at launch (`private-etc ...,resolv.conf`), and the browser booster had copied the wifi resolvers at boot. Sailfish's connman is built `--with-dns-backend=systemd-resolved`, so the intended setup is a constant `/etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf` (127.0.0.53). resolved had been masked on the device because it SIGSEGVed (libselinux, see the SELinux notes), and once running it could not open sockets: the Android kernel's paranoid networking allows AF_INET only to gid 3003, so `systemd-resolved.service.d/50-d2s-inet.conf` adds `SupplementaryGroups=inet`. `droid-net-fixup.sh` now points `/etc/resolv.conf` at the stub as soon as it starts, re-pushes the connected service's servers when resolved has none for its interface (connman only pushes on network changes, so a resolved restart otherwise leaves only resolved's built-in public fallback servers), and writes the file directly only if resolved is not running. Verified: sandbox sees `nameserver 127.0.0.53`, fast.com runs in the browser. Open: Samsung RILD logs `LoadSimOperator(): Failed to set IMSI from [gsm.sim.operator.numeric]` constantly (Android's telephony normally publishes those properties); LTE data works without them. |
| **Sensors** | **Working** | Accelerometer / gyro / magnetometer / rotation all stream to sensorfw clients; auto-rotation OK. **Proximity needed a fix** (verified 2026-09-16: the screen now blanks against the ear during a call). Everything below sensorfw was already correct — the kernel logs `[SSP] Proximity Sensor Detect : 1/0` and the HAL logs `ProximitySensor - 0(cm)/8(cm)`, both matching every cover exactly — but mce never received a single sample. Samsung's HAL lists the sensor correctly in `getSensorsList` (handle 9, type 8 `SENSOR_TYPE_PROXIMITY`, flags 0x0003 = WAKE_UP\|on-change) yet tags the *events* with its **device-private type 65592**, the raw TMD4910 proximity/palm sensor reserved above `SENSOR_TYPE_DEVICE_PRIVATE_BASE` (65535) since the S10. Android does not care because its sensorservice dispatches by sensor **handle**; sensorfw dispatches by **type** (`m_registeredAdaptors.values(data.type)`, filled by `insert(adaptor->m_sensorType, ...)`), and `HybrisProximityAdaptor` registers under type 8, so every event was dropped. Measured in one covering session: 14 `HYBRIS EVE SENSOR_TYPE_PRIVATE_65592`, zero `HYBRIS EVE PROXIMITY`, while ACCELEROMETER (269) and LIGHT (55) flowed through to mce normally. Not fixable by configuration — the adaptor's type is compiled in and sensorfw clamps interval requests to the sensor's `[minDelay, maxDelay]` = `[0, 0]`. `d2s-proximity-uinput.service` therefore polls `/sys/class/sensors/proximity_sensor/raw_data` (~1340 uncovered vs 3500–4700 covered) and republishes it as a uinput evdev device `d2s-proximity` emitting `ABS_DISTANCE` (0 = near, 1 = far), with `primaryuse.conf` switched to `proximityadaptor = proximityadaptor-evdev` + `input_match`. Dead ends: `batch()` with a sane period (the HAL clamps to 0 since maxDelay is 0), the plain `proximityadaptor` (hardcoded for Nokia RM680/RM696/NCDK, binary struct), and mce evdev (mce leaves ALS/PS devices to sensorfw) |
| **Hardware video decode** | **Working** | Verified 2026-09-17: FinTube plays VP9 smoothly, the browser is smooth at 1080p/1440p (4K60, itag 315 `vp09.00.51.08`, still lags slightly, likely network). Two droidmedia bugs, both in `external/droidmedia`. (1) **Decoding into a surface failed outright** - `OMXNodeInstance: useBuffer(Exynos.vp9.dec, Output:1 8@...) (0x80001000)` then `ACodec: Failed to allocate output port buffers after port reconfiguration: (-12)` - so FinTube, Gallery and other gst-droid/media-buffer clients fell back to software. ACodec sizes the output pool as nBufferCountMin + the BufferQueue's min-undequeued count + extras, and the MFC driver accepts at most 32 output buffers (`MFC_MAX_DPBS` in `mfc_data_struct.h`); `DroidMediaBufferQueue` allowed 32 acquired buffers at <=1080p (an earlier fix capped it to 8 only above 1080p, for the same error on 4K AVC), so VP9 at 1080p asked for ~9+33+extras. The cap now applies to every codec queue (camera queues, created without a size, are unchanged). (2) **The decoder was destroyed and rebuilt every few seconds** in the browser: Gecko drains it whenever playback catches up with the downloaded data (MSE waiting-for-data), then flushes it and seeks back to the keyframe - and a drained droidmedia codec was dead by design, so gecko-camera's `flush()` destroyed it and the next frame created a new OMX component and MFC instance. `droid_media_codec_flush()` (only gecko-camera calls it; gst-droid never does) now really flushes and resumes the same codec: `AsyncCodecSource::flushAndResume()` stops the input reader without queueing EOS, flushes MediaCodec, waits for already-posted callbacks with stale buffer indices to be dropped, discards pending output, restarts MediaCodec (async mode resumes from FLUSHED on `start()`) and restarts the source and reader. A flush generation makes the output loop ignore an EOS that was in flight across the flush (Gecko does not wait for the drain's EOS before flushing - without this the stale EOS re-drained the restarted source). gecko-camera (`hybris/mw/gecko-camera`, upstream + one patch) no longer destroys the codec in `flush()`. Still open: Gecko also shuts the decoder down on every MSE stream-id change (YouTube quality switch) because the Sailfish PDM does not report `SupportDecoderRecycling()`; that lives in libxul |
| **Double-tap to wake** | **Working** | Verified 2026-09-16. Two pieces were missing. (1) The panel has to be put into low-power scanning: `echo aot_enable,1 > /sys/class/sec/tsp/cmd` (Samsung "AOT", Always On Touch; `cmd_list` also offers `set_lowpower_mode` and `spay_enable`). It then reports a double tap while blanked as `EV_KEY KEY_WAKEUP` (143) on `sec_touchscreen`. (2) mce receives that key but deliberately does nothing with it — in its keypress handler `KEY_WAKEUP` only takes a short wakelock (`"[wakeup] block suspend a while"`). What mce unblanks on is `EV_MSC/MSC_GESTURE` with `GESTURE_DOUBLETAP`, which it synthesises from **`KEY_POWER`** arriving on a device classified `EVDEV_DBLTAP`. `d2s-doubletap.service` therefore enables AOT at boot, watches the touchscreen for `KEY_WAKEUP` and re-emits `KEY_POWER` on a uinput device advertising the dbltap key set (`KEY_POWER`/`KEY_MENU`/`KEY_BACK`/`KEY_HOMEPAGE`), pinned to that class by `/etc/mce/25-d2s-doubletap.ini` (`d2s-doubletap=DBLTAP`) so it can never be mistaken for a real power key. mce then logs `[doubletap] as power key event` → `gesture(4)` → `display_state_next: OFF -> ON`. Note mce's "Double-tap wakeup policy" is `proximity`, so this depends on the proximity fix above actually working |
| **USB modes** | **All three working** | Verified 2026-09-17 from the PC with a self-reverting on-phone test (`~/.cache/claude-hadk/usb-mode-suite.sh` + `serve/usbmode-test.sh`: switch, log, always return to developer mode, reboot as backstop). **MTP**: enumerates as 18d1:0a07 at SuperSpeed, gvfs mounts it, 20 MB written in 0.33 s and read back in 0.59 s with a matching md5, camera photo copied, delete works (the kernel's FunctionFS SuperSpeed descriptor synthesis is what makes this work at all). **Charging only**: was mapping usb-moded's placeholder mass-storage function to `acm.0`, so the PC saw a USB serial port; `25-configfs-d2s.ini` now sets `function_mass_storage = mass_storage.usb0` (needs CONFIG_USB_CONFIGFS_MASS_STORAGE, enabled 2026-09-12) and the PC sees an empty removable drive, charging unaffected. **Developer mode**: RNDIS up, DHCP lease to the PC, ssh port open. Also fixed: usb-moded listed `developer_mode` twice (Settings > USB showed two identical entries) because `usb-moded-defaults` pulled in the generic `usb-moded-developer-mode` (g_ether/usb0) next to jolla-developer-mode's android dyn-mode; droid-config now `Provides: usb-moded-configs` and obsoletes both, leaving one entry. USB tethering (`connection_sharing`) is not installed and was not tested. Note the image defaults to developer mode on connect because `patterns-sailfish-device-tools` pulls `jolla-rnd-device`; stock Sailfish would ask instead |
| **GPS** | **Working (fix verified)** | 2026-09-17: indoor cold start got a fix in ~2 min - 8 of 12 satellites used, 16 m accuracy, through the normal Sailfish path (geoclue-provider-hybris-binder -> `vendor.samsung.hardware.gnss@2.0` -> Broadcom `gpsd`). The reported "GPS not working" was **Location switched off** (`enabled=false` in `/var/lib/location/location.conf`; `/etc/location/location.conf` is only a compatibility copy). Assistance data never reached the chip, for two reasons: (1) `gpsd` fetches its LTO/RTO files itself, but Android processes cannot resolve host names here (`/system/bin/ping gllto.glpals.com` -> unknown host; netd has no default network), and (2) the HAL's download requests went to the provider, which had no XTRA servers configured. `/etc/gps_xtra.ini` now lists Broadcom's public 7-day LTO files, and the provider downloads and injects them. But geoclue-provider-hybris 0.3.0 injects over HIDL with `gbinder_local_request_append_hidl_string()`, which uses strlen() - an LTO file starts `ff ca de 00`, so the HAL got 3 bytes and kept asking again. Patched in `hybris/mw/geoclue-providers-hybris` (branch d2s off tag 0.3.0) to write the hidl_string with its real length; built into the local repo as `geoclue-provider-hybris-binder-0.3.0+d2s.*` and verified: one download request per session instead of one every few seconds, and gpsd now stores the full `lto2.dat` (182639 bytes) plus `ltoStatus.txt` in `/data/vendor/gps`, then reported a fix (7 satellites, 24 m). The rebuilt droid-config packages (2026-09-17) were checked to contain `/etc/gps_xtra.ini`, `d2s-camera.rc`, the SELinux `file_contexts`, the resolved drop-in and `zz-d2s-adaptation.txt` (in `droid-config-d2s-sailfish`). Open: SUPL / Broadcom LBS assistance also needs DNS on the Android side; the satellite timestamp the provider reports is negative (cosmetic) |
| Device identity | Working | Settings > About shows Samsung / Galaxy Note 10+ |
| WiFi | Working | Auto-connects, real MAC, DNS + routing OK. The same network used to be listed many times (66 entries for one SSID; the radio only sees 2 BSSIDs). Two causes, both fixed: (1) bcmdhd's second station interface `wlan1` was also scanned - blacklisted in `sparse/etc/connman/main.conf.d/10-d2s-wlan1.conf`; (2) the real cause - connman fixes a device ident from wlan0's MAC at ~35 s, but bcmdhd only swaps the random `00:90:4c:xx` placeholder for the real `8c:b8:4a:...` when firmware loads, so every boot minted a new ident and another saved service under `/home/defaultuser/.local/share/system/privileged/connman/`. `d2s-wlan0-mac.service` now sets the EFS MAC before connman starts. Verified across reboots: one ident (`8cb84a04fd03`), one entry per network |
| USB | Working | MTP, developer (RNDIS) and charging-only modes |
| Battery | Working | Charge level and charging state report correctly. **The core pinned from boot by Samsung's HWC event thread is now gone entirely** (2026-09-17): both DECON vsync nodes are bound to a plain file, and the compositor drives updates from a timer instead. Verified after a cold boot: no thread above ~20%, frame pacing dead steady (60 windows of 100 ms during 4K playback, zero outside 5-7, 61 fps), UI smooth and 1080p video smooth. Two plugin changes were needed, both in `hybris/mw/qt5-qpa-hwcomposer-plugin` and both env-gated so upstream behaviour is unchanged when unset: `QPA_HWC_VSYNC_TIMEOUT` makes the hardcoded 50 ms fallback configurable (set to 10 — the timeout starts when the update is *requested*, so the period is timeout + render time: 16 gave 48-53 fps, 10 gives 60-61), and `QPA_HWC_TIMER_VSYNC` stops the backend touching `eventControl(HWC_EVENT_VSYNC, …)` at all. That second one matters: with the timer firing before the next frame is requested, the backend was disabling and re-enabling the vsync interrupt **60 times a second** — churn that never happened while vsync callbacks were arriving, and it was clearly visible as periodic stutter. Both values live in `sparse/var/lib/environment/compositor/droid-hal-device.conf`. History below is kept because it explains why the obvious fix alone does not work. **Previously partly fixed twice**: (1) `droid-hal-prepare.sh` binds a plain file over `19050000.decon_t/vsync`, the dead second controller. (2) That left `19030000.decon_f/vsync` spinning, because it is the live node that latches `POLLPRI\|POLLERR` and this HWC never reads to clear it — re-measured 2026-09-16 with ftrace: **21207 syscalls in one second, every one `ppoll` (NR 73), zero reads**, identical to the original diagnosis. `decon_f` cannot be bound as well: that stops the spin but costs the compositor its vsync (~17–18 fps, the Qt plugin's hardcoded 50 ms fallback — only `QPA_HWC_IDLE_TIME` is tunable, the timeout is not), and a bind only affects opens made after it so it cannot be applied to a running lipstick. An interim `d2s-hwc-affinity.service` made the spin cheap by pinning that thread to the little cluster, measured at 8% battery on an 875 mA budget: **50–323 mA on the big cluster → 796–842 mA on the little cluster**. That service has since been **removed** — with the spin gone it would only mispin a legitimately busy `QSGRenderThread`. Note the 875 mA / 5 V ceiling is just the PC USB port — the test device charges over `rndis0`; a wall charger should negotiate much more |
| Vibration | Working | Bypasses the Samsung-only vibrator HAL: ngfd writes `/sys/class/timed_output/vibrator/enable` directly. Needed the CS40L25A firmware embedded in the kernel (it probes before any filesystem is mounted) and `droid-vibrator-perms.service` to make the node writable by the user |
| Microphone | Working | Plain ALSA capture on ABOX WDMA1 (`hw:0,13`) as PulseAudio `source.primary` (`droid.input.builtin=true`). Controls in `mixer-mic-main.tsv`: Samsung `dev-main-mic` + `gain-media-mic` + `ABOX NSRC0=UAIF0`, with `WDMA1_EN`/`VPCMIN_DAI0_EN` pinned Off (Samsung's `route-ap-record` sets them On and hands WDMA1 to the DSP's MMAP voice pipeline, which never delivers to the AP). Verified by speaker-to-mic loopback through PulseAudio. Gain: `IN3R Digital Volume` 168 (+20 dB); Samsung's 96 is -16 dB and recorded speech at ~-50 dBFS, which played back as silence |

## What does not work yet

| Area | State | Blocker |
|---|---|---|
| Bluetooth | Working | Powers on at boot and scanning finds devices. Two faults, both fixed: (1) the boot-time bluebinder instance wedges - its first HCI commands arrive before it considers Bluetooth up, are "delayed" (dropped), and every power-on then fails with `org.bluez.Error.Failed` / `bluetoothd: Failed to set mode: Failed (0x03)`; any fresh instance works, so `d2s-bluebinder-restart.service` restarts it once after boot. (2) The "scanning is broken" symptom was a test artefact: BlueZ ties a discovery session to the calling D-Bus client, and `gdbus call` exits immediately, so BlueZ cancelled discovery microseconds after starting it. With a client that stays connected, discovery runs and finds devices. (3) Once the restart moved a minute earlier (see Boot to UI), a third fault surfaced: the hci device the restarted bluebinder registers comes up **soft-blocked**, and nothing clears it, so every power-on fails with `org.bluez.Error.Blocked: Blocked through rfkill`. `d2s-bluebinder-restart.service` now runs `rfkill unblock bluetooth` afterwards; that only permits power-on, the user's own Bluetooth setting still decides |
| Wakeup sensor | Not offered | Hardcoded `wakeupsensor=False` in `20-sensors-default.conf` (not feature-gated); plugins are installed, config just disables it |
| Camera | Mostly working | Stills and video with sound both work. Fixed in the kernel: LineageOS's newer Samsung camera driver inserted 40 bytes into `struct camera2_shot_ext`, so the kernel read the HAL's shot magic at the wrong offset (`shot magic number error(0x00000000)`) and the ISP never started. Restored the stock layout in `fimc-is-metadata.h`; verified 0 shot errors and ISP interrupts running. Video recording needed four more fixes — see "Video recording" below; verified headless at 5.7 s, 0 dropped frames, H.264 ~1.2 Mbit/s + AAC ~142 kbit/s. **Recording quality fixed 2026-09-17**: 4K clips were heavily blocked because nothing ever set a sensible encoder bitrate or profile. QtMultimedia leaves the bitrate at 0 and gst-droid's `droidvenc` defaults `target-bitrate` to 192000 regardless of resolution, so the Exynos encoder fell back to its own floor - measured 1.8-4.4 Mbit/s for 3840x2160 - and ACodec logged `setupAVCEncoderParameters with [profile: Baseline]`, the one profile with neither CABAC nor B-frames. `external/droidmedia/droidmediacodec.cpp` now derives a bitrate from the frame size (~0.083 bits per pixel per frame: ~20 Mbit/s for 4K30, 5 for 1080p30, 2.2 for 720p30) whenever the request is absent or implausibly low for the resolution, and defaults H.264 to **High** instead of Baseline. Measured after: `Bitrate ... too low for 3840x2160@30, using 20736000 bps`, `[profile: High]`, and a 4K clip at **18.9 Mbit/s** instead of 2.0 - confirmed visually much better. Also fixed a latent bug there: `getAVCLevelFor()` was reading `width`/`height`/`frames`/`bitrate` uninitialised when the client did not supply them. The "blank viewfinder with Camera is not responding" seen when reopening the app was the aftermath of a hung recording leaving the camera wedged, not a separate fault: recording and then immediately reopening the camera for a still now both succeed **All lenses (2026-09-17):** jolla-camera shows 1.0 / 0.5 / 2.0 buttons and the front camera uses the full sensor. Samsung's stock provider lists only HAL ids 0-3 (0 main, 1 front 16:9 crop, 2 ultra-wide, 3 front full); the 2x telephoto is HAL id 52, which LineageOS' own provider adds by hand. Our camera service (`frameworks/av` CameraProviderManager, "(hybris)" patch) now also offers the ids in `ro.camera.extra_ids` and skips those in `ro.camera.hidden_ids`; `sparse/usr/libexec/droid-hybris/system/etc/init/d2s-camera.rc` sets 52 and 1. API1 cameras are then 0 main (4.3 mm, 12 MP), 1 ultra-wide (1.8 mm, 16 MP, fixed focus), 2 front (10 MP, 4K video), 3 telephoto (6 mm, 12 MP); `backCameraLabels=['1.0','0.5','2.0']` in `zz-d2s-adaptation.txt` enables the toggle. Verified by capture: 4032x3024, 4608x3456, 4032x3024 on the back lenses and 3648x2736 on the front (was 2944x2208 on id 1); previews verified on all four. Video recording on the new lenses is not yet verified. The 32-bit `libcameraservice.so` must be rebuilt into droid-hal for the image. Also: the "Swipe down to access camera settings" hint showed on every launch - jolla-camera 1.3.2 never increments `camera_mode_hint_count`; the vendor dconf now starts it past its limit |
| MTP (file transfer) | Working | Verified 2026-09-11: host enumerated the phone at 5000M as 18d1:0a07, GNOME/gvfs mounted it and listed "Mass storage" (the user's home). Needed a kernel fix: buteo-mtp supplies full/high-speed descriptors only (`ss_count = 0`) and this DWC3 always links at SuperSpeed, where a FunctionFS function without SS descriptors is left out of the configuration (`no configurations / error -22`). `ffs_synth_ss_descs()` in f_fs.c now derives the SS set from the HS one (dmesg: `functionfs: added 7 SuperSpeed descriptors ...`) |
| Audio routing | Partial | One fixed path to both speakers. Headphones, earpiece and Bluetooth are still not switched — `module-droid-card` used to do that. **In-call audio** now has a route: calls connected but were silent both ways, because the 32-bit HAL that would normally swap the codec route on call start can never load. Voice audio does **not** use an AP-side PCM on this SoC - the CP talks to the ABOX DSP directly and the DSP bridges it to the codec once the routing controls are set - so the fix is purely a mixer delta: Samsung's `incall_nb-*` path (`SPUM ASRC3/4` on, `ABOX Sound Type=VOICE`, amps to `ASP` with boost off, `route-cp-tx-bridge` for uplink, 3-mic input, in-call gains). Generated with `tools/debug/gen-alsa-mixer.py` into `/usr/share/droid-audio/incall/incall-{handset,dual-speaker}.tsv` (a subdirectory, so `droid-alsa-mixer.sh`'s boot-time `*.tsv` glob does not pick them up) and applied on `CallAdded` / undone on `CallRemoved` by `d2s-incall-audio.service`. All 52 controls apply with 0 failures and revert cleanly, and the route fires correctly on real calls (verified in the log on a UI-placed call) - but **calls are still silent in both directions**, so the mixer route is necessary and not sufficient. Measured during a live, `active` call with the route applied: every PCM stays `closed` (`pcm0p`/RDMA0, `pcm13c`/WDMA1) and the ABOX/Calliope driver logs nothing at all, i.e. the DSP's voice pipeline never starts. `ABOX Audio Mode=IN_CALL` (added to the lists; the vendor HAL sets it from code, no mixer path does) did not change that, and RDMA0/WDMA1 refuse to open by hand (`pcm_write`/`pcm_read` errors). What is missing is the CP-side activation the vendor HAL does through `libsecril-client`: `SetCallAudioPath(path)` + `SetCallClockSync(SOUND_CLOCK_START)` over rild's abstract socket `@VND_Multiclient` (payloads `{0x08,0x05,0x00,0x06,path,0}` and `{0x08,0x0A,0x00,0x05,1}` wrapped in `OEM_HOOK_RAW`; paths EARPIECE 0x01 / SPEAKER 0x06 as this is an ss310 modem, so `SAMSUNG_NEXT_GEN_MODEM` is not defined). **Blocker:** rild accepts gpsd on that socket but closes ours instantly (t=0.00s, before any write), and this is not uid (0/1000/1001/1005/1013/1021/1041 all refused), not the executable path (tested by bind-mounting the interpreter over `/vendor/bin/hw/gpsd`), not free slots (still refused with gpsd stopped), not SELinux (permissive, all contexts `u:r:kernel:s0`) and not timing. `audiosystem-passthrough-dummy-af` - the documented fix for "calling parties cannot hear one another" - cannot register either: `Failed to add media.audio_flinger (-2147483647)` even with Android's audioserver bind-mounted out of the way, and the docs scope it to qti-mode devices. **Solved by driving the vendor HAL instead** (`sparse/usr/bin/d2s-incall-cp-audio.py`): that HAL runs in its own process and registers `android.hardware.audio@5.0::IDevicesFactory` on hwbinder, so its 32-bitness (which only ever stopped PulseAudio from `dlopen`-ing it in-process) is irrelevant to a 64-bit caller over binder - and being a *vendor* process it is allowed on the rild socket we are not. A ctypes/libgbinder client calls `openPrimaryDevice()` (IDevicesFactory code 2) then `setMode(AUDIO_MODE_IN_CALL)` (IPrimaryDevice code 23), which makes the HAL log `AudioRil: ### Send OEM IPC command : cmd(0xf), ipcData(0x2)`, `VoiceCall START notification received`, and open two more `@VND_Multiclient` connections - i.e. the CP activation, performed by the HAL. It must hold `IPrimaryDevice` open for the whole call, so `d2s-incall-audio.sh` runs it as a child and SIGTERMs it on `CallRemoved` (the helper restores `AUDIO_MODE_NORMAL` first; teardown verified: connections 4 -> 2, mode 2 -> 0). Two notes for whoever continues: `setParameters` (code 19) is refused with UNKNOWN_ERROR whatever is passed - as is every code in 17..21, while 22+ always work - so the HAL gets no `routing=` hint and picks its own output; and the HAL falls back to `/vendor/etc/mixer_paths.xml` (`no mixer_info or there is error`) when `mixer_paths_r18.xml` is the correct pair for this handset. **Confirmed working by ear on a live call (user, 2026-09-18)**, two-way. (Earlier testing was blocked because the Jio SIM has no international roaming pack, so the network rejected every outgoing call with `cause 65535` before it reached `dialing`.) Note the uplink bridge sets `WDMA1_EN=On`/`VPCMIN_DAI0_EN=On`, so ordinary AP recording on `hw:0,13` cannot work while a call is up |
| NFC / S-Pen | Untested | |

## Known cosmetic issues

- The kernel's camera driver now matches the camera HAL in the stock
  `N975FXXS6DTI5` vendor that the XDA LineageOS 18.1 ROM (ivanmeler)
  installs. Flash that ROM first; a different /vendor will likely bring the
  black-viewfinder bug back (see the camera row above).

- Fixed: media playback could get stuck on PulseAudio's dummy `sink.null`
  while ringtones still played. xpolicy.conf resolves the loudspeaker as
  "the sink whose `droid.output.media_latency` is true"; the ALSA sink had
  no `droid.*` properties, so media groups fell back to `sink.null`. The sink
  now declares them (`arm_droid_card_custom.pa`); verified 0 streams forced
  to `sink.null` after a reboot.

- Fixed 2026-09-17: `systemd-hostnamed`, `systemd-user-sessions`,
  `systemd-tmpfiles-clean` and `systemd-resolved` no longer SIGSEGV in
  libselinux. droid-config now ships an empty file-context database
  (`/etc/selinux/targeted/contexts/files/file_contexts`, one `/.* <<none>>`
  rule), so `selabel_open()` succeeds and nothing is labelled.
  `/etc/selinux/config` is unchanged - see the addendum under "Do not retry"
  for why this is not the change that wedged PID 1. All four units run, and
  `systemctl --failed` is empty.

---

## Root causes found and fixed

These are all fixed **in the build tree**, so a fresh flash gets them.

### Audio - FIXED (playback works; two earlier diagnoses were wrong)

Speakers work. Verified after a clean reboot: three system sounds played
through PulseAudio, and the cs35l41 amps reported real per-channel cone
excursion (left 0.1581, right 0.1066) with voice-coil heating, i.e. stereo
content physically moving the drivers.

**Correction 1:** an early revision of this document said audio was working and
"verified". What had actually been verified is that `paplay` streamed into
PulseAudio without error and the sink left SUSPENDED - the *software* path
accepts audio. Nothing had confirmed that sound left the speaker, and it did
not. Treat "the pipeline accepted it" as evidence of nothing until either a
human confirms sound or the amps report non-zero excursion.

**Correction 2:** a later revision blamed the AOSP *stub* HAL being loaded in
place of `audio.sec_primary.default.so`, and called `adev_open()` returning
EINVAL an unexplained vendor quirk. Right symptom, wrong cause.

#### Root cause: the only real audio HAL on this device is 32-bit

`/vendor/lib64/hw/` contains **no working audio HAL at all**. What is there:

| Library | Arch | Size | What it is |
|---|---|---|---|
| `audio.primary.default.so` | 64-bit | 15,576 | AOSP stub, "Default audio HW HAL", links no implementation |
| `audio.sec_primary.default.so` | 64-bit | 15,384 | Samsung **shim**, not an implementation |
| `audio.primary.exynos9825.so` | **32-bit** | 125,752 | the real Samsung HAL - **`/vendor/lib/hw/` only** |

`ro.hardware` is `exynos9825`, so `hw_get_module_by_class("audio", "primary")`
resolves to `audio.primary.exynos9825.so` - which exists only in the 32-bit
directory. `/vendor/bin/hw/android.hardware.audio@2.0-service` is itself a
**32-bit** binary, which is why Samsung never shipped a 64-bit build.

Sailfish's PulseAudio is 64-bit, and a 64-bit process cannot dlopen a 32-bit
library. `module-droid-card` could therefore only ever reach the stub, which
accepts streams, reports success and discards the audio. That is why PulseAudio
looked healthy, routed correctly, applied volume, and the device was silent.

It also explains the EINVAL. The Samsung shim is 15 KB and links only
libc/libc++/libcutils/libdl/libhardware/liblog. It exports
`sec_load_audio_primary_device`, which loads the *primary* HAL and asks it for
the Samsung extension. In 64-bit there is no `audio.primary.exynos9825.so`, so
it loads the AOSP stub, finds no Samsung entry point, logs its own string

    %s: exit: The audio hal does not support to samsung audio hal

and returns EINVAL. The shim was correct; it was reporting a missing 64-bit
implementation.

Note also that `audio_policy_configuration_sec.xml` names its module `primary`,
not `sec_primary`, so `module_id=sec_primary` was never going to be the fix.

**None of this is fixable by configuration.** The fix is to stop using the
Android HAL.

#### The fix: drive the codec directly through ALSA

Three pieces, all in the build tree.

**1. Routing.** `droid-alsa-mixer.service` runs `/usr/bin/droid-alsa-mixer.sh`,
which applies 189 mixer controls from
`/usr/share/droid-audio/mixer-media-dual-speaker.tsv`. That list is Samsung's
own configuration, flattened out of

    /vendor/etc/mixer_paths_r18.xml   initial <ctl> block + media-dual-speaker
    /vendor/etc/mixer_gains_r18.xml   gain-media-dual-speaker

which is exactly what the vendor HAL applies for media playback on both
speakers. It routes ABOX SIFS0 to UAIF1 at 32 bit / 4 channel / 48 kHz and
brings up both cs35l41 smart amps; the link carries two playback channels plus
two feedback channels for speaker protection. Applies with `ok=189 fail=0`.

The r18 variant is correct here: the pair is selected by
`/proc/device-tree/sound/mixer-paths` and `ro.revision` on this handset is 24.
Order within the list matters - the initial block leaves SIFS0 at 24 bit /
2 channel and `media-dual-speaker` raises it to 32 bit / 4 channel - so the
controls must be applied top to bottom, never sorted or de-duplicated.

**2. The sink.** `sparse/etc/pulse/arm_droid_card_custom.pa` loads
`module-alsa-sink` instead of `module-droid-card`:

    load-module module-alsa-sink device=hw:0,1 sink_name=sink.primary-out \
        rate=48000 channels=2 format=s16le tsched=0 fragments=4 fragment_size=4096

The name `sink.primary-out` is not optional. Sailfish's routing tables
(`x-maemo-route.table`, `xpolicy.conf`) and `module-policy-enforcement` address
the primary output by that name.

**3. `module-droid-hidl` must not load.** See below - it aborts the daemon.

#### Why hw:0,1 and not hw:0,0

RDMA0 (`hw:0,0`) is the obvious choice and it is **broken**. The Calliope DSP
accepts the entire sequence and then does nothing:

    [CALLIOPE2] Register A listener idx: 0, entity: PCMOUT0, node: RDMA0
    [CALLIOPE2] PCM open for output channel: 0
    [CALLIOPE2] Entity buffer of the RDMA#0 was alloced: 192000, 0x800D9B58
    [CALLIOPE2] RDMA hwparams output-0: 48000, 16, 2, 9
    [CALLIOPE]  calliope2_pcm_trigger-0 - type: 2, trigger: 1

No error follows, and no DMA either. `/proc/asound/card0/pcm0p/sub0/status`
shows `appl_ptr` climbing while `hw_ptr` stays at 0, and ALSA fails the write
with EIO. `abox_rdma_pointer()` only advances once the DSP sends
`PCM_PLTDAI_POINTER` back, and on RDMA0 it never does - although ABOX
interrupts *are* reaching the CPU, so the DSP-to-AP path itself is fine.

Not a format problem: 2 and 4 channel, S16/S24/S32 all behave identically, and
mmap access hangs instead of erroring. Not contention either - stopping
`vendor.audio-hal-2-0` changes nothing, and it holds only `/dev/snd/controlC0`.

Scanning every playback device, **only RDMA0 and RDMA4 fail**. RDMA1, 2, 3, 8,
9 and 11 all stream normally. RDMA1 was chosen because `ABOX SPUS OUT1` is
already routed to SIFS0 by the initial mixer block, so it reaches the speaker
amps by exactly the path RDMA0 would have.

Why RDMA0 specifically is rejected by the DSP is still unexplained. It is
`type=normal` in the device tree like the others, and the driver logs nothing.

#### module-droid-hidl aborts PulseAudio

With no droid card loaded, `module-droid-hidl` fails - which would be harmless,
except its failure path is buggy:

    E: module-droid-hidl.c: Couldn't get hw module functions,
       is module-droid-card loaded?
    E: protocol-dbus.c: Assertion 'p' failed at
       ../src/pulsecore/protocol-dbus.c:1116, function
       pa_dbus_protocol_unregister_extension(). Aborting.

It unregisters a D-Bus extension it never registered, and the assert kills the
daemon. Upstream's `.nofail` wrapper does not help: `.nofail` tolerates a
module *declining* to load, not one that calls `abort()`.

The symptom was PulseAudio crash-looping with the working ALSA sink already
created - "Loaded module-alsa-sink", `sink.primary-out` INIT -> IDLE,
`default_sink` set - then dying two lines later, so every client saw
"Connection refused" and the device stayed silent after a reboot.

Fixed two ways: `sparse/etc/pulse/default_sailfish.pa.d/droid.pa` is a
device-specific replacement that omits the module (our `sparse/` is copied last
by `copy_files_from`, and the same package owns both paths, so there is no rpm
conflict), and `pulseaudio-modules-droid-hidl` is dropped from the adaptation
pattern. The module has no use here anyway - despite the name it no longer
speaks HIDL, it only forwards `set_parameters()` out of PulseAudio to a droid
hw module that does not exist.

#### Ruled out (all verified on device, do not re-walk these)

- `use_legacy_stream_set_parameters=true` was correct and was never the cause.
- ABOX starts fine: "Calliope is ready to sing (version:MBG0)". Early
  `calliope_sram.bin` ENOENT messages are retried and recovered; benign.
- The cs35l41 amps load DSP firmware and report "DSP1: Execution started" for
  both `14-0040` and `14-0041`.
- Masking Android's `audioserver` stops it but changes nothing. Kept anyway:
  two owners of one HAL is wrong regardless.
- `audiosystem-passthrough-dummy-af` cannot start - a real AudioFlinger already
  owns `media.audio_flinger`.
- No SysMMU/IOMMU faults occur (`fault : 0` throughout).
- The DSP logging `[ABOXCONFIG:ERROR] Invalid ABOX config MSG:` for 11-14,
  25-29 and 48 is benign. Those are `SET_SIFM5/6_*`, `SET_SIFS3/4_*`,
  `SET_PIFS0_*` and `SET_ASRC_FACTOR_CP`; this firmware implements a subset of
  the enum in `include/sound/samsung/abox_ipc.h`, and it happens on every ABOX
  resume regardless of whether audio works.

#### Still to do on audio

- **Microphone.** Working (see the table); recordings needed +20 dB of digital gain.
  The path is known: `media-mic` resolves to `dev-main-mic` + `route-ap-record`
  and lands on **WDMA1 = `hw:0,13`**. Its 10 controls are additive over the
  playback set (they only touch `DMIC1 Switch`, `ABOX NSRC0` and `ABOX SIFM0`,
  all from the initial block, not from the speaker path), so they can simply be
  appended to the TSV and paired with a `module-alsa-source`.
- **Routing is static.** One fixed path, both speakers. Headphones, earpiece,
  Bluetooth and in-call routing are not switched, because nothing is watching
  jack/route state the way `module-droid-card` did. Samsung's tables have named
  paths for all of them (`media-handset`, `media-bt-sco-headphone`,
  `media-usb-headset`, ...), so this is bookkeeping rather than research.
- **Volume is software-only.** There is no hardware volume control on an ALSA
  sink here; the amp gain is fixed at Samsung's `gain-media-dual-speaker`
  values.
- **Call audio** is untested.
- The cirrus amps fail calibration at boot:
  `cirrus cirrus_cal: Failed to open calibration file /efs/cirrus/rdc_cal: -2`.
  `/efs` is bind-mounted by `droid-wifi-firmware.sh`, which runs long after the
  amps probe. Worth fixing; speaker protection is running uncalibrated.

#### Tooling

`tools/debug/` in this tree holds both Samsung XML tables, `gen-alsa-mixer.py`
(which regenerates the control list exactly), and a standalone apply script for
experimenting without rebuilding. `alsa-utils` is now required by the
adaptation pattern, because the mixer script drives `amixer`.

### Audio — PulseAudio crash loop (fixed), no sinks at all
`pa_droid_stream_set_route()` called `create_audio_patch()` unconditionally.
That entry point arrived in Android audio device API 3.0 and is optional; this
device runs `android.hardware.audio@2.0-service` and leaves the pointer NULL,
so PulseAudio jumped to `0x0` at `droid-util.c:2146` while loading
`module-droid-card` — before any sink existed.

Fix: `sparse/etc/pulse/arm_droid_card_custom.pa` sets
`use_legacy_stream_set_parameters=true`, selecting the legacy
`AUDIO_PARAMETER_STREAM_ROUTING` path the HAL does implement. This uses the
`.ifexists` hook upstream `droid.pa` already provides, so no patch is carried
against `pulseaudio-modules-droid`.

### Telephony — `GetModems` returned an empty array
`ofono-configs-binder` was pulled in indirectly and dropped
`/etc/ofono/binder.conf` on the system, but nothing pulled in the plugin that
reads it — `/usr/lib64/ofono/plugins/` contained only `amlplugin.so`. ofonod
started clean, loaded no modem driver, and reported no modems, even though
`rild` was running with `libsec-ril.so`.

Fix: `Requires: ofono-binder-plugin` in the pattern. ofono now logs
`Connected to android.hardware.radio@1.2::IRadio/slot2` and exposes `/ril_1`
with the real modem revision.

### Sensors — every adaptor installed but disabled
`ssu-sysinfo` answers hardware-feature queries from
`/usr/share/csd/settings.d/*hw-settings*.ini`, and in
`hw_feature_get_fallback()` **only `Suspend` and `Reboot` default to true**.
No such file existed, so `ssu-sysinfo -f` printed exactly two lines. sensorfw
gates each sensor on those answers, so it disabled all of them and logged
`Plugin not available: orientationsensor`, and lipstick logged
`Could not start the orientation sensor` — despite every `libhybris*adaptor`
plugin being installed and the HAL working.

Fix: `sparse/usr/share/csd/settings.d/50-d2s-hw-settings.ini` declares the
hardware. Feature count went 2 → 33. Note the keys are the short CSD names
(`GSensor`, `ProxSensor`, `ECompass`, ...), not the `Feature_*` enum names.

### Bluetooth — three faults; two fixed, one open
1. `bluebinder` was never in the pattern. `droid-config-d2s-bluez5` ships only
   BlueZ *config*; with no binder-to-vHCI bridge, bluetoothd saw zero adapters.
   Fixed with `Requires: bluebinder`.
2. `CONFIG_BT_HCIVHCI` was off, so `/dev/vhci` could not exist and bluebinder
   died with `Failed to open /dev/vhci device`. Samsung's stock BT stack is
   entirely userspace, so this and `BT_RFCOMM` / `BT_BNEP` / `BT_HIDP` were all
   disabled. Enabled in the defconfig and flashed. **Fixed** — BlueZ now
   enumerates hci0 as "Galaxy Note 10+" at EC:AA:25:1A:5A:4B.
3. **Adapter would not power on at boot - the boot-time bluebinder instance
   wedges. FIXED.** `bluetoothd` logged `Failed to set mode: Failed (0x03)` and
   D-Bus power-on returned `org.bluez.Error.Failed`. A boot probe
   (a one-shot unit run 25 s after boot, before anything was touched by hand)
   showed this is not a race that settles and not rfkill: bluebinder was
   already `active`, `hci0` existed, and rfkill was unblocked, yet power-on
   still failed - and kept failing for the life of that instance.

   bluebinder's own log explains it:

       Own hci index: N
       delaying writing host command to controller until bt is up
       delaying writing host command to controller until bt is up
       Turning bluetooth on

   The first host commands arrive while it still considers Bluetooth down, are
   dropped, and that instance never recovers. Starting any fresh instance fixes
   it immediately - `systemctl restart bluebinder` then `Powered = true`
   succeeds every time, and a power off/on cycle works afterwards without
   touching bluebinder again.

   Fix: `sparse/etc/systemd/system/d2s-bluebinder-restart.service`, a one-shot
   that waits 15 s after `bluetooth.service` and restarts bluebinder. Note it
   must not use `/bin/systemctl` - that path does not exist here (systemctl is
   `/usr/bin/systemctl`) and the unit fails with `status=203/EXEC`; it runs
   `/bin/sh -c "systemctl restart bluebinder.service"` instead. Verified by
   reboot: the probe now reports `powered_before=true`, `set_on=()`.

4. **"Bluetooth shows no devices" was partly a measuring error.** Once the
   adapter powers on, scanning works. `StartDiscovery()` over `gdbus call`
   looks like it fails - it returns success while `Discovering` stays false and
   no devices appear - because BlueZ owns a discovery session per D-Bus client
   and `gdbus` exits as soon as the method returns, so BlueZ immediately sends
   Stop Discovery. The bluetoothd debug trace shows the whole sequence:

       mgmt send command 0x0023 -> complete 0x00
       discovering_callback() hci0 type 7 discovering 1
       adapter.c:discovery_disconnect() owner :1.233
       mgmt send command 0x0024 -> complete 0x00

   Test with a client that stays alive. There is no `bluetoothctl`, `btmgmt` or
   `btmon` on the device and python has no `dbus`/`gi` bindings, but
   `Nemo.DBus` + `sailfish-qml` works: a QML app that calls `StartDiscovery`
   and then just keeps running. Doing that found 8 nearby devices.

   Earlier diagnoses in this document were WRONG and are corrected here:
   - `Got BLUEBINDER_LOCAL_FEATURES_MASK 0x0` is not a failed handshake, just
     bluebinder printing an unset environment variable.
   - Samsung's private `vendor.samsung.hardware.bluetooth@2.0::ISehBluetooth`
     is not the obstacle. `lshal` shows the standard
     `android.hardware.bluetooth@1.0::IBluetoothHci/default` registered and
     served, which is exactly what bluebinder asks for. No patched bluebinder
     is needed.

### UI scale — `start_drag_distance` was half
`pixel_ratio` was left at 1.0. The dconf override fixed the theme scale and
icon set, but `pixel_ratio` also feeds `@START_DRAG_DISTANCE@` in
`/etc/xdg/QtProject/QPlatformTheme.conf` (`ratio * 20`), which nothing else
overrode — so drag/flick thresholds were 20px instead of 40px on a 498ppi
panel. Set `%define pixel_ratio 2.0` in `droid-config-d2s.spec`.

---

## Ambient light sensor — WORKS (earlier diagnosis was wrong)

Auto-brightness works on the device. An earlier revision of this document
called this a genuine hardware limitation; that was incorrect.

sensorfw does log `setActive(LIGHT, true) -> -22` (EINVAL), because Samsung maps
the standard Android `LIGHT` type (5) to "TMD4910 **Uncalibrated** lux Sensor",
which the HAL refuses to activate. The working sensor sits at
`SENSOR_TYPE_PRIVATE_65601` ("TMD4910 lux Sensor"), with a rear-facing
`TCS3407 Rear ALS` at 65577.

But MCE does not depend on sensorfw's ALS binding for brightness — the
sensorhub reports lux directly (visible in logcat as `lux 14`,
`Light:0,-1,20`), and auto-brightness follows it. So the sensorfw error is
cosmetic. No patch to hybris-libsensorfw is needed, and one should NOT be
carried for this.

---

## Do not retry: the SELinux "fix"

`systemd-user-sessions` and `systemd-hostnamed` SIGSEGV at
`selabel_open() -> selabel_close()` because `/etc/selinux/config` sets
`SELINUX=disabled` with no `SELINUXTYPE=`, so `selinux_policy_root()` returns
NULL — while `is_selinux_enabled()` is true once `droid-selinux-enable.sh` has
mounted selinuxfs, so systemd tries to label anyway.

Setting `SELINUX=permissive` + `SELINUXTYPE=targeted` with an empty
`file_contexts` store **did stop both SIGSEGVs** — the on-device report showed
`systemd-user-sessions` and `systemd-hostnamed` as `inactive` rather than
`failed`, with no crash entries in the journal.

But it then wedged systemd itself: the same report shows
`Failed to list units: Connection timed out`, i.e. PID 1 stopped answering
D-Bus. Once `selabel_open()` succeeds, systemd starts doing SELinux label work
against a policy whose labels do not apply to an xattr-less rootfs, and hangs.
Because PID 1 was wedged, the harness's own `reboot -f` never took effect, and
the device had to be power-cycled by hand — it hung in the window after
`switch_root` (initramfs telnet gone) and before usb-moded (no RNDIS), so there
was no listener on either interface.

Reverted; never committed to source. Leaving it alone costs only the cosmetic
hostname issue. If revisited, do it with physical access to the device.

**Addendum 2026-09-17 - what was actually different.** The empty
`file_contexts` store is now shipped, but `/etc/selinux/config` still says
`SELINUX=disabled`. That is the change that matters for PID 1: the config is
what `mac_selinux_setup()` / `selinux_init_load_policy()` act on during early
boot, and switching it to `permissive` is what changed PID 1's own SELinux
handling. PID 1 never reaches `selabel_open()` with the config as it is: if it
did, every boot before this change would have died in that SIGSEGV. The user
manager (`user@100000`) starts ~65 s after selinuxfs is mounted and has never
crashed, so it does not call it either. Evidence after the change: repeated
`systemctl daemon-reload`, `systemctl --user` restarts and unit starts all
answered normally. A clean reboot with the file in place was verified on 2026-09-17 (UI up in
~2 min, `systemctl --failed` empty, resolved/hostnamed running). Still
untested: `systemctl daemon-reexec` (e.g. from an OS update), which
previously would have hit the SIGSEGV in PID 1 itself.

**Harness lesson:** the test harness now arms an unconditional reboot in a
detached subshell at a fixed deadline *before* running any test, so a wedged
system still returns to the debug prompt without physical intervention.

---

### Video recording — FIXED

Recording froze with "Camera is not responding", and once that was past, the
camera app died in `memcpy`. Four separate faults, all fixed in the tree:

1. **libcameraservice was stale.** `startRecordingL` called `playSound()`,
   which waits forever for an AudioFlinger that does not exist here. The
   hybris patch that compiles it out was applied after droid-hal was built.
2. **The recording pool held one buffer.** `CameraSource` sizes it from
   `kKeyNumBuffers`, defaulting to ONE, and droidmedia is the only caller that
   uses CameraSource, so nothing ever set it. `droid_media_recorder_start()`
   now passes 8.
3. **libstagefright was stale too** — the real cause of the hang. Without
   hybris patch `0002-hybris-Fix-32-bit-vs-64-bit-size-mismatch-in-codecs`,
   ACodec cannot pass `VideoNativeMetadata` from the 64-bit camera app to the
   32-bit OMX service: frames were fed (`err 0`) but no buffer came back, the
   pool drained, and CameraSource logged "Waiting on an available memory base
   timed out. Dropping a recording frame." every 200 ms (116 per run).
4. **Oversized audio input crashed the app.** gst-droid's droidaenc queues
   whole GStreamer buffers (15052 bytes here) while `c2.android.aac.encoder`
   takes 4096, and `MediaCodecSource::feedEncoderInputBuffers()` memcpy's
   without checking capacity — SIGSEGV inside glibc `memcpy`, on the thread
   named `DroidMediaCodec`. `droid_media_codec_queue()` now splits PCM input
   for audio encoders into pieces of at most one AAC frame (1024 samples),
   sharing one unref across the pieces. It also clamps a bitrate of 0 to
   128 kbit/s, because the encoder's own fallback is 12403 bit/s ("Requested
   bitrate 0 unsupported") and recordings came out barely audible.

Verified without the UI (`~/.cache/claude-hadk/pl_vtest.sh` and its vtest7
variant): 5.7 s recorded, 0 dropped frames, clean stop, 143 video blocks
(~1.2 Mbit/s H.264) and 271 audio blocks (~142 kbit/s AAC). QtMultimedia
writes **Matroska** unless the application picks a container, so verify with
gst-discoverer or an EBML dump - looking for MP4 box names finds nothing.

Until droid-hal is rebuilt, the phone carries locally built copies of
libstagefright, libcameraservice and libdroidmedia in
`/usr/libexec/droid-hybris/`, with the originals kept as `.orig` in
`/var/lib/hybris-fix/`.

### Battery drain — one CPU core pinned from boot by the HWC vsync poll (FIXED)

The phone charged at ~20 mA out of an 875 mA USB budget, sat at 7-8 percent for
hours, and ran at 44 C (SoC big cluster 76 C) with the screen off.

Cause: a lipstick thread had used 10298 s of CPU over 10341 s of uptime - a
whole core, continuously, since boot. It was Samsung's HWC event thread
(`hwc_eventHndler_thread` in `/vendor/lib64/libexynosdisplay.so`, loaded
in-process by lipstick), calling `ppoll` 21000 times a second and getting an
instant return every time.

How it was found, in case something like it comes back:
- `raw_syscalls:sys_enter/sys_exit` filtered to the thread: every call is
  NR 73 (ppoll) and every return says 2 descriptors ready.
- kprobes on the poll handlers: `kernfs_fop_poll` twice and `sock_poll` once
  per iteration, so the set is two sysfs attributes plus one socket.
- Disassembling the function shows `poll(fds, 3, -1)` - an infinite timeout,
  so the only way it spins is a descriptor that is always ready.
- Decoding the live `pollfd` array (grab `arg0`/`arg1` from the tracepoint,
  then read `/proc/<lipstick>/mem`) named the culprit outright:
      fd 16 socket          events POLLIN  revents 0
      fd 17 decon_f/vsync   events POLLPRI revents POLLPRI|POLLERR
      fd 18 decon_t/vsync   events POLLPRI revents POLLPRI|POLLERR
  A sysfs attribute keeps reporting POLLERR until the reader clears it with
  lseek()+read() on the same open file description, and POLLERR is delivered
  whatever the events mask says. This HWC never reads either node - in one
  second the thread makes 21207 syscalls, all ppoll, zero reads - so the
  condition never clears. The rate is the same with the screen on and off, so
  vsync does not actually flow through these nodes on this device.

Fix (in `droid-hal-prepare.sh`, before droid-hal-init so it precedes the
opens): bind `/var/lib/hybris-fix/fake-vsync`, a plain file, over
`19050000.decon_t/vsync` only - the dead second controller.

**decon_f must keep its real node, and the spin there is NOT fixable from our
side.** Binding decon_f as well stopped the spin completely (charging went from
~20 mA to +831 mA) but cost the compositor its vsync: the display dropped to
17-18 fps, the qt5-qpa-hwcomposer-plugin falling back to its 50 ms timer. So
the HAL does use decon_f's poll *events* as its vsync signal even though it
never read()s the node.

Two further ideas were tested and disproved, so do not repeat them:
- "Keep vsync enabled so the HAL drains the node" - measured with the UI
  animating and across blank/unblank cycles: 21207, 21223, 21189, 21184,
  21228 ppoll/s, i.e. identical to idle. Enabling vsync changes nothing. The
  prepared patch to `hwcomposer_backend_v20.cpp` was reverted unbuilt.
- "Bind the node only while the screen is off" - impossible: a bind only
  affects opens made after it, and the HAL opens the fd once at startup.

Verified after a reboot: the thread makes **zero** syscalls per second and has
used 1.9 s of CPU in 192 s of uptime (was ~95 percent of a core); charging
+831 mA; battery 40.5 C; big cluster 40 C. The compositor is unaffected - the
QML camera self-test still renders and captures (IMG_00000003.jpg).

### Media playback — AAC had no codec config; 4K H.264 breaks the HW decoder

Playing a recorded video hung the Gallery ("Gallery is not responding") and
voice recordings played back silent. Two independent faults.

**1. AAC decode got no AudioSpecificConfig. FIXED.** gst-droid hands droidmedia
an empty codec_data for AAC even though the caps carry it
(`codec_data=(buffer)1190` for a camera recording), so no `kKeyESDS` is set,
`convertMetaDataToMessage()` produces no `csd-0`, and the decoder runs
unconfigured:

    C2SoftAacDec: aacDecoder_DecodeFrame decoderErr = 0x1001
    C2SoftAacDec: Invalid AAC stream ... substituting silence
    GStreamer: No valid frames decoded before end of stream

Found by logging what droidmedia actually receives (`codec_data=0 bytes`,
`esds=0 csd0=0`). Fix in `AsyncCodecSource::Create()`: for AAC decoders with no
`csd-0`, rebuild the 2-byte AudioSpecificConfig from the sample rate and
channel count that are already in the format - AAC-LC, frequency index, channel
config. 48000 Hz stereo gives 0x1190, byte-identical to the container's own
copy. Verified: `Rebuilt AAC csd-0 1190 for 48000 Hz, 2 channel(s)`, zero
decoder errors, audio decodes to EOS.

**2. The hardware H.264 decoder failed on 4K. FIXED (two bugs in droidmedia).**
The camera records 3840x2160 (jolla-camera has no resolution setting), and
every recording hit both of these:

- *Output buffers could not be allocated.* `private.cpp` asked the BufferQueue
  for `NUM_BUFFER_SLOTS / 2` = 32 acquired buffers. At 4K a YCbCr_420_888
  buffer is ~12.4 MB, so the pool wanted over 400 MB and the vendor decoder
  gave up:
      OMXNodeInstance: useBuffer(Exynos.avc.dec, Output:1 ...) (0x80001000)
      AsyncCodecSource: Codec (OMX.Exynos.avc.dec) reported error : 0x-12
  `_DroidMediaBufferQueue()` now takes the frame size and caps the count at 8
  above 1920x1088.

- *Teardown aborted the process.* `droid_media_codec_stop()` called
  `disconnectListener()` (i.e. `consumerDisconnect()`, abandoning the queue)
  BEFORE stopping the codec, so in-flight output buffers hit -ENODEV:
      ACodec: queueBuffer failed in onOutputBufferDrained: -19
      ACodec: signalError(omxError 0x80001001, internalError -19)
      F/MediaCodec: postPendingRepliesAndDeferredMessages: mReplyID == null,
                    from kWhatError:STOPPING following kWhatError:STOPPING
  AOSP's LOG_ALWAYS_FATAL_IF then killed the player - SIGABRT in codec_looper,
  ~2 of every 3 playbacks. The queue is now torn down after the codec stops,
  matching what the pre-Android-7 branch of the same function already did.

Verified: 5 consecutive hardware playbacks of a 4K recording, all RC=0 at
`sync=true` (4.67 s wall for a 3.99 s clip), zero crashes. The temporary
software-decode workaround (`GST_PLUGIN_FEATURE_RANK`) has been removed from
the tree and the device, so playback keeps native DroidMediaBuffer frames
through droideglsink - libav decoding was reliable but went through a
conversion/scaling path that visibly softened the picture.

### Camera — two separate faults, both from one missing library

`libandroidicu.so` broke the camera twice, in two different places needing two
different fixes. It lives in the **ART** apex on this base (com.android.i18n
here ships only etc/icu, no lib/ at all).

**Fault 1 - minimedia crash-loop.** `ld.config.txt` maps executables to linker
namespaces by path prefix, and linkerconfig only emits Android's own paths.
droidmedia's binaries live at `/usr/libexec/droid-hybris/system/bin/`, matched
no `dir.*` section, got bionic's namespace-less fallback, and died:

    CANNOT LINK EXECUTABLE ".../minimediaservice":
    library "libandroidicu.so" not found: needed by /system/lib/libmedia.so

droid-hal-init respawned it every 5s forever. Fixed by prepending
`dir.system = /usr/libexec/droid-hybris/system/bin/` to the generated
ld.config.txt, and chmod 0644 (minimedia runs as user `media`; a 0600 config is
silently unreadable to it and the linker falls back without saying why).

**Fault 2 - gst-droid blacklisted.** With minimedia fixed the camera still
showed SMPTE colour bars with an animating noise block, identically on both
cameras, and logcat had *zero* camera entries. That was the giveaway: the
Android camera stack was never being reached at all. The bars were GStreamer's
`videotestsrc`, which jolla-camera falls back to when it finds no camera:

    attempt to load plugin "/usr/lib64/gstreamer-1.0/libgstdroid.so"
    library "libandroidicu.so" not found
    Aborted (core dumped)
    → GStreamer blacklists the plugin (registry keeps the filename, no elements)
    → droidcamsrc never registers
    → jolla-camera: "No front camera detected" → videotestsrc

The Fault 1 fix does **not** help here. libhybris does not use ld.config.txt's
dir-matching when a *glibc* process (gst-inspect, jolla-camera) loads an
Android .so — verified by adding `dir.system = /usr/` and watching it change
nothing. hybris resolves from its own search path instead, which includes the
droid-hybris lib dir where libdroidmedia.so lives but not /apex.

Fixed in `droid-apex-bind.sh` by symlinking the ART apex's ICU libraries in
beside libdroidmedia.so. Symlinks are fine despite /apex being mounted later -
they resolve when used, not when created.

Verified from a cold boot with the symlinks deleted first, so the boot script
had to recreate them: real viewfinder, both cameras, and the Android stack
genuinely running (`ExynosCameraMCPipe ... sensorStream`, `prepare() is
succeed`, real crop sizes 3216x2208).

### Settings > About showed UNKNOWN for model and manufacturer

`ssusysinfo` resolves the device model in exactly three ways, in order:
`[file.exists]` in `board-mappings.d/*.ini`, then **`MER_HA_DEVICE` from
`/etc/hw-release`**, then `[cpuinfo.contains]`. Nothing else in hw-release is
consulted for identification — not `ID`, not `HW_MODEL`, not `NAME`.

Our `/etc/hw-release` had no `MER_HA_DEVICE`, so none of the three matched,
`ssusysinfo_device_model()` returned `UNKNOWN`, and every attribute keyed off
it followed. Verified on-device:

    before:  model: UNKNOWN   manufacturer: UNKNOWN   pretty_name: UNKNOWN
    after:   model: d2s       manufacturer: Samsung   pretty_name: Galaxy Note 10+

Fix: one line, `MER_HA_DEVICE=d2s`, in `sparse/etc/hw-release`.

A hand-written `sparse/usr/share/ssu/board-mappings.d/d2s.ini` had been added
earlier to try to fix this. It could never have worked — it used a
`[file.d2s]` section with a path-to-regex mapping, and no such section exists
in ssusysinfo (the real one is `[file.exists]`, keyed model-name to file path,
existence only, no regex). It also shadowed the generated `05-samsung-d2s.ini`
`[d2s]` section. Deleted; the generated file supplies everything once
`MER_HA_DEVICE` is set.

## Android apps

**Alien Dalvik is not available and cannot be made available.** It is
proprietary Jolla software, licensed per device and delivered only to
officially supported devices through the Jolla Store. Verified: nothing
matching alien/apkd/dalvik is installed, there is no `/opt/alien`,
`app_process` or `apkd-install`, and `zypper search aliendalvik` / `apkd`
return no matches in any configured repo. The one hit, `feature-alien` in
`customer-jolla`, is a 452-byte stub requiring only `/bin/sh` and `coreutils`
— a feature marker, not a runtime.

**Waydroid** is the open-source alternative. The kernel is now prepared for it:

| Requirement | State |
|---|---|
| `ANDROID_BINDER_IPC`, `ASHMEM` | already on |
| `NAMESPACES`, `CGROUPS`, `VETH`, `FUSE_FS`, `TUN` | already on |
| `USER_NS`, `BRIDGE` (+`STP`,`LLC`) | enabled |
| `OVERLAY_FS` | enabled |
| `SQUASHFS` (+`XZ`, `ZLIB` decompressors) | enabled |
| `MEMFD_CREATE` | not a Kconfig symbol in 4.14 — `memfd_create()` is compiled unconditionally, so it was already available |
| `ANDROID_BINDERFS` | **impossible here** — binderfs arrived in 5.0; this is 4.14.253 and the symbol is absent from `drivers/android/Kconfig` |

Because binderfs does not exist, the container gets its own binder nodes from
the static device list instead — the first three are claimed by the host HAL:

    CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder,anbox-binder,anbox-hwbinder,anbox-vndbinder"

Waydroid is pointed at the `anbox-*` trio via `waydroid.cfg`.

Note `SQUASHFS=y` alone mounts nothing — a decompressor is required, hence XZ
and ZLIB. Likewise `BRIDGE` selects `STP`/`LLC`, stated explicitly rather than
relying on Kconfig select ordering in this tree.

This makes the kernel *capable* of running Waydroid. Actually running it still
needs the SailfishOS:Chum repo added, the Waydroid packages installed and
`waydroid init` run — none of which is verified yet, and none of which can be
until the kernel is flashed.

## Needs the device in hand

1. Flash the rebuilt kernel — Bluetooth (`CONFIG_BT_HCIVHCI`) and
   `CONFIG_USB_CONFIGFS_MASS_STORAGE`.
2. Insert a SIM and confirm calls / SMS / mobile data.
3. Test camera, GPS fix, vibration, NFC, S-Pen.
4. Optionally switch `function_mass_storage` from `acm.0` to `mass_storage.usb0`
   in `/etc/usb-moded/25-configfs-d2s.ini` once the kernel supports it.
