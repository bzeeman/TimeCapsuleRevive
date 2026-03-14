"""Manage SMB shares on the Time Capsule, including USB drives."""

import re

from timecapsule_revive.deploy import _run_ssh, _upload_text, SAMBA_DIR


def list_volumes(host: str) -> list[dict]:
    """List mounted volumes on the Time Capsule.

    Returns a list of dicts with 'device', 'mountpoint', 'size', 'used', 'avail'.
    """
    result = _run_ssh(host, "df")
    volumes = []
    for line in result.stdout.strip().splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 6 and parts[5].startswith("/Volumes/"):
            volumes.append({
                "device": parts[0],
                "mountpoint": parts[5],
                "blocks": parts[1],
                "used": parts[2],
                "avail": parts[3],
                "capacity": parts[4],
            })
    return volumes


def list_shares(host: str) -> list[dict]:
    """List currently configured SMB shares by parsing smb.conf."""
    result = _run_ssh(host, f"cat {SAMBA_DIR}/etc/smb.conf")
    shares = []
    current = None

    for line in result.stdout.splitlines():
        line = line.strip()
        # Section header
        match = re.match(r"^\[(.+)\]$", line)
        if match:
            name = match.group(1)
            if name.lower() != "global":
                current = {"name": name, "path": "", "timemachine": False}
                shares.append(current)
            else:
                current = None
            continue

        if current and "=" in line:
            key, _, val = line.partition("=")
            key = key.strip().lower()
            val = val.strip()
            if key == "path":
                current["path"] = val
            elif key == "fruit:time machine" and val.lower() == "yes":
                current["timemachine"] = True
            elif key == "comment":
                current["comment"] = val

    return shares


def add_share(
    host: str,
    name: str,
    path: str,
    timemachine: bool = False,
    readonly: bool = False,
) -> None:
    """Add a new SMB share to the Time Capsule.

    Appends a share section to smb.conf and reloads Samba.
    """
    # Verify the path exists on the device
    _run_ssh(host, f"ls -d {path}")

    # Build the share config
    share_conf = f"""
[{name}]
    comment = {name}
    path = {path}
    browseable = yes
    writable = {"no" if readonly else "yes"}
    guest ok = yes
    force user = root
    create mask = 0664
    directory mask = 0775"""

    if timemachine:
        share_conf += """
    vfs objects = fruit streams_xattr
    fruit:time machine = yes
    fruit:metadata = stream
    fruit:posix_rename = yes
    fruit:veto_appledouble = no
    fruit:wipe_intentionally_left_blank_rfork = yes
    fruit:delete_empty_adfiles = yes"""

    # Append to smb.conf
    result = _run_ssh(host, f"cat {SAMBA_DIR}/etc/smb.conf")
    new_conf = result.stdout.rstrip() + "\n" + share_conf + "\n"
    _upload_text(host, new_conf, f"{SAMBA_DIR}/etc/smb.conf")

    # Restart Samba to pick up new share
    _restart_samba(host)
    print(f"Share '{name}' added at {path}")


def remove_share(host: str, name: str) -> None:
    """Remove an SMB share from smb.conf."""
    if name.lower() in ("global", "timemachine"):
        raise ValueError(f"Cannot remove the '{name}' section.")

    result = _run_ssh(host, f"cat {SAMBA_DIR}/etc/smb.conf")
    lines = result.stdout.splitlines()

    # Find and remove the share section
    new_lines = []
    skip = False
    for line in lines:
        match = re.match(r"^\[(.+)\]$", line.strip())
        if match:
            if match.group(1) == name:
                skip = True
                continue
            else:
                skip = False
        if not skip:
            new_lines.append(line)

    new_conf = "\n".join(new_lines) + "\n"
    _upload_text(host, new_conf, f"{SAMBA_DIR}/etc/smb.conf")
    _restart_samba(host)
    print(f"Share '{name}' removed.")


def _restart_samba(host: str) -> None:
    """Kill and restart smbd on the Time Capsule."""
    _run_ssh(
        host,
        "for pid in $(/bin/ps ax 2>/dev/null "
        "| sed -n '/\\/smbd/s/^ *\\([0-9]*\\) .*/\\1/p'); "
        "do kill $pid 2>/dev/null; done; sleep 1; "
        f"{SAMBA_DIR}/sbin/smbd -D "
        f"-s {SAMBA_DIR}/etc/smb.conf "
        f"--log-basename={SAMBA_DIR}/var",
    )
