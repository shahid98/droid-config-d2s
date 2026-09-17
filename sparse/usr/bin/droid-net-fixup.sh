#!/bin/sh
# Make Sailfish networking work alongside Android's netd.
#
# netd owns the network stack on a hybris device and does two things that break
# connman:
#
#  1. It DELETES the standard "32766: from all lookup main" policy rule and
#     installs its own scheme, ending in "32000: from all unreachable".
#     connman writes every route into the main table, which is then never
#     consulted, so every lookup returns ENETUNREACH - an interface with a
#     valid address and a link route to its gateway still cannot reach it.
#     That is what produced connman's "Adding host route failed (Network is
#     unreachable)", the blank IPv4 gateway in Settings, and "Limited
#     connectivity".
#
#  2. Its iptables filter chains drop traffic that is not marked with a netId
#     fwmark and owned by a registered Android network. connman does not mark
#     packets, so once routing worked the packets still went nowhere
#     (0% received rather than ENETUNREACH).
#
# Fix: restore a main-table lookup ahead of netd's unreachable catch-all, and
# stop the filter table dropping our traffic. Android's per-app/per-UID
# firewall has no meaning on Sailfish - there is no Android app sandbox here.
#
# Verified working: ping gateway 11ms, ping 8.8.8.8 18ms, HTTP/1.1 200 OK.
B=/usr/bin/busybox
IP=/usr/sbin/ip
IPT=/sbin/iptables
IPT6=/sbin/ip6tables
CM=/usr/bin/connmanctl
PRIO=25000

# Both address families: netd installs the same rule scheme for IPv6. With only
# the IPv4 rule, the carrier's IPv6 address and default route were unusable -
# every IPv6 connect failed at once with ENETUNREACH, which broke sites whose
# scripts fetch from dual-stack hosts (fast.com's api.fast.com).
apply() {
    for f in -4 -6; do
        $IP $f rule show 2>/dev/null | $B grep -q "^$PRIO:" || \
            $IP $f rule add from all lookup main priority $PRIO 2>/dev/null
    done
    for c in INPUT OUTPUT FORWARD; do
        $IPT -P $c ACCEPT 2>/dev/null
        $IPT6 -P $c ACCEPT 2>/dev/null
    done
}

# connman will not start a provisioned service on its own: this build rejects
# the AutoConnect key in a .config file ("Unknown configuration key
# AutoConnect") and marks provisioned services Immutable with
# AutoConnect=False, so they sit at State=idle forever. Nudge whichever wifi
# service is configured until one is up.
connect_wifi() {
    # Already have a default route? Nothing to do.
    $IP route show table main 2>/dev/null | $B grep -q '^default ' && return 0

    svc=$($CM services 2>/dev/null | $B grep -m1 -E '^[*A ]*[A-Za-z0-9]' \
          | $B grep 'wifi_' | $B sed 's/.* //')
    [ -n "$svc" ] || return 0

    st=$($CM services "$svc" 2>/dev/null | $B grep -m1 ' State' | $B sed 's/.*= //')
    case "$st" in
        online|ready|association|configuration) return 0 ;;
    esac

    $CM config "$svc" --autoconnect yes >/dev/null 2>&1
    $CM connect "$svc" >/dev/null 2>&1
}

# DNS. Sailfish's connman is built --with-dns-backend=systemd-resolved: it hands
# the connected service's servers to resolved over D-Bus, and /etc/resolv.conf
# is meant to be resolved's stub (nameserver 127.0.0.53), which never changes.
#
# It has to stay constant because sailjail gives every sandboxed app (browser,
# store apps) a private COPY of /etc/resolv.conf taken at launch
# (Internet.permission: private-etc ...,resolv.conf). When this script wrote
# the live servers into the file instead, an app started on wifi kept the home
# ISP's resolvers after a switch to mobile data - the browser (prestarted at
# boot) could not open any page on LTE while everything outside it worked.
#
# resolved used to SIGSEGV at startup (libselinux crashed when it found no
# file-context database; see /etc/selinux/targeted/contexts/files/
# file_contexts), and then could not open sockets at all (see
# systemd-resolved.service.d/50-d2s-inet.conf), which is why this script took
# over DNS in the first place.
STUB=../run/systemd/resolve/stub-resolv.conf
SYSTEMCTL=/usr/bin/systemctl
RESOLVE=/usr/bin/systemd-resolve

