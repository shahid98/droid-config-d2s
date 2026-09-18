# HANDOFF: Sailfish OS port for Samsung Galaxy Note 10+ Exynos (d2s)

Read this fully before doing anything. This is a mid-flight port. The build is DONE;
we are stuck on ONE remaining problem: the device bootloops and we can't capture the panic.

## THE DEVICE
- Samsung Galaxy Note 10+ LTE, model **SM-N975F**, codename **d2s**, SoC **Exynos 9825**
  (uses the shared exynos9820 kernel/device family; GPU Mali-G76).
- Bootloader UNLOCKED. Anti-rollback binary = 9 (B9/K9/S9).
- adb serial: RF8M80878RY.

## HOST / BUILD ENV
- Beelink SER8, Ubuntu 22.04, Ryzen 8845HS, 28GB RAM, 200GB+ free.
- Sailfish OS Platform SDK + HABUILD (Ubuntu) chroot installed. Target: samsung-d2s-aarch64,
  tooling SailfishOS-5.1.0.11.
- Source tree at **~/hadk** ($ANDROID_ROOT). Base: **hybris-18.1** (LineageOS 18.1 / Android 11), full 64-bit.
- SHELL NESTING (critical): host -> `sfossdk` (PlatformSDK) -> `ubu-chroot -r $PLATFORM_SDK_ROOT/sdks/ubuntu` (HABUILD_SDK [d2s]).
  All `make`/`$ANDROID_ROOT`/`external/*` commands ONLY work inside the innermost HABUILD shell.
- After EVERY re-entry to HABUILD you MUST run:
    cd $ANDROID_ROOT && source build/envsetup.sh
    export TEMPORARY_DISABLE_PATH_RESTRICTIONS=true
    export BUILD_BROKEN_USES_BUILD_HOST_EXECUTABLES=true
    breakfast d2s        # <-- without this it defaults to aosp_arm and breaks

## WHAT'S BUILT & WORKING (all done from source)
- LineageOS 18.1 device/kernel/vendor trees synced via local manifest .repo/local_manifests/d2s.xml
  (LineageOS/android_device_samsung_d2s, ...exynos9820-common, ...kernel_samsung_exynos9820,
   hardware_samsung, samsung_slsi/sepolicy, TheMuppets proprietary_vendor_samsung @ lineage-18.1).
- libhybris added: mer-hybris/libhybris @ android11 branch, path external/libhybris.
  NOTE: it has a git SUBMODULE (mlehtima/libhybris-1) that must be `git submodule update --init`.
- `make hybris-hal droidmedia` builds clean. Kernel (exynos9820, 4.14) builds.
- droid-hal-d2s, droid-config-d2s, droid-hal-version-d2s, droidmedia-localbuild, and the
  middleware (libhybris, pulseaudio-modules-droid + hidl, mce-plugin-libhybris) all built as RPMs.
- `build_packages.sh --mic` produced a flashable image:
    ~/hadk/SailfishOScommunity-release-5.1.0.11-d2s/sailfishos-d2s-release-5.1.0.11.zip
    (+ sfe-d2s-5.1.0.11.tar.bz2 rootfs)
- kernel passes `hybris/mer-kernel-check/mer_verify_kernel_config .../KERNEL_OBJ/.config` with 0 ERRORs.

## FIXES APPLIED DURING BUILD (so a rebuild reproduces them)
- Neutralized `hardware/samsung/AdvancedDisplay/Android.bp` (LOS-only, needs org.lineageos.settings.resources).
- Stubbed `external/chromium-webview/Android.mk` (empty; WebView not synced).
- Removed `external/audioflingerglue` (wrong branch; not needed for boot).
- Disabled `libui_compat_layer` line in hybris/hybris-boot/Android.mk (d2s has gralloc).
- Kernel defconfig `arch/arm64/configs/exynos9820-d2s_defconfig` additions:
    CONFIG_SYSVIPC, FHANDLE, DEVTMPFS(_MOUNT), VT, NETFILTER_XT_MATCH_MULTIPORT,
    INET_AH, INET_IPCOMP, L2TP(_V3/_IP), CONFIG_LOCALVERSION_AUTO=n,
    and (for debugging) CONFIG_PSTORE*, CONFIG_PANIC_ON_OOPS, CONFIG_PRINTK_PROCESS.
  Also de-dirtied kernel/samsung/exynos9820/scripts/setlocalversion (removed -dirty).
