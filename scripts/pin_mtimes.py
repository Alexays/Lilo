#!/usr/bin/env python3
"""Dates every tracked file by its content: a checkout then keeps a cached build's file dates, so Xcode rebuilds only what changed.

Usage: git ls-files -s -z | python3 scripts/pin_mtimes.py
"""
import os
import sys

# 2020-01-01 plus up to five years: the same blob always gets the same date, a changed one a different one.
BASE, SPAN = 1577836800, 5 * 365 * 24 * 3600

for entry in sys.stdin.buffer.read().split(b"\0"):
    if not entry:
        continue
    meta, path = entry.split(b"\t", 1)
    mode, blob, _ = meta.split(b" ")
    # Symlinks keep the checkout's date: utime would follow them, and submodules are not files.
    if mode in (b"120000", b"160000"):
        continue
    stamp = BASE + int(blob[:12], 16) % SPAN
    os.utime(path, (stamp, stamp))
