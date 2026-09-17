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
CM=/usr/bin/connmanctl
PRIO=25000

# netd installs its rules while droid-hal-init comes up; adding ours earlier
# would just be overwritten. Wait for its catch-all to appear.
i=0
while [ $i -lt 90 ]; do
    $IP rule show 2>/dev/null | $B grep -q 'unreachable' && break
    $B sleep 1
    i=$((i+1))
done

apply() {
    $IP rule show 2>/dev/null | $B grep -q "^$PRIO:" || \
        $IP rule add from all lookup main priority $PRIO 2>/dev/null
    for c in INPUT OUTPUT FORWARD; do
        $IPT -P $c ACCEPT 2>/dev/null
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

# connman's own DNS proxy on 127.0.0.1 never comes up here (its dnsproxy wants
# iptables redirection, and netd owns those tables), so /etc/resolv.conf has to
# be written directly. Take the nameservers from whichever service is online so
# DNS follows the network instead of hardcoding one router.
sync_resolv() {
    svc=$($CM services 2>/dev/null | $B grep -m1 'wifi_' | $B sed 's/.* //')
    [ -n "$svc" ] || return 0
    ns=$($CM services "$svc" 2>/dev/null | $B grep -m1 'Nameservers =' \
         | $B sed 's/.*\[ *//; s/ *\].*//; s/,/ /g')
    [ -n "$ns" ] || return 0
    new=""
    for n in $ns; do new="$new nameserver $n"; done
    [ -n "$new" ] || return 0
    tmp=/etc/.resolv.conf.new
    : > "$tmp"
    for n in $ns; do echo "nameserver $n" >> "$tmp"; done
    if ! $B cmp -s "$tmp" /etc/resolv.conf 2>/dev/null; then
        $B mv "$tmp" /etc/resolv.conf
    else
        $B rm -f "$tmp"
    fi
}

apply
$IPT -F 2>/dev/null      # drop netd's filter rules once, at startup
connect_wifi
sync_resolv

# netd re-asserts its rules on network events, so keep checking. Cheap: a
# couple of reads and, normally, no writes.
while : ; do
    $B sleep 30
    apply
    connect_wifi
    sync_resolv
done