- hybris/hybris-boot/fixup-mountpoints: added a no-op `"d2s")` case (fstab already uses full by-name paths).
- fs_config_generator.py (build/make/tools/fs_config/): ported to python3 (prints, ConfigParser as configparser,
  iteritems->items via 2to3, int(aid,0) for int/str compare). Also `ln -sf python3 /usr/bin/python`.
- droid-hal spec rpm/droid-hal-d2s.spec: %define droid_target_aarch64 1; straggler_files for
  /bugreports /d /product /sdcard /system_ext; %define _unpackaged_files_terminate_build 0.
- rpm/dhd/droid-hal-device.inc: removed the `.la` %files line; made zygote cp non-fatal (|| true);
  changed kernel_release sort to `| head -n1`.
- droid-config: removed duplicate external/libhybris?  NO -> removed
  hybris/droid-configs/droid-configs-device/sparse/etc/ofono/binder.conf (conflicts ofono-configs-binder);
  and %exclude attempt reverted. droid-hal-version-d2s.spec was hand-written.
- p7zip lib7z fails to link (undefined SysStringLen etc.) on full `bacon` -> we neutralized
  external/p7zip/Android.mk (echo "# disabled") because it's OTA-only, not needed for system/vendor.
  (Full LOS `bacon`/`systemimage` also hit CORRUPTED artifacts: libncurses.so "unknown file type",
   androidx.preference package-res.apk "Invalid file" -> from interrupted builds; would need `make clean`.)

## FLASHING STATE (Phase 5)
- Flashed stock Samsung firmware N975FXXS9HWG9 (Android 12, binary 9 = matches device, SAFE) via heimdall.
  All 20 partitions flashed 100% OK. (This is the correct Android-12 firmware base LOS 18.1 needs.)
- LineageOS 18.1 base: used PREBUILT `lineage-18.1-20211112-UNOFFICIAL-d2s.zip` (Ivan_Meler, in ~/Downloads).
  Official LOS 18.1 d2s downloads are DEAD (EOL). We built our own LOS recovery.img (make recoveryimage, WORKS).
- Flashing method that works: LOS recovery -> Format data -> adb sideload/push.
  NOTE: `adb sideload` of the SFOS zip stalls at ~47% ("failed to read command: Success") and writes NOTHING.
  WORKAROUND (this works): flash LOS recovery, then MANUALLY:
    adb push <sailfish zip> /data/sfos.zip ; unzip in /data/extract ;
    the rootfs tar is bz2 and recovery has NO bzip2 -> decompress on PC (bunzip2) and push the plain .tar,
    then `tar xvf sfos.tar -C /data/.stowaways/sailfishos/` ; `dd if=hybris-boot.img of=.../by-name/boot`.
  Rootfs is correctly installed at /data/.stowaways/sailfishos/ (bin etc usr var init lib64 sbin ... present).

## THE ROOT-CAUSE BUG WE FOUND AND FIXED (important!)
- soong's PATH-tool sandbox BLOCKS `cpio` ("cpio is not allowed to be used") during hybris-boot build,
  so `boot-initramfs.gz` was **20 bytes (empty ramdisk)** on every normal build. Symlinking cpio into
  prebuilts/build-tools and BUILD_BROKEN_USES_BUILD_HOST_EXECUTABLES did NOT bypass it.
- FIX (must be done manually every hybris-boot build):
    cd out/target/product/d2s/obj/ROOT/hybris-boot_intermediates/initramfs
    find . | cpio -H newc -o | gzip -9 > ../boot-initramfs.gz      # -> ~1.6MB, real
    cd $ANDROID_ROOT
    out/soong/host/linux-x86/bin/mkbootimg \
      --kernel out/target/product/d2s/obj/KERNEL_OBJ/arch/arm64/boot/Image \
      --ramdisk out/target/product/d2s/obj/ROOT/hybris-boot_intermediates/boot-initramfs.gz \
      --base 0x10000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
      --tags_offset 0x00000100 --pagesize 2048 --header_version 1 \
      --cmdline "androidboot.selinux=permissive buildvariant=userdebug" \
      --output out/target/product/d2s/hybris-boot.img
  Boot image header args (base/offsets/cmdline) were matched to the working LOS boot.img header
  (kernel_addr 0x10008000, tags 0x10000100, page 2048, header v1).
