#!/usr/bin/env python3
"""Manage the EML anatomy viewer as a per-user macOS login service."""

import argparse
import json
import os
import plistlib
import re
import signal
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

LABEL = "com.agrim.eml-anatomy-viewer"
DOMAIN = f"gui/{os.getuid()}"
SERVICE = f"{DOMAIN}/{LABEL}"
PLIST = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
LOGS = Path.home() / "Library" / "Logs" / LABEL
DEFAULT_ROOT = Path(__file__).resolve().parents[4] / "eml"
PORT = 8765
URL = f"http://127.0.0.1:{PORT}"


def cmd(*args, check=True):
    return subprocess.run(args, text=True, check=check, capture_output=True)


def info():
    return cmd("/bin/launchctl", "print", SERVICE, check=False)


def listener():
    result = cmd("/usr/sbin/lsof", "-nP", f"-iTCP:{PORT}", "-sTCP:LISTEN", "-t", check=False)
    return set(int(s) for s in result.stdout.split())


def status():
    description = info()
    match = re.search(r"^\s*pid = (\d+)\s*$", description.stdout, flags=re.MULTILINE)
    pid = int(match.group(1)) if match else None
    if description.returncode or not pid or listener() != {pid}:
        raise RuntimeError(f"Viewer is not serving from {SERVICE}. See {LOGS}.")
    with urllib.request.urlopen(f"{URL}/api/catalog", timeout=4) as response:
        catalog = json.load(response)
    print(f"{LABEL} (pid {pid}): {URL}/ — "
          f"{sum(k.startswith('exercises/') for k in catalog)} catalog exercises, "
          f"{sum(k.startswith('examples/') for k in catalog)} examples")


def adopt(root, pid):
    # Only terminate an exact copy of this user's manually started EML viewer.
    cwd = cmd("/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn").stdout.splitlines()
    args = cmd("/bin/ps", "-p", str(pid), "-o", "command=").stdout.strip().split()
    owner = cmd("/bin/ps", "-p", str(pid), "-o", "uid=").stdout.strip()
    if (f"n{root}" not in cwd or owner != str(os.getuid()) or
        args not in [[prefix + "python", "-m", "viewer", "--port", str(PORT)]
                     for prefix in [".venv/bin/", str(root / ".venv/bin") + "/"]]):
        raise RuntimeError(f"Port {PORT} is held by an unrecognized process ({pid}).")
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        if pid not in listener():
            return
        time.sleep(0.1)
    raise RuntimeError("Timed out waiting for the manual viewer to release its port.")


def install(root, take_over):
    python = root / ".venv/bin/python"
    check = subprocess.run([python, "-B", "-c", "from viewer.__main__ import entries; assert entries()"],
                           cwd=root, capture_output=True, text=True)
    if check.returncode:
        raise RuntimeError(f"Initialize the EML checkout's .venv first. {check.stderr.strip()}")
    if info().returncode == 0:
        cmd("/bin/launchctl", "bootout", SERVICE)
        for _ in range(50):
            if not listener():
                break
            time.sleep(0.1)
    pids = listener()
    if pids:
        if not take_over or len(pids) != 1:
            raise RuntimeError(f"Port {PORT} is already in use. Use --adopt only for this checkout's manual viewer.")
        adopt(root, pids.pop())
    LOGS.mkdir(parents=True, exist_ok=True)
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    settings = {
        "Label": LABEL, "ProgramArguments": [str(python), "-B", "-u", "-m", "viewer", "--port", str(PORT)],
        "WorkingDirectory": str(root), "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 5,
        "StandardOutPath": str(LOGS / "stdout.log"), "StandardErrorPath": str(LOGS / "stderr.log"),
    }
    with tempfile.NamedTemporaryFile(dir=PLIST.parent, delete=False) as temp:
        plistlib.dump(settings, temp)
    os.replace(temp.name, PLIST)
    cmd("/bin/launchctl", "enable", SERVICE)
    cmd("/bin/launchctl", "bootstrap", DOMAIN, str(PLIST))
    for _ in range(50):
        try:
            status()
            return
        except (RuntimeError, OSError):
            time.sleep(0.2)
    raise RuntimeError(f"Viewer did not start. See {LOGS}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    setup = actions.add_parser("install")
    setup.add_argument("--eml", type=Path, default=DEFAULT_ROOT)
    setup.add_argument("--adopt", action="store_true", help="Replace a manual viewer started from this checkout")
    actions.add_parser("status")
    actions.add_parser("uninstall")
    args = parser.parse_args()
    if args.action == "install":
        install(args.eml.resolve(), args.adopt)
    elif args.action == "status":
        status()
    else:
        if info().returncode == 0:
            cmd("/bin/launchctl", "bootout", SERVICE)
        if PLIST.exists():
            PLIST.unlink()
        print(f"Removed {LABEL}. Logs remain at {LOGS}.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as exc:
        detail = (exc.stderr or "").strip() if isinstance(exc, subprocess.CalledProcessError) else ""
        raise SystemExit(detail or str(exc))
