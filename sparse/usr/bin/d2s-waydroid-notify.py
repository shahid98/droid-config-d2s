#!/usr/bin/python3
"""Forward Android notifications out of the Waydroid container to Sailfish.

Waydroid bridges the clipboard but not notifications, so a WhatsApp message
arriving in the container is only visible inside the container: nothing reaches
the events view, the lock screen or the LED. For anything used as a messenger
that makes the container a dead end.

There is no notification listener to hook: that would need an Android app inside
the container signed and installed for the purpose. But `dumpsys notification`
reports the active notifications in a parseable form, so this polls it and
re-posts what is new to the host's org.freedesktop.Notifications, which is what
Sailfish's own notifications go through.

Consequences of doing it this way, all deliberate:

  * A poll interval of a few seconds, so a notification can be that late.
  * Only what dumpsys shows: package, title and text. No actions, no inline
    reply, no icons from inside the container.
  * Tapping the notification opens Waydroid, not the app that posted it -
    launching a specific Android activity would need the session's own IPC.
  * Ongoing notifications (the "running" ones apps keep pinned) are skipped,
    otherwise they would be re-posted forever.

Notifications are keyed by package + tag + title + text, so an unchanged one is
posted once. When a notification disappears from dumpsys its key is forgotten,
so the same message arriving again is posted again.
"""

import hashlib
import os
import re
import subprocess
import sys
import time

LXC_PATH = "/var/lib/waydroid/lxc"
CONTAINER = "waydroid"
USER = "defaultuser"
UID = 100000
INTERVAL = 4          # seconds between polls
BODY_MAX = 200

# Packages whose notifications are noise on the Sailfish side: the container's
# own housekeeping, and Android's persistent system entries.
SKIP_PACKAGES = {
    "android",
    "com.android.systemui",
    "com.android.settings",
    "org.lineageos.waydroidupdater",
    "com.google.android.gms",
}

RECORD = re.compile(r"NotificationRecord\(0x[0-9a-f]+: pkg=(\S+).*?\btag=(\S*)")
TITLE = re.compile(r"android\.title=String \((.*)\)\s*$")
TEXT = re.compile(r"android\.text=String \((.*)\)\s*$")
FLAGS = re.compile(r"flags=0x([0-9a-f]+)")

FLAG_ONGOING_EVENT = 0x2
FLAG_FOREGROUND_SERVICE = 0x40


def container_state():
    try:
        out = subprocess.run(["lxc-info", "-P", LXC_PATH, "-n", CONTAINER, "-sH"],
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return ""


def dumpsys():
    """Read the container's active notifications.

    Deliberately does NOT thaw the container: Waydroid freezes it when no
    session UI is attached, and waking it every few seconds to poll would keep
    the phone busy for nothing. A frozen container is showing nobody anything,
    so there is nothing to forward.
    """
    if container_state() != "RUNNING":
        return ""
    try:
        out = subprocess.run(
            ["lxc-attach", "-P", LXC_PATH, "-n", CONTAINER, "--",
             "/system/bin/sh", "-c", "dumpsys notification --noredact"],
            capture_output=True, text=True, timeout=20)
        return out.stdout
    except (subprocess.SubprocessError, OSError):
        return ""


def parse(text):
    """Yield (key, package, title, body) for each active notification."""
    pkg = tag = title = body = None
    flags = 0
    found = []

    def flush():
        if pkg and (title or body) and pkg not in SKIP_PACKAGES:
            if not (flags & (FLAG_ONGOING_EVENT | FLAG_FOREGROUND_SERVICE)):
                raw = "|".join((pkg, tag or "", title or "", body or ""))
                key = hashlib.sha1(raw.encode("utf-8", "replace")).hexdigest()
                found.append((key, pkg, title or pkg, body or ""))

    for line in text.splitlines():
        m = RECORD.search(line)
        if m:
            flush()
            pkg, tag = m.group(1), m.group(2)
            title = body = None
            flags = 0
            continue
        if pkg is None:
            continue
        m = FLAGS.search(line)
        if m and flags == 0:
            flags = int(m.group(1), 16)
        m = TITLE.search(line)
        if m:
            title = m.group(1).strip()
            continue
        m = TEXT.search(line)
        if m:
            body = m.group(1).strip()
    flush()
    return found


def app_label(pkg):
    """A human name for the package: WhatsApp, not com.whatsapp."""
    name = pkg.rsplit(".", 1)[-1]
    return name.replace("_", " ").title()


def notify(summary, body, label):
    """Post to the user's session bus, where Sailfish's own notifications go."""
    if len(body) > BODY_MAX:
        body = body[:BODY_MAX - 1] + "…"
    # x-nemo.messaging.im puts it in the events view like a message, and
    # Waydroid's own icon makes the source obvious at a glance.
    args = [
        "gdbus", "call", "--session",
        "--dest", "org.freedesktop.Notifications",
        "--object-path", "/org/freedesktop/Notifications",
        "--method", "org.freedesktop.Notifications.Notify",
        "Waydroid", "0", "waydroid", summary, body, "[]",
        "{'category': <'x-nemo.messaging.im'>,"
        " 'x-nemo-preview-summary': <'%s'>,"
        " 'x-nemo-preview-body': <'%s'>}" % (_esc(summary), _esc(body)),
        "5000",
    ]
    env = dict(os.environ)
    env["XDG_RUNTIME_DIR"] = "/run/user/%d" % UID
    env["DBUS_SESSION_BUS_ADDRESS"] = \
        "unix:path=/run/user/%d/dbus/user_bus_socket" % UID
    try:
        subprocess.run(["su", USER, "-c", " ".join(_q(a) for a in args)],
                       env=env, capture_output=True, text=True, timeout=15)
    except (subprocess.SubprocessError, OSError) as e:
        print("notify failed: %s" % e, flush=True)


def _esc(s):
    return s.replace("\\", "\\\\").replace("'", "\\'")


def _q(s):
    return "'" + s.replace("'", "'\\''") + "'"


def main():
    seen = {}
    first_pass = True
    while True:
        found = parse(dumpsys())
        current = {k for k, _, _, _ in found}

        for key, pkg, title, body in found:
            if key in seen:
                continue
            seen[key] = True
            # Whatever is already on screen when this starts is history, not
            # news: post it and the user gets a burst of old notifications.
            if first_pass:
                continue
            print("forwarding %s: %s" % (pkg, title), flush=True)
            notify(title, body, app_label(pkg))

        for key in [k for k in seen if k not in current]:
            del seen[key]

        first_pass = False
        time.sleep(INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
