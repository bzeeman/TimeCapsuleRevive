"""Monitor Time Capsule and auto-start Samba after reboot."""

import os
import subprocess
import time

from timecapsule_revive.deploy import _ssh_base
from timecapsule_revive.verify import verify_smb


def check_and_start(host: str) -> bool:
    """Check if SMBv3 is running; start it if not.

    Returns True if SMBv3 is (now) running.
    Uses SSH_ASKPASS for password authentication when available.
    """
    if verify_smb(host, timeout=5.0):
        return True

    print(f"SMBv3 not responding on {host}. Starting Samba...")

    try:
        result = subprocess.run(
            [*_ssh_base(host), "/Volumes/dk2/samba/rc_samba.sh"],
            capture_output=True,
            text=True,
            timeout=60,
            env=_ssh_env(),
        )

        if result.returncode != 0:
            print(f"  Failed: {result.stderr.strip()}")
            return False

        # Wait for smbd to bind ports
        time.sleep(3)
        success = verify_smb(host, timeout=10.0)
        if success:
            print("  Samba started successfully.")
        return success
    except subprocess.TimeoutExpired:
        print("  SSH timed out — device may not be reachable.")
        return False
    except Exception as e:
        print(f"  Error: {e}")
        return False


def watch(host: str, interval: int = 60) -> None:
    """Continuously monitor and restart Samba as needed."""
    print(f"Watching {host} (checking every {interval}s)...")
    print("Press Ctrl+C to stop.\n")

    while True:
        running = check_and_start(host)
        status = "OK" if running else "DOWN"
        print(f"  [{time.strftime('%H:%M:%S')}] SMBv3: {status}")
        time.sleep(interval)


def _ssh_env() -> dict[str, str]:
    """Build environment dict with SSH_ASKPASS support."""
    env = dict(os.environ)
    askpass = _find_askpass()
    if askpass:
        env["SSH_ASKPASS"] = askpass
        env["SSH_ASKPASS_REQUIRE"] = "force"
        # Remove DISPLAY to avoid X11 askpass dialogs
        env.pop("DISPLAY", None)
    return env


def _find_askpass() -> str | None:
    """Find the TimeCapsuleRevive askpass helper."""
    candidates = [
        os.path.expanduser("~/.config/timecapsule-revive/tc-askpass"),
        "/usr/local/bin/tc-askpass",
    ]
    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None
