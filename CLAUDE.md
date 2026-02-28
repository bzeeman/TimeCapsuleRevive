Project: TimeCapsuleRevive — an open source CLI tool that rescues Apple Time Capsules from planned obsolescence by replacing their SMBv1/AFP stack with modern Samba over SMBv3, restoring full Time Machine compatibility through macOS 27 and beyond.
Reference implementation: https://github.com/jamesyc/TimeCapsuleSMB
Build environment: Debian 13 x86_64 (Proxmox VM)
Target device: Apple Time Capsule (any generation), NetBSD 6.0 evbarm, ARM Cortex-A9, earmv4 ABI, 256MB RAM, 32MB flash
Tool language: Python 3, packaged as a single CLI with no required external dependencies beyond standard library and AirPyrt
Architecture:

Discovery phase — mDNS scan the local network for Time Capsule devices, present found devices to the user for selection. Don't require manual hostname/IP entry.
Authentication phase — prompt for base station password at runtime using getpass (never echoed, never stored, never logged). Use AirPyrt/ACP to enable SSH on the selected device.
Samba binary delivery — download pre-compiled statically linked Samba binaries from the project's GitHub Releases (to be built by CI). Verify SHA256 checksum before deploying. Do not build on the user's machine.
Configuration generation — generate smb.conf at runtime targeting the specific device, configured for SMBv3, Time Machine support via vfs_fruit, bound to ports 1445/1139, minimal worker processes to respect 256MB RAM constraint.
Deployment phase — SCP binaries and configs to /mnt/Flash on the device via SSH with -oHostKeyAlgorithms=+ssh-dss. Install pf redirect rules (445→1445, 139→1139). Do not disable AFP — required for disk auto-mount at /Volumes/dk2/ShareRoot.
Startup persistence — install a NetBSD-compatible rc hook that survives reboots, reloading pf rules and starting Samba on boot.
Verification phase — confirm SMBv3 is answering on port 445 before declaring success. Print clear success/failure status.

CI pipeline (GitHub Actions):

On each release tag, spin up a Debian container
Install NetBSD evbarm cross-compilation toolchain
Cross-compile Samba statically linked for earmv4
Upload binaries as release artifacts with SHA256 checksums
Tool downloads from releases at runtime

Security requirements:

All credentials via getpass, never stored or logged
Checksum verification before any binary execution on target
README must document exactly what the tool does to the device before users run it
SSH disabled again after provisioning (optional flag)

Deliverables:

timecapsule_revive.py — single-file CLI tool
build_samba.sh — cross-compilation script for CI
.github/workflows/release.yml — GitHub Actions workflow
README.md — prerequisites, usage, what it does, AirPyrt manual step if needed, ewaste motivation
LICENSE — MIT

Out of scope for this iteration: GUI, Windows support, non-Time-Capsule AirPort devices
