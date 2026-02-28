"""Binary delivery, config generation, and deployment to Time Capsule."""

import hashlib
import json
import os
import subprocess
import tempfile
import urllib.request
from pathlib import Path

# Paths on the Time Capsule
FLASH_DIR = "/mnt/Flash"
SAMBA_DIR = "/Volumes/dk2/samba"
SHARE_ROOT = "/Volumes/dk2/ShareRoot"
LIB_DIR = "/Volumes/dk2/lib"

GITHUB_REPO = "bzeeman/TimeCapsuleRevive"
RELEASE_API = f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"

TEMPLATES_DIR = Path(__file__).parent / "templates"


def _load_template(name: str) -> str:
    return (TEMPLATES_DIR / name).read_text()


def generate_smb_conf(
    server_string: str = "Time Capsule SMB",
    share_path: str = SHARE_ROOT,
    max_size: str = "1.5T",
) -> str:
    """Generate smb.conf from template."""
    template = _load_template("smb.conf.template")
    return template.format(
        server_string=server_string,
        share_path=share_path,
        max_size=max_size,
    )


def generate_rc_script(
    smbd_path: str = f"{SAMBA_DIR}/sbin/smbd",
    conf_path: str = f"{SAMBA_DIR}/etc/smb.conf",
    lib_path: str = LIB_DIR,
) -> str:
    """Generate the rc.d startup script from template."""
    template = _load_template("rc_samba.template")
    return template.format(
        smbd_path=smbd_path,
        conf_path=conf_path,
        lib_path=lib_path,
    )


def generate_pf_rules() -> str:
    """Generate PF redirect rules from template."""
    return _load_template("pf_rules.template")


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
            # Single hash, no filename
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


def _ssh_command(host: str) -> list[str]:
    """Base SSH command with Time Capsule-compatible options."""
    return [
        "ssh",
        "-oHostKeyAlgorithms=+ssh-dss",
        "-oPubkeyAuthentication=no",
        "-oStrictHostKeyChecking=accept-new",
        f"root@{host}",
    ]


def _scp_command(host: str, src: str, dest: str) -> list[str]:
    """SCP command for uploading to the Time Capsule."""
    return [
        "scp",
        "-oHostKeyAlgorithms=+ssh-dss",
        "-oPubkeyAuthentication=no",
        "-oStrictHostKeyChecking=accept-new",
        src,
        f"root@{host}:{dest}",
    ]


def _run_ssh(host: str, command: str) -> None:
    """Run a command on the Time Capsule via SSH."""
    subprocess.run(
        [*_ssh_command(host), command],
        check=True,
    )


def deploy(host: str) -> None:
    """Full deployment: download binary, generate configs, upload, install.

    This is the main entry point for the deploy phase.
    """
    with tempfile.TemporaryDirectory(prefix="tcrevive-") as staging:
        # Download smbd binary
        smbd_path = download_release_binary(staging)

        # Generate configs
        smb_conf = generate_smb_conf()
        rc_script = generate_rc_script()
        pf_rules = generate_pf_rules()

        # Write configs to staging
        smb_conf_path = Path(staging) / "smb.conf"
        smb_conf_path.write_text(smb_conf)

        rc_script_path = Path(staging) / "rc.samba"
        rc_script_path.write_text(rc_script)

        pf_rules_path = Path(staging) / "pf.conf"
        pf_rules_path.write_text(pf_rules)

        # Create directories on device
        print("Preparing device directories...")
        _run_ssh(host, f"mkdir -p {SAMBA_DIR}/sbin {SAMBA_DIR}/etc /tmp/samba")

        # Upload files
        print("Uploading Samba binary...")
        subprocess.run(
            _scp_command(host, str(smbd_path), f"{SAMBA_DIR}/sbin/smbd"),
            check=True,
        )

        print("Uploading configuration...")
        subprocess.run(
            _scp_command(host, str(smb_conf_path), f"{SAMBA_DIR}/etc/smb.conf"),
            check=True,
        )

        print("Uploading PF rules...")
        subprocess.run(
            _scp_command(host, str(pf_rules_path), f"{FLASH_DIR}/pf.conf"),
            check=True,
        )

        print("Uploading startup script...")
        subprocess.run(
            _scp_command(host, str(rc_script_path), f"{FLASH_DIR}/rc.samba"),
            check=True,
        )

        # Install: set permissions, load PF, hook into boot, start Samba
        print("Installing PF redirect rules...")
        _run_ssh(host, f"chmod +x {FLASH_DIR}/rc.samba")
        _run_ssh(host, f"pfctl -ef {FLASH_DIR}/pf.conf")

        print("Installing boot persistence...")
        _install_boot_hook(host)

        print("Starting Samba...")
        _run_ssh(
            host,
            f"export LD_LIBRARY_PATH={LIB_DIR} && "
            f"{SAMBA_DIR}/sbin/smbd -D -s {SAMBA_DIR}/etc/smb.conf",
        )

        print("Deployment complete.")


def _install_boot_hook(host: str) -> None:
    """Install rc.samba into the boot sequence.

    Appends a call to /mnt/Flash/rc.samba in /etc/rc.local if not already
    present. On NetBSD, /etc/rc.local runs after standard rc.d scripts.
    """
    check = subprocess.run(
        [*_ssh_command(host), "grep -q rc.samba /etc/rc.local 2>/dev/null"],
        capture_output=True,
    )
    if check.returncode != 0:
        _run_ssh(host, "echo '/mnt/Flash/rc.samba' >> /etc/rc.local")
