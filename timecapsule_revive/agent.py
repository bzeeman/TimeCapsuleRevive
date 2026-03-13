"""macOS launchd agent for automatic Samba restart on Time Capsule."""

import os
import platform
import stat
import subprocess
import sys
from pathlib import Path

AGENT_LABEL = "com.timecapsulerevive.monitor"
KEYCHAIN_SERVICE = "TimeCapsuleRevive"
CONFIG_DIR = Path("~/.config/timecapsule-revive").expanduser()


def install(host: str, password: str, interval: int = 120) -> None:
    """Install the launchd agent and store credentials in Keychain."""
    if platform.system() != "Darwin":
        raise RuntimeError("Launchd agent is macOS-only. Use 'watch' command on Linux.")

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    # Store password in macOS Keychain
    _keychain_store(host, password)

    # Create the askpass helper
    askpass_path = CONFIG_DIR / "tc-askpass"
    _write_askpass(askpass_path, host)

    # Write host config
    config_path = CONFIG_DIR / "host"
    config_path.write_text(host)

    # Create the launchd plist
    plist_dir = Path("~/Library/LaunchAgents").expanduser()
    plist_dir.mkdir(parents=True, exist_ok=True)
    plist_path = plist_dir / f"{AGENT_LABEL}.plist"

    cli_path = _find_cli()
    log_path = CONFIG_DIR / "monitor.log"

    plist = _generate_plist(cli_path, host, interval, log_path)
    plist_path.write_text(plist)

    # Load the agent
    subprocess.run(["launchctl", "unload", str(plist_path)],
                    capture_output=True)  # ignore if not loaded
    subprocess.run(["launchctl", "load", str(plist_path)], check=True)

    print(f"Agent installed and running.")
    print(f"  Checking {host} every {interval}s")
    print(f"  Plist: {plist_path}")
    print(f"  Log: {log_path}")
    print(f"  Password stored in Keychain as '{KEYCHAIN_SERVICE}'")
    print()
    print("To uninstall: timecapsule-revive uninstall-agent")


def uninstall() -> None:
    """Remove the launchd agent and clean up."""
    if platform.system() != "Darwin":
        raise RuntimeError("Launchd agent is macOS-only.")

    plist_path = Path("~/Library/LaunchAgents").expanduser() / f"{AGENT_LABEL}.plist"

    if plist_path.exists():
        subprocess.run(["launchctl", "unload", str(plist_path)],
                        capture_output=True)
        plist_path.unlink()
        print(f"Agent unloaded and plist removed.")
    else:
        print("Agent plist not found (already uninstalled?).")

    # Remove askpass helper but keep keychain entry (user might want it)
    askpass_path = CONFIG_DIR / "tc-askpass"
    if askpass_path.exists():
        askpass_path.unlink()

    print("To also remove the stored password:")
    print(f"  security delete-generic-password -s '{KEYCHAIN_SERVICE}'")


def _keychain_store(host: str, password: str) -> None:
    """Store the Time Capsule password in macOS Keychain."""
    # Delete existing entry first (ignore errors)
    subprocess.run(
        ["security", "delete-generic-password",
         "-s", KEYCHAIN_SERVICE, "-a", f"root@{host}"],
        capture_output=True,
    )
    subprocess.run(
        ["security", "add-generic-password",
         "-s", KEYCHAIN_SERVICE, "-a", f"root@{host}",
         "-w", password, "-U"],
        check=True,
        capture_output=True,
    )


def _write_askpass(path: Path, host: str) -> None:
    """Write the SSH_ASKPASS helper script."""
    script = f"""#!/bin/sh
# TimeCapsuleRevive SSH_ASKPASS helper — reads password from macOS Keychain
security find-generic-password -s "{KEYCHAIN_SERVICE}" -a "root@{host}" -w 2>/dev/null
"""
    path.write_text(script)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP)


def _find_cli() -> str:
    """Find the timecapsule-revive CLI executable."""
    # Check if we're running from an installed entry point
    cli = subprocess.run(
        ["which", "timecapsule-revive"], capture_output=True, text=True
    )
    if cli.returncode == 0:
        return cli.stdout.strip()

    # Fall back to python -m
    return f"{sys.executable} -m timecapsule_revive"


def _generate_plist(cli_path: str, host: str, interval: int, log_path: Path) -> str:
    """Generate the launchd plist XML."""
    # Split cli_path for python -m case
    if " -m " in cli_path:
        parts = cli_path.split()
        program_args = "\n".join(f"        <string>{p}</string>" for p in parts)
    else:
        program_args = f"        <string>{cli_path}</string>"

    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{AGENT_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
{program_args}
        <string>monitor</string>
        <string>--host</string>
        <string>{host}</string>
        <string>--once</string>
    </array>

    <key>StartInterval</key>
    <integer>{interval}</integer>

    <key>StandardOutPath</key>
    <string>{log_path}</string>

    <key>StandardErrorPath</key>
    <string>{log_path}</string>

    <key>RunAtLoad</key>
    <true/>

    <key>EnvironmentVariables</key>
    <dict>
        <key>SSH_ASKPASS</key>
        <string>{CONFIG_DIR / 'tc-askpass'}</string>
        <key>SSH_ASKPASS_REQUIRE</key>
        <string>force</string>
    </dict>
</dict>
</plist>
"""
