#!/usr/bin/env python3
"""Read-only Garmin USB count for the Omarchy bar widget.

This file is standalone: the marketplace clone does not include the companion
package. It asks lsblk for block-device metadata and counts filesystems on
parent disks whose vendor is Garmin and whose transport is USB. Linux sysfs
USB ancestry groups multiple storage disks from one physical device. It never
opens mountpoints or GarminDevice.xml. Paths, labels, models, and serials stay
out of the printed object.

Behavior matches ``garmin_companion.shell_status`` for this status object.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

LSBLK_TIMEOUT_SECONDS = 5
LSBLK_COLUMNS = "NAME,VENDOR,TRAN,FSTYPE,TYPE"
_MAX_NODES = 256
_MAX_VOLUMES = 32
_VOLUME_TYPES = {"disk", "part"}

_TIMEOUT = "lsblk timed out"
_START = "lsblk could not be started"
_FAILED = "lsblk failed"
_MALFORMED = "lsblk returned malformed JSON"
_UNEXPECTED = "lsblk returned unexpected data"
_DISCONNECTED = "No Garmin USB storage"


def _payload(state: str, volume_count: int, tooltip: str, device_count: int = 0) -> dict[str, Any]:
    text = f"Garmin {device_count}" if state == "connected" else "Garmin"
    return {
        "state": state,
        "device_count": device_count,
        "volume_count": int(volume_count),
        "text": text,
        "tooltip": tooltip,
    }


def _error(tooltip: str) -> dict[str, Any]:
    return _payload("error", 0, tooltip)


def _is_garmin_usb(node: dict[str, Any]) -> bool:
    vendor = str(node.get("vendor") or "").strip().casefold()
    transport = str(node.get("tran") or "").strip()
    return vendor == "garmin" and transport == "usb"


def _is_volume(node: dict[str, Any]) -> bool:
    filesystem = node.get("fstype")
    return node.get("type") in _VOLUME_TYPES and isinstance(filesystem, str) and bool(filesystem.strip())


def count_garmin_volumes(devices: list[Any]) -> int | None:
    """Count Garmin USB filesystems, or return None when the tree is not usable."""
    count = 0
    seen = 0
    for disk in devices:
        if not isinstance(disk, dict) or not _is_garmin_usb(disk):
            continue
        stack = [disk]
        while stack:
            node = stack.pop()
            seen += 1
            if seen > _MAX_NODES:
                return None
            if _is_volume(node):
                count += 1
                if count > _MAX_VOLUMES:
                    return None
            children = node.get("children")
            if children is None:
                continue
            if not isinstance(children, list):
                return None
            for child in children:
                if isinstance(child, dict):
                    stack.append(child)
                elif child is not None:
                    return None
    return count


def _usb_device_key(name: str, sysfs_root: Path = Path("/sys/class/block")) -> str:
    """Group block disks by their physical Garmin USB ancestor.

    Read only Linux sysfs USB metadata, never a serial, mountpoint, or Garmin
    file. The internal topology key is discarded rather than printed.
    """
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name):
        raise ValueError("Invalid block name")
    node = (sysfs_root / name).resolve(strict=True)
    for parent in (node, *node.parents):
        try:
            vendor = (parent / "idVendor").read_text(encoding="ascii").strip().lower()
        except FileNotFoundError:
            continue
        if vendor == "091e":
            return str(parent)
    raise ValueError("Garmin USB topology unavailable")


def status_from_lsblk(stdout: str) -> dict[str, Any]:
    """Turn one lsblk JSON document into the widget status object."""
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError:
        return _error(_MALFORMED)
    if not isinstance(payload, dict):
        return _error(_UNEXPECTED)
    devices = payload.get("blockdevices")
    if not isinstance(devices, list):
        return _error(_UNEXPECTED)
    count = count_garmin_volumes(devices)
    if count is None:
        return _error(_UNEXPECTED)
    if count == 0:
        return _payload("disconnected", 0, _DISCONNECTED)
    keys = {
        _usb_device_key(disk.get("name"))
        for disk in devices
        if isinstance(disk, dict) and _is_garmin_usb(disk) and count_garmin_volumes([disk])
    }
    device_count = len(keys)
    if not device_count:
        return _error(_UNEXPECTED)
    noun = "device" if device_count == 1 else "devices"
    volume_noun = "volume" if count == 1 else "volumes"
    return _payload(
        "connected",
        count,
        f"{device_count} Garmin USB {noun} · {count} storage {volume_noun}",
        device_count,
    )


def _run_lsblk() -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["lsblk", "--json", "--bytes", "--output", LSBLK_COLUMNS],
        check=False,
        capture_output=True,
        text=True,
        timeout=LSBLK_TIMEOUT_SECONDS,
    )


def read_status() -> dict[str, Any]:
    """Query lsblk once and return the widget status object."""
    try:
        completed = _run_lsblk()
    except subprocess.TimeoutExpired:
        return _error(_TIMEOUT)
    except OSError:
        return _error(_START)
    except UnicodeError:
        return _error(_UNEXPECTED)
    if completed.returncode != 0:
        return _error(_FAILED)
    try:
        return status_from_lsblk(completed.stdout)
    except (OSError, TypeError, ValueError, RecursionError):
        return _error(_UNEXPECTED)


def _emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, separators=(",", ":"), sort_keys=True), flush=True)


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args:
        _emit(_error("Unsupported arguments"))
        return 2
    _emit(read_status())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
