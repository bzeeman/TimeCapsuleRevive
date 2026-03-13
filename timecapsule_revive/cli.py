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

    # monitor — check and start Samba (single check or continuous watch)
    monitor_parser = subparsers.add_parser(
        "monitor", help="Monitor Time Capsule and auto-start Samba"
    )
    monitor_parser.add_argument(
        "--host", required=True, help="IP/hostname of the Time Capsule"
    )
    monitor_parser.add_argument(
        "--once", action="store_true",
        help="Check once and exit (for launchd agent use)",
    )
    monitor_parser.add_argument(
        "--interval", type=int, default=60,
        help="Seconds between checks in watch mode (default: 60)",
    )

    # install-agent — macOS launchd agent
    agent_parser = subparsers.add_parser(
        "install-agent",
        help="Install macOS launchd agent for automatic Samba restart",
    )
    agent_parser.add_argument(
        "--host", required=True, help="IP/hostname of the Time Capsule"
    )
    agent_parser.add_argument(
        "--interval", type=int, default=120,
        help="Seconds between checks (default: 120)",
    )

    # uninstall-agent
    subparsers.add_parser(
        "uninstall-agent", help="Remove the macOS launchd agent"
    )

    # shares — manage SMB shares
    shares_parser = subparsers.add_parser(
        "shares", help="Manage SMB shares (list, add, remove)"
    )
    shares_sub = shares_parser.add_subparsers(dest="shares_command")

    shares_list = shares_sub.add_parser("list", help="List current shares")
    shares_list.add_argument("--host", required=True)

    shares_add = shares_sub.add_parser("add", help="Add a new share")
    shares_add.add_argument("--host", required=True)
    shares_add.add_argument("--name", required=True, help="Share name")
    shares_add.add_argument("--path", required=True, help="Path on device")
    shares_add.add_argument(
        "--time-machine", action="store_true",
        help="Enable Time Machine support for this share",
    )
    shares_add.add_argument(
        "--readonly", action="store_true", help="Make share read-only"
    )

    shares_remove = shares_sub.add_parser("remove", help="Remove a share")
    shares_remove.add_argument("--host", required=True)
    shares_remove.add_argument("--name", required=True, help="Share name")

    shares_volumes = shares_sub.add_parser(
        "volumes", help="List mounted volumes on device"
    )
    shares_volumes.add_argument("--host", required=True)

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
        elif args.command == "monitor":
            _cmd_monitor(args)
        elif args.command == "install-agent":
            _cmd_install_agent(args)
        elif args.command == "uninstall-agent":
            _cmd_uninstall_agent()
        elif args.command == "shares":
            _cmd_shares(args)
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


def _cmd_monitor(args: argparse.Namespace) -> None:
    from timecapsule_revive import monitor

    if args.once:
        success = monitor.check_and_start(args.host)
        sys.exit(0 if success else 1)
    else:
        monitor.watch(args.host, interval=args.interval)


def _cmd_install_agent(args: argparse.Namespace) -> None:
    from timecapsule_revive import agent

    password = getpass.getpass("AirPort admin password (stored in Keychain): ")
    agent.install(args.host, password, interval=args.interval)


def _cmd_uninstall_agent() -> None:
    from timecapsule_revive import agent

    agent.uninstall()


def _cmd_shares(args: argparse.Namespace) -> None:
    from timecapsule_revive import shares

    if not args.shares_command:
        print("Usage: timecapsule-revive shares {list,add,remove,volumes}")
        sys.exit(1)

    if args.shares_command == "list":
        share_list = shares.list_shares(args.host)
        if not share_list:
            print("No shares configured.")
            return
        for s in share_list:
            tm = " [Time Machine]" if s.get("timemachine") else ""
            print(f"  [{s['name']}] {s['path']}{tm}")

    elif args.shares_command == "add":
        shares.add_share(
            args.host,
            name=args.name,
            path=args.path,
            timemachine=args.time_machine,
            readonly=args.readonly,
        )

    elif args.shares_command == "remove":
        shares.remove_share(args.host, name=args.name)

    elif args.shares_command == "volumes":
        vols = shares.list_volumes(args.host)
        if not vols:
            print("No volumes mounted.")
            return
        for v in vols:
            print(f"  {v['mountpoint']}  ({v['capacity']} used, {v['device']})")
