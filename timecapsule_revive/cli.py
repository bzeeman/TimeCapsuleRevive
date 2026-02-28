"""CLI orchestrator for TimeCapsuleRevive."""

import argparse
import getpass
import sys

from timecapsule_revive import __version__


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="timecapsule-revive",
        description="Rescue Apple Time Capsules with modern Samba (SMBv3)",
    )
    parser.add_argument(
        "--version", action="version", version=f"%(prog)s {__version__}"
    )

    subparsers = parser.add_subparsers(dest="command")

    # setup — full automated flow
    setup_parser = subparsers.add_parser(
        "setup", help="Full setup: discover, enable SSH, deploy Samba, verify"
    )
    setup_parser.add_argument(
        "--host", help="Skip discovery and use this IP/hostname directly"
    )
    setup_parser.add_argument(
        "--disable-ssh-after",
        action="store_true",
        help="Disable SSH on the device after deployment",
    )

    # discover — just scan for devices
    subparsers.add_parser(
        "discover", help="Scan the network for Time Capsule devices"
    )

    # verify — just check SMBv3
    verify_parser = subparsers.add_parser(
        "verify", help="Check if SMBv3 is active on a Time Capsule"
    )
    verify_parser.add_argument(
        "--host", required=True, help="IP/hostname of the Time Capsule"
    )

    args = parser.parse_args(argv)

    if not args.command:
        parser.print_help()
        sys.exit(1)

    try:
        if args.command == "setup":
            _cmd_setup(args)
        elif args.command == "discover":
            _cmd_discover()
        elif args.command == "verify":
            _cmd_verify(args)
    except KeyboardInterrupt:
        print("\nAborted.")
        sys.exit(130)
    except Exception as e:
        print(f"\nError: {e}", file=sys.stderr)
        sys.exit(1)


def _cmd_setup(args: argparse.Namespace) -> None:
    from timecapsule_revive import deploy, discovery, ssh, verify

    # Step 1: Discover or use provided host
    if args.host:
        host = args.host
        print(f"Using provided host: {host}")
    else:
        print("Scanning for Time Capsule devices...")
        devices = discovery.scan()
        device = discovery.select_device(devices)
        host = device["ip"]

    # Step 2: Get password
    print()
    password = getpass.getpass("AirPort admin password: ")

    # Step 3: Enable SSH
    print()
    ssh.enable_ssh(host, password)

    # Step 4: Deploy Samba
    print()
    deploy.deploy(host)

    # Step 5: Verify
    print()
    print("Verifying SMBv3...")
    success = verify.verify_smb(host)
    verify.print_status(host, success)

    # Step 6: Optionally disable SSH
    if args.disable_ssh_after:
        print("Disabling SSH as requested...")
        ssh.disable_ssh(host, password)

    sys.exit(0 if success else 1)


def _cmd_discover() -> None:
    from timecapsule_revive import discovery

    print("Scanning for Time Capsule devices...\n")
    devices = discovery.scan()

    if not devices:
        print("No devices found.")
        sys.exit(1)

    for d in devices:
        model = f" [{d['model']}]" if d.get("model") else ""
        print(f"  {d['name']} — {d['ip']}{model}")

    print(f"\n{len(devices)} device(s) found.")


def _cmd_verify(args: argparse.Namespace) -> None:
    from timecapsule_revive import verify

    print(f"Checking SMBv3 on {args.host}...")
    success = verify.verify_smb(args.host)
    verify.print_status(args.host, success)
    sys.exit(0 if success else 1)