link_stub() {
    [ "$($B readlink /etc/resolv.conf 2>/dev/null)" = "$STUB" ] || \
        $B ln -sfn "$STUB" /etc/resolv.conf
}

sync_resolv() {
    case "$($SYSTEMCTL is-active systemd-resolved 2>/dev/null)" in
        active|activating|reloading)
            link_stub
            repush_dns
            return 0 ;;
    esac
    write_resolv
}

# Sets $ifc and $ns (interface and nameservers) for the connected service.
# That has to be any service type: taking the first *wifi* service listed,
# connected or not, once left the home ISP's resolvers in place on mobile data.
# connmanctl lists services in preference order and flags the connected ones
# with O (online) or R (ready) in the third column, e.g.
#     *AO Bell        cellular_302610051797915_context1
active_service() {
    ifc=""
    ns=""
    svc=$($CM services 2>/dev/null | $B grep -m1 -E '^..[OR] ' | $B sed 's/.* //')
    [ -n "$svc" ] || return 1
    info=$($CM services "$svc" 2>/dev/null)
    ifc=$(echo "$info" | $B grep -m1 'Ethernet =' \
          | $B sed -n 's/.*Interface=\([^,]*\),.*/\1/p')
    ns=$(echo "$info" | $B grep -m1 'Nameservers =' \
         | $B sed 's/.*\[ *//; s/ *\].*//; s/,/ /g')
    [ -n "$ns" ]
}

# connman hands servers to resolved only when a service changes, so after a
# resolved restart the link has none until the next network change, and
# lookups quietly go to resolved's built-in public fallback servers instead of
# the network's own. Hand them over again whenever resolved has none for the
# connected interface. Link-local servers are skipped, as connman does.
repush_dns() {
    active_service || return 0
    [ -n "$ifc" ] || return 0
    $RESOLVE --status "$ifc" 2>/dev/null | $B grep -q 'DNS Servers:' && return 0
    args=""
    for n in $ns; do
        case "$n" in
            fe80:*|FE80:*) ;;
            *) args="$args --set-dns=$n" ;;
        esac
    done
    [ -n "$args" ] && $RESOLVE -i "$ifc" $args >/dev/null 2>&1
}

# Fallback for when resolved is not running: write the connected service's
# nameservers directly, so DNS still follows the network.
write_resolv() {
    active_service || return 0
    # IPv4 first: the resolver only uses the first three entries, and IPv6 may
    # have no default route (the carrier gives host routes only). Link-local
    # IPv6 servers (the cellular service lists fe80::2) are unusable without a
    # scope id, so leave them out.
    v4=""
    v6=""
    for n in $ns; do
        case "$n" in
            fe80:*|FE80:*) ;;
            *:*) v6="$v6 $n" ;;
            *) v4="$v4 $n" ;;
        esac
    done
    [ -n "$v4$v6" ] || return 0
    tmp=/etc/.resolv.conf.new
    : > "$tmp"
    for n in $v4 $v6; do echo "nameserver $n" >> "$tmp"; done
    if ! $B cmp -s "$tmp" /etc/resolv.conf 2>/dev/null; then
        $B mv "$tmp" /etc/resolv.conf
    else
        $B rm -f "$tmp"
    fi
}

# Point /etc/resolv.conf at the stub straight away, before the wait below: the
# user session prestarts sandboxed apps (the browser booster) early in boot,
# and each copies the file as it is at that moment.
case "$($SYSTEMCTL is-enabled systemd-resolved 2>/dev/null)" in
    enabled*|static) link_stub ;;
esac

# netd installs its rules while droid-hal-init comes up; adding ours earlier
# would just be overwritten. Wait for its catch-all to appear.
i=0
while [ $i -lt 90 ]; do
    $IP rule show 2>/dev/null | $B grep -q 'unreachable' && break
    $B sleep 1
    i=$((i+1))
done

apply
$IPT -F 2>/dev/null      # drop netd's filter rules once, at startup
$IPT6 -F 2>/dev/null
connect_wifi
sync_resolv

# netd re-asserts its rules on network events, so keep checking. Cheap: a
# couple of reads and, normally, no writes. Short enough that DNS follows a
# wifi <-> mobile data switch before the user notices.
while : ; do
    $B sleep 10
    apply
    connect_wifi
    sync_resolv
done
