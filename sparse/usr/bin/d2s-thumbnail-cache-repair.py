#!/usr/bin/python3
"""Discard thumbnail cache entries left empty or zero-filled by a hard stop."""

import os
from pathlib import Path


def main():
    cache = Path.home() / ".cache" / "org.nemomobile" / "thumbnails"
    if not cache.is_dir():
        return

    removed = 0
    for path in cache.rglob("*"):
        if not path.is_file():
            continue
        try:
            size = path.stat().st_size
            with path.open("rb") as stream:
                header = stream.read(32)
            if size == 0 or (header and not any(header)):
                path.unlink()
                removed += 1
        except OSError:
            # A concurrently regenerated entry is harmless; Lipstick will
            # retry it through the normal thumbnail provider.
            continue

    if removed:
        print("d2s-thumbnail-cache-repair: removed %d corrupt entries" % removed)


if __name__ == "__main__":
    main()
