# TimeCapsuleRevive

Rescue Apple Time Capsules from e-waste by deploying modern Samba (SMBv3) with full Time Machine support — compatible through macOS 27 and beyond.

Apple discontinued Time Capsule in 2018 and modern macOS versions have progressively dropped SMBv1 and AFP support, turning millions of perfectly functional backup devices into doorstops. This tool gives them a second life.

## What This Tool Does

TimeCapsuleRevive automates the following steps on your Time Capsule:

1. **Discovers** your Time Capsule on the local network via mDNS
2. **Enables SSH** temporarily using the AirPort Configuration Protocol (ACP)
3. **Downloads** a pre-compiled Samba binary (cross-compiled for NetBSD/ARM) from GitHub Releases
4. **Verifies** the binary's SHA256 checksum before deployment
5. **Uploads** Samba + configuration files to the device via SSH (`dd` pipe — the device's OpenSSH 4.4 doesn't support modern scp)
6. **Kills** the old Apple SMBv1 service (`wcifsfs`/`wcifsnd`) to free port 445
7. **Starts** Samba with SMBv3 and Time Machine support (via `vfs_fruit`) on standard ports (445/139)
8. **Verifies** SMBv3 is responding before declaring success

### What it does NOT do

- Does **not** disable AFP (Apple Filing Protocol) — still needed for internal disk auto-mount
- Does **not** modify the Time Capsule firmware or flash storage
- Does **not** store your password by default — collected via `getpass`, used only for the current session (the optional launchd agent and menubar app store it in macOS Keychain)

### Files deployed to the device

| File | Location | Purpose |
|------|----------|---------|
| `smbd` | `/Volumes/dk2/samba/sbin/smbd` | Samba server binary (14MB, static ARM) |
| `smb.conf` | `/Volumes/dk2/samba/etc/smb.conf` | Samba configuration |
| `rc_samba.sh` | `/Volumes/dk2/samba/rc_samba.sh` | Startup script (run after reboot) |

## Prerequisites

- Python 3.9+
- `pip` or `pipx`
- An SSH client (`ssh`) — included on macOS and most Linux distros
- An Apple Time Capsule on the same local network
- The AirPort admin password for your Time Capsule

## Installation

```bash
pip install .
```

Or with pipx for isolated installation:

```bash
pipx install .
```

## Usage

### Full automated setup

```bash
timecapsule-revive setup
```

This runs the complete flow: discover → enable SSH → deploy Samba → verify.

### Options

```bash
# Skip discovery, connect to a specific host
timecapsule-revive setup --host 10.0.1.1

# Disable SSH after deployment (recommended for security)
timecapsule-revive setup --disable-ssh-after
```

### Individual commands

```bash
# Just scan for Time Capsule devices
timecapsule-revive discover

# Just verify if SMBv3 is working on a device
timecapsule-revive verify --host 10.0.1.1
```

## After Setup

Your Time Capsule is now serving SMBv3 on the standard port (445). On macOS:

1. Open **Finder** → **Go** → **Connect to Server** (⌘K)
2. Enter `smb://your-time-capsule-ip/TimeMachine`
3. Connect as **Guest** (no password needed)
4. To add as a Time Machine destination: **System Settings** → **General** → **Time Machine** → **+**

### After a Reboot

The Time Capsule's root filesystem is a ramdisk, so Samba doesn't auto-start after a reboot. You have three options:

**Option 1: Automatic monitoring (recommended)**

Install the macOS launchd agent to detect reboots and restart Samba automatically:

```bash
timecapsule-revive install-agent --host YOUR_TC_IP
```

This stores your password in the macOS Keychain and checks the Time Capsule every 2 minutes. To remove: `timecapsule-revive uninstall-agent`.

**Option 2: Manual SSH restart**

```bash
ssh -oHostKeyAlgorithms=+ssh-rsa -oKexAlgorithms=+diffie-hellman-group14-sha1 \
    -oPubkeyAuthentication=no root@YOUR_TC_IP \
    "/Volumes/dk2/samba/rc_samba.sh"
```

**Option 3: Continuous watch mode**

```bash
timecapsule-revive monitor --host YOUR_TC_IP
```

This runs in the foreground and restarts Samba whenever it detects the service is down.

### Managing Shares

By default, the internal disk is shared as `TimeMachine`. You can add additional shares (e.g., for a USB drive plugged into the Time Capsule):

