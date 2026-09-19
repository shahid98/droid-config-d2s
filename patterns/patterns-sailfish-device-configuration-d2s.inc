# Feel free to disable non-critical HA parts during devel by commenting lines out
# Generated in hadk by executing: rpm/dhd/helpers/add_new_device.sh

%package -n patterns-sailfish-device-configuration-d2s
Summary: Jolla Configuration d2s
Requires: patterns-sailfish-device-configuration-common-d2s
Requires: patterns-sailfish-device-adaptation-d2s

# For devices with cellular modem. Those without one, please comment out:
Requires: patterns-sailfish-cellular-apps

# Early stages of porting benefit from these:
Requires: patterns-sailfish-device-tools

Requires: sailfish-content-graphics-z%{icon_res}

# For multi-SIM devices
#Requires: jolla-settings-networking-multisim

# For devices which support NFC
#Requires: jolla-settings-system-nfc
#Requires: nfcd-dbuslog-plugin
#Requires: nfcd-mce-plugin

# Introduced starting Sailfish OS 2.0.4.x:
# 3rd party accounts like Twitter, VK, cloud services, etc
Requires: jolla-settings-accounts-extensions-3rd-party-all

# Introduced starting Sailfish OS 2.1.1.26
# Required for Jolla Store Access
Requires: patterns-sailfish-consumer-generic

# For Mozilla location services (online)
Requires: geoclue-provider-mlsdb

# Sailfish Secrets. Not pulled in by any pattern this port uses, so the image
# shipped without it entirely - `rpm -qa | grep sailfishsecrets` was empty.
#
# That blocks installing Storeman, which is the first thing most people do on
# a community port. Its rpm fails dependency resolution outright:
#   libsailfishsecrets.so.0()(64bit) is needed by harbour-storeman
#   sailfishsecretsdaemon-secretsplugins-default is needed by harbour-storeman
# and the failure surfaces in the UI as a bare "installation failed", with the
# real reason only visible to `rpm -i --test`.
#
# These are stock platform components present on official devices, not
# Storeman-specific extras; the daemon plus its default secrets plugin is the
# minimum that satisfies the above.
Requires: libsailfishsecrets
Requires: sailfishsecretsdaemon
Requires: sailfishsecretsdaemon-secretsplugins-default

# Devices with 2G or more memory should also include this booster
# to improve camera startup times and the like
#Requires: mapplauncherd-booster-silica-qt5-media

%description -n patterns-sailfish-device-configuration-d2s
Pattern with packages for d2s configurations

%files -n patterns-sailfish-device-configuration-d2s