- Verified fix: hybris-boot.img now has ramdisk_size ~1,590,738 (bootinfo.py). Confirmed NOT 20 bytes.

## THE REMAINING PROBLEM (WHERE WE ARE STUCK)
Even with the real 1.6MB initramfs flashed, the device **bootloops at the Samsung logo**:
- USB enumerates repeatedly as **18d1:d001 "samsung" bcdDevice=4.14** (kernel + USB gadget come up), then resets ~10min cycle.
- NO cdc_ether/rndis/usb0 network interface EVER appears. No telnet. Tried both gzip AND lz4 ramdisk - same.
- hybris-boot USB-serial debug method: iSerial stays plain "RF8M80878RY", never changes to "Mer Debug..." =>
  per Halium docs, **initramfs /init is NOT running** (very early kernel/init failure).
- No /data/.stowaways/sailfishos/init.log, no /diagnosis.log, /sys/fs/pstore/ EMPTY.
- /proc/last_kmsg and /proc/first_kmsg only ever show the RECOVERY boot (Samsung OVERWRITES the crash log
  on each boot), so we CANNOT capture the actual Sailfish-attempt panic. This is the wall.

## KEY DIAGNOSTIC CLUE (last finding)
- The RECOVERY kernel unpacks ITS initramfs fine: last_kmsg shows
  "Trying to unpack rootfs image as initramfs... Freeing initrd memory: 8412K ... Freeing unused kernel memory".
  => kernel + initramfs-unpacking WORKS on this hardware.
- Samsung bootloader (S-Boot) loads DTB and DTBO from SEPARATE partitions (androidboot.dtbo_idx=9),
  does AVB (VERIFICATION_DISABLED set = ok), then "Starting kernel..." then our boot dies silently.
- LEADING HYPOTHESIS: this bootloader may expect the ramdisk EMBEDDED in the kernel Image
  (like recovery) rather than as a SEPARATE ramdisk in the boot image, OR there's a kernel/DTB mismatch.
  RECOVERY works because its ramdisk is embedded/handled the way S-Boot expects.

## NEXT THINGS TO TRY (in order)
1. **Embed initramfs into kernel**: set CONFIG_INITRAMFS_SOURCE to the initramfs staging dir and rebuild the
   kernel so the ramdisk is baked into Image (boots exactly like the working recovery kernel). Most promising.
2. Capture the real panic: needs UART/serial cable, OR Samsung sec_debug "upload mode", OR compare the
   hybris-boot.img byte-layout vs a KNOWN-WORKING hybris/Halium/UT boot image for exynos9825.
3. Escalate to #sailfishos-porters (Libera/OFTC IRC) + SFOS forum HW Adaptation; ping the exynos9825
   Ubuntu Touch / Halium porter (ubports community-ports android11 samsung-galaxy-note-10-plus) - they
   booted THIS exact SoC and will know the boot-image requirement.

## REFERENCE FILES PRODUCED THIS SESSION (in /mnt/user-data/outputs earlier, may need re-saving)
- d2s.xml (local manifest), bootinfo.py (boot image header inspector),
  d2s-sailfish-port-summary.md, d2s-debugging-methods.md, d2s-help-post-FINAL.md.

## USEFUL COMMANDS
- Inspect a boot image:  python3 bootinfo.py <img>   (checks ramdisk_size != 20, header_version, dtb)
- Working LOS boot.img header: base 0x10000000, kernel 0x10008000, tags 0x10000100, page 2048, hdr v1,
  ramdisk_size 0 (system-as-root), cmdline "androidboot.selinux=permissive buildvariant=userdebug".
- Reference working kernel to diff against:
  gitlab.com/ubports/porting/community-ports/android11/samsung-galaxy-note-10-plus/kernel-samsung-exynos9825 (halium-11.0)
