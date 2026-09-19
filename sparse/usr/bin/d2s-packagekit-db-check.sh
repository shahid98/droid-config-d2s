#!/bin/sh
# Drop PackageKit's transaction database if it is not a database.
#
# packagekitd opens /var/lib/PackageKit/transactions.db at startup and, if the
# file is unreadable as SQLite, gives up before claiming its bus name:
#
#     PackageKit: trying to open database '/var/lib/PackageKit/transactions.db'
#     Failed to load the backend: Failed to execute statement
#         'PRAGMA synchronous=OFF': file is not a database
#     PackageKit: daemon quit
#
# Every D-Bus activation then ends in
# "Failed to activate service 'org.freedesktop.PackageKit': timed out
# (service_start_timeout=25000ms)", which is what the Settings app installer
# and Storeman both report as a plain "installation failed". Nothing in the UI
# says the database is the problem.
#
# Seen on this device as 32768 bytes of NUL: the inode size was committed but
# the data blocks never were. /data is f2fs and a reset that skips the
# checkpoint - vol-down+power, which this port still needs sometimes - leaves
# files exactly like that. It is the same failure that hollowed out the bcmdhd
# firmware (see droid-wifi-firmware.sh), so it is worth expecting anywhere a
# file is written and then the phone is reset.
#
# The database is a cache of past transactions, so deleting it costs nothing:
# packagekitd recreates it on the next start. Only touch it when the SQLite
# magic is absent, so a healthy database is never thrown away.
DB=/var/lib/PackageKit/transactions.db
[ -f "$DB" ] || exit 0

# "SQLite format 3\000" - compare the first 15 bytes, which are printable.
MAGIC=$(dd if="$DB" bs=1 count=15 2>/dev/null)
[ "$MAGIC" = "SQLite format 3" ] && exit 0

rm -f "$DB"
echo "removed a corrupt $DB (magic was '$MAGIC')"
exit 0