```bash
# List mounted volumes on the device
timecapsule-revive shares volumes --host YOUR_TC_IP

# Add a USB drive as a share
timecapsule-revive shares add --host YOUR_TC_IP --name USB --path /Volumes/dk3

# Add with Time Machine support
timecapsule-revive shares add --host YOUR_TC_IP --name USB-TM --path /Volumes/dk3 --time-machine

# List current shares
timecapsule-revive shares list --host YOUR_TC_IP

# Remove a share
timecapsule-revive shares remove --host YOUR_TC_IP --name USB
```

### macOS Menubar App

For a native GUI experience, the `TimeCapsuleApp/` directory contains a SwiftUI menubar app. Open in Xcode and build:

```bash
cd TimeCapsuleApp && xed .
```

The app shows Time Capsule status in your menu bar, auto-starts Samba after reboots, lets you manage shares, and stores your password in the macOS Keychain.

## Security Notes

- **Local network only.** The ACP protocol sends the admin password with XOR encoding (effectively plaintext). Only use on trusted networks.
- **Binary verification.** The Samba binary is verified against SHA256 checksums from the GitHub Release before deployment.
- **SSH access.** SSH is enabled temporarily for deployment. Use `--disable-ssh-after` to disable it when done.
- **Credentials handled securely.** Your password is collected via `getpass()` during setup and never written to disk or logs. The optional launchd agent and menubar app store it in the macOS Keychain (encrypted, protected by your login password).
- **Guest access.** The TimeMachine share allows guest access (no authentication) for ease of use. The share is only accessible on your local network.

## How It Works (Technical Details)

The Time Capsule runs NetBSD 4.0_STABLE on an ARM Cortex-A9 (OABI, not EABI) with 256MB RAM and a 32MB flash chip. Apple's original file sharing uses AFP (port 548) and SMBv1 (port 445 via `wcifsfs`/`wcifsnd`), which modern macOS no longer supports.

TimeCapsuleRevive deploys a statically-compiled Samba 4.8.12 binary with several patches for NetBSD 4.0 compatibility:

- **OABI ARM binary** — NetBSD 5 toolchain (last to support old ABI), ELF patched for NB4 kernel
- **SMBv2/SMBv3 only** — no SMBv1
- **`vfs_fruit`** and **`streams_xattr`** — Apple's SMB extensions for Time Machine
- **Standard ports** (445/139) — old Apple CIFS service killed at startup
- **Minimal memory** — capped at 3 smbd processes for 256MB RAM
- **HFS+ compatible** — ownership checks bypassed (HFS+ returns uid=4294967295)
- **talloc hardened** — reload_services disabled after initial load to prevent use-after-free
- **realpath fix** — NetBSD 4.0 `realpath()` doesn't support NULL argument

## Manual ACP Fallback

If the automated ACP client fails to enable SSH (e.g., due to firmware differences), you can enable SSH manually:

1. Install the [AirPort Utility](https://support.apple.com/en-us/102521) (version 5.6 or earlier for full access)
2. Hold **Option** and click your Time Capsule to access hidden settings
3. Enable **Remote Login** (SSH)
4. Then run: `timecapsule-revive setup --host <your-tc-ip>`

## Building Samba from Source

The CI pipeline cross-compiles Samba automatically on each release tag. To build manually:

```bash
# Requires: Debian bullseye container (for Python 2), git, curl, build-essential
# The build takes ~2 hours on first run (toolchain + sysroot from source)
OUTPUT_DIR=./dist ./build_samba.sh
```

This produces `dist/smbd` (a 14MB static ARM binary) and `dist/SHA256SUMS`.

## Why Save Time Capsules?

Millions of Time Capsules are fully functional hardware — reliable hard drives in well-designed enclosures with built-in networking. The only reason they're "obsolete" is a software compatibility gap that takes 14MB of Samba binary to fix.

Every Time Capsule rescued from e-waste is:
- A hard drive kept out of a landfill
- A backup device given years more useful life
- A small win against planned obsolescence

## License

MIT — see [LICENSE](LICENSE).

## Credits

Based on patterns from [TimeCapsuleSMB](https://github.com/jamesyc/TimeCapsuleSMB) by James Cuzella, and ACP protocol research from [airpyrt-tools](https://github.com/x56/airpyrt-tools).
