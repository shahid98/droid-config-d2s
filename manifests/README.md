# repo local manifests

Copies of `$ANDROID_ROOT/.repo/local_manifests/`, which is not under version
control - a fresh `repo init` starts without them and `repo sync` would then
pull none of the device, kernel or vendor trees this port needs.

On a new checkout:

    mkdir -p .repo/local_manifests
    cp hybris/droid-configs/manifests/*.xml .repo/local_manifests/
    repo sync -c -j4 --no-clone-bundle

`d2s.xml` pins the LineageOS device/kernel/vendor trees (and this port's own
branches); `roomservice.xml` is what `breakfast d2s` added by itself.
