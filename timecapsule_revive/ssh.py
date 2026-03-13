"""SSH enablement for Apple Time Capsule via ACP protocol."""

import socket
import time

from timecapsule_revive.acp_client import ACPClient, ACPError

SSH_PORT = 22
REBOOT_WAIT = 90  # seconds to wait for reboot


def enable_ssh(host: str, password: str) -> None:
    """Enable SSH on a Time Capsule and reboot.

    Connects to ACP on port 5009, sets dbug=0x3000 to enable SSH,
    then reboots the device.
    """
    print(f"Connecting to {host} via ACP (port 5009)...")
    with ACPClient(host, password) as acp:
        print("Enabling SSH (setting dbug=0x3000)...")
        acp.enable_ssh()
        print("Rebooting device...")
        acp.reboot()

    print(f"Waiting for device to reboot (~{REBOOT_WAIT}s)...")
    _wait_for_ssh(host, timeout=REBOOT_WAIT)
    print(f"SSH is now available on {host}:22")


def disable_ssh(host: str, password: str) -> None:
    """Disable SSH by removing the dbug property via SSH, then rebooting.

    Runs the on-device `acp` binary to remove the property, since some
    firmware versions ignore setting dbug=0 via the network protocol.
    """
    import subprocess

    ssh_base = _ssh_command(host)
    print("Removing dbug property on device...")
    subprocess.run(
        [*ssh_base, "acp", "remove", "dbug"],
        check=True,
    )

    print("Rebooting to apply...")
    with ACPClient(host, password) as acp:
        acp.reboot()

    print("SSH has been disabled. Device is rebooting.")


def _wait_for_ssh(host: str, timeout: float = REBOOT_WAIT, poll: float = 5.0) -> None:
    """Poll SSH port until the device is reachable or timeout expires."""
    deadline = time.monotonic() + timeout
    # Initial delay — device needs time to shut down before we start polling
    time.sleep(15)

    while time.monotonic() < deadline:
        if _is_port_open(host, SSH_PORT):
            return
        time.sleep(poll)

    raise TimeoutError(
        f"Device {host} did not become reachable on port {SSH_PORT} "
        f"within {timeout}s after reboot"
    )


def _is_port_open(host: str, port: int, timeout: float = 3.0) -> bool:
    """Check if a TCP port is open."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except (OSError, ConnectionRefusedError):
        return False


def _ssh_command(host: str) -> list[str]:
    """Build the base SSH command with Time Capsule-compatible options."""
    return [
        "ssh",
        "-oHostKeyAlgorithms=+ssh-rsa",
        "-oKexAlgorithms=+diffie-hellman-group14-sha1",
        "-oPubkeyAuthentication=no",
        "-oStrictHostKeyChecking=accept-new",
        f"root@{host}",
    ]


def run_ssh(host: str, *args: str) -> "subprocess.CompletedProcess":
    """Run a command on the Time Capsule via SSH."""
    import subprocess

    cmd = [*_ssh_command(host), *args]
    return subprocess.run(cmd, check=True, capture_output=True, text=True)
