# TimeCapsuleRevive

Rescue Apple Time Capsules from e-waste by deploying modern Samba (SMBv3) with full Time Machine support — compatible through macOS 27 and beyond.

Apple discontinued Time Capsule in 2018 and modern macOS versions have progressively dropped SMBv1 and AFP support, turning millions of perfectly functional backup devices into doorstops. This tool gives them a second life.

## What This Tool Does

TimeCapsuleRevive automates the following steps on your Time Capsule:

1. **Discovers** your Time Capsule on the local network via mDNS
2. **Enables SSH** temporarily using the AirPort Configuration Protocol (ACP)
3. **Downloads** a pre-compiled Samba binary (cross-compiled for NetBSD/ARM) from GitHub Releases
4. **Verifies** the binary's SHA256 checksum before deployment
5. **Uploads** Samba + configuration files to the device via SCP
6. **Installs** PF (packet filter) redirect rules: port 445 → 1445, port 139 → 1139
7. **Starts** Samba with SMBv3 and Time Machine support (via `vfs_fruit`)
8. **Persists** the configuration across reboots via an rc.local hook
9. **Verifies** SMBv3 is responding before declaring success

### What it does NOT do

- Does **not** disable AFP or Apple's built-in file sharing (required for disk auto-mount)
- Does **not** modify the Time Capsule firmware
- Does **not** store your password anywhere — it's collected via `getpass` and used only for the current session

### Files deployed to the device

| File | Location | Purpose |
|------|----------|---------|
| `smbd` | `/Volumes/dk2/samba/sbin/smbd` | Samba server binary |
| `smb.conf` | `/Volumes/dk2/samba/etc/smb.conf` | Samba configuration |
| `pf.conf` | `/mnt/Flash/pf.conf` | PF port redirect rules |
| `rc.samba` | `/mnt/Flash/rc.samba` | Boot startup script |

## Prerequisites

- Python 3.9+
- `pip` or `pipx`
- An SSH client (`ssh`, `scp`) — included on macOS and most Linux distros
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

1. Open **System Settings** → **General** → **Time Machine**
2. Click **+** to add a backup disk
3. Select your Time Capsule (it will appear as an SMB share)
4. Enter `root` as the username and your AirPort admin password

## Security Notes

- **Local network only.** The ACP protocol sends the admin password with trivial XOR encoding (effectively plaintext). Only use this tool on trusted networks.
- **Binary verification.** The Samba binary is verified against SHA256 checksums from the GitHub Release before deployment.
- **SSH access.** SSH is enabled temporarily for deployment. Use `--disable-ssh-after` to automatically disable it when done.
- **No credentials stored.** Your password is collected via `getpass()` and never written to disk or logs.

## How It Works (Technical Details)

The Time Capsule runs NetBSD 6.0 on an ARM Cortex-A9 (earmv4 ABI) with 256MB RAM. Apple's original file sharing uses AFP and SMBv1, which modern macOS no longer supports.

TimeCapsuleRevive deploys a statically-compiled Samba 4.8 binary configured for:
- **SMBv2/SMBv3 only** — no SMBv1
- **`vfs_fruit`** — Apple's SMB extension for Time Machine compatibility
- **High ports** (1445/1139) with PF redirects from standard ports — avoids conflicting with Apple's built-in services
- **Minimal memory** — capped at 3 smbd processes to respect the 256MB RAM constraint

The pre-compiled binary is cross-compiled from a Debian CI environment using the NetBSD evbarm toolchain, ensuring it runs natively on the Time Capsule's ARM processor.

## Manual ACP Fallback

If the automated ACP client fails to enable SSH (e.g., due to firmware differences), you can enable SSH manually:

1. Install the [AirPort Utility](https://support.apple.com/en-us/102521) (version 5.6 or earlier for full access)
2. Hold **Option** and click your Time Capsule to access hidden settings
3. Enable **Remote Login** (SSH)
4. Then run: `timecapsule-revive setup --host <your-tc-ip>`

## Building Samba from Source

The CI pipeline cross-compiles Samba automatically on each release tag. To build manually:

```bash
# Requires: Debian/Ubuntu, git, curl, build-essential, bison, flex, python3
OUTPUT_DIR=./dist ./build_samba.sh
```

This produces `dist/smbd` (a static ARM binary) and `dist/SHA256SUMS`.

## Why Save Time Capsules?

Millions of Time Capsules are fully functional hardware — reliable hard drives in well-designed enclosures with built-in networking. The only reason they're "obsolete" is a software compatibility gap that takes about 17MB of Samba binary to fix.

Every Time Capsule rescued from e-waste is:
- A hard drive kept out of a landfill
- A backup device given years more useful life
- A small win against planned obsolescence

## License

MIT — see [LICENSE](LICENSE).

## Credits

Based on patterns from [TimeCapsuleSMB](https://github.com/jamesyc/TimeCapsuleSMB) by James Cuzella, and ACP protocol research from [airpyrt-tools](https://github.com/x56/airpyrt-tools).
