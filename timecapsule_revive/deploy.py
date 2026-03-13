"""Binary delivery, config generation, and deployment to Time Capsule."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

# Paths on the Time Capsule
SAMBA_DIR = "/Volumes/dk2/samba"
SHARE_ROOT = "/Volumes/dk2/ShareRoot"

GITHUB_REPO = "bzeeman/TimeCapsuleRevive"
RELEASE_API = f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"

TEMPLATES_DIR = Path(__file__).parent / "templates"


def _load_template(name: str) -> str:
    return (TEMPLATES_DIR / name).read_text()


def generate_smb_conf(
    netbios_name: str = "THE-TARDIS",
    share_path: str = SHARE_ROOT,
    max_size: str = "1.5T",
) -> str:
    """Generate smb.conf from template."""
    template = _load_template("smb.conf.template")
    return template.format(
        netbios_name=netbios_name,
        share_path=share_path,
        max_size=max_size,
    )


def generate_rc_script() -> str:
    """Generate the startup script from template."""
    return _load_template("rc_samba.template")


def download_release_binary(dest_dir: str) -> Path:
    """Download the latest smbd binary from GitHub Releases.

    Verifies SHA256 checksum before returning the path.
    Returns the path to the downloaded binary.
    """
    print(f"Fetching latest release from {GITHUB_REPO}...")
    req = urllib.request.Request(RELEASE_API, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req) as resp:
        release = json.loads(resp.read())

    # Find the smbd binary and checksum assets
    smbd_asset = None
    checksum_asset = None
    for asset in release.get("assets", []):
        name = asset["name"]
        if name == "smbd":
            smbd_asset = asset
        elif name == "SHA256SUMS" or name.endswith(".sha256"):
            checksum_asset = asset

    if not smbd_asset:
        raise RuntimeError(
            f"No 'smbd' binary found in release {release.get('tag_name', '?')}. "
            f"Available assets: {[a['name'] for a in release.get('assets', [])]}"
        )

    tag = release.get("tag_name", "unknown")
    print(f"Downloading smbd from release {tag}...")

    smbd_path = Path(dest_dir) / "smbd"
    _download_asset(smbd_asset["browser_download_url"], smbd_path)

    if checksum_asset:
        print("Verifying SHA256 checksum...")
        _verify_checksum(smbd_path, checksum_asset["browser_download_url"])
    else:
        print("WARNING: No checksum file found in release. Skipping verification.")

    smbd_path.chmod(0o755)
    return smbd_path


def _download_asset(url: str, dest: Path) -> None:
    """Download a URL to a local file."""
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req) as resp:
        dest.write_bytes(resp.read())


def _verify_checksum(file_path: Path, checksum_url: str) -> None:
    """Verify SHA256 of a file against a remote checksum file."""
    req = urllib.request.Request(checksum_url)
    with urllib.request.urlopen(req) as resp:
        checksum_text = resp.read().decode("utf-8")

    # Parse "hash  filename" format
    expected = None
    for line in checksum_text.strip().splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].strip("*") == file_path.name:
            expected = parts[0].lower()
            break
        elif len(parts) == 1:
            expected = parts[0].lower()
            break

    if not expected:
        raise RuntimeError(f"Could not find checksum for {file_path.name}")

    actual = hashlib.sha256(file_path.read_bytes()).hexdigest()
    if actual != expected:
        file_path.unlink()
        raise RuntimeError(
            f"SHA256 mismatch for {file_path.name}:\n"
            f"  expected: {expected}\n"
            f"  actual:   {actual}\n"
            f"Binary has been deleted. The download may be corrupted."
        )
    print(f"Checksum verified: {actual[:16]}...")


def _ssh_base(host: str) -> list[str]:
    """Base SSH command with Time Capsule-compatible options.

    The Time Capsule runs OpenSSH 4.4 which only supports ssh-rsa and ssh-dss
    host keys, and diffie-hellman-group14-sha1 key exchange. Modern OpenSSH
    has removed ssh-dss entirely, so we use ssh-rsa.
    """
    return [
        "ssh",
        "-oHostKeyAlgorithms=+ssh-rsa",
        "-oKexAlgorithms=+diffie-hellman-group14-sha1",
        "-oPubkeyAuthentication=no",
        "-oStrictHostKeyChecking=accept-new",
        f"root@{host}",
    ]


def _run_ssh(host: str, command: str) -> subprocess.CompletedProcess:
    """Run a command on the Time Capsule via SSH."""
    return subprocess.run(
        [*_ssh_base(host), command],
        check=True,
        capture_output=True,
        text=True,
    )


def _upload_file(host: str, local_path: Path, remote_path: str) -> None:
    """Upload a file to the Time Capsule via dd over SSH pipe.

    The device's OpenSSH 4.4 doesn't support modern scp/sftp. We pipe the
    file content through SSH to dd on the device.
    """
    with open(local_path, "rb") as f:
        proc = subprocess.run(
            [*_ssh_base(host), f"dd of={remote_path} bs=65536"],
            stdin=f,
            capture_output=True,
        )
    if proc.returncode != 0:
        raise RuntimeError(
            f"Failed to upload {local_path.name}: {proc.stderr.decode()}"
        )


def _upload_text(host: str, content: str, remote_path: str) -> None:
    """Upload text content to a file on the Time Capsule."""
    proc = subprocess.run(
        [*_ssh_base(host), f"dd of={remote_path} bs=4096"],
        input=content.encode(),
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"Failed to write {remote_path}: {proc.stderr.decode()}")


def deploy(host: str, netbios_name: str = "THE-TARDIS") -> None:
    """Full deployment: download binary, generate configs, upload, install.

    This is the main entry point for the deploy phase.
    """
    with tempfile.TemporaryDirectory(prefix="tcrevive-") as staging:
        # Download smbd binary
        smbd_path = download_release_binary(staging)

        # Generate configs
        smb_conf = generate_smb_conf(netbios_name=netbios_name)
        rc_script = generate_rc_script()

        # Mount disk if needed and create directories
        print("Preparing device directories...")
        _run_ssh(
            host,
            "if [ ! -d /Volumes/dk2/ShareRoot ]; then "
            "mkdir -p /Volumes/dk2 && "
            "/sbin/mount_hfs /dev/dk2 /Volumes/dk2; "
            "fi"
        )
        _run_ssh(
            host,
            f"mkdir -p {SAMBA_DIR}/sbin {SAMBA_DIR}/etc "
            f"{SAMBA_DIR}/var/run {SAMBA_DIR}/var/lock "
            f"{SAMBA_DIR}/var/cores/smbd {SAMBA_DIR}/private"
        )

        # Kill old Apple CIFS services to free port 445/139
        print("Stopping old SMBv1 service...")
        _run_ssh(
            host,
            "for pid in $(/bin/ps ax 2>/dev/null "
            "| grep '[w]cifsfs\\|[w]cifsnd' "
            "| awk '{print $1}'); do kill $pid 2>/dev/null; done; "
            "sleep 2"
        )

        # Upload binary via dd pipe (no scp on device)
        print("Uploading Samba binary (~14MB)...")
        _upload_file(host, smbd_path, f"{SAMBA_DIR}/sbin/smbd")
        _run_ssh(host, f"chmod 755 {SAMBA_DIR}/sbin/smbd")

        # Verify binary runs
        result = _run_ssh(host, f"{SAMBA_DIR}/sbin/smbd --version")
        print(f"  {result.stdout.strip()}")

        # Upload configuration
        print("Uploading configuration...")
        _upload_text(host, smb_conf, f"{SAMBA_DIR}/etc/smb.conf")

        # Upload startup script
        print("Uploading startup script...")
        _upload_text(host, rc_script, f"{SAMBA_DIR}/rc_samba.sh")
        _run_ssh(host, f"chmod 755 {SAMBA_DIR}/rc_samba.sh")

        # Add hostname entry for fast DNS resolution
        _run_ssh(
            host,
            f"echo '{host} {netbios_name.lower()}' >> /etc/hosts"
        )

        # Start Samba
        print("Starting Samba...")
        _run_ssh(
            host,
            f"{SAMBA_DIR}/sbin/smbd -D "
            f"-s {SAMBA_DIR}/etc/smb.conf "
            f"--log-basename={SAMBA_DIR}/var",
        )

        print("Deployment complete.")
        print(f"  SMBv3 share available at: smb://{host}/TimeMachine")
        print(f"  After reboot, SSH in and run: {SAMBA_DIR}/rc_samba.sh")
