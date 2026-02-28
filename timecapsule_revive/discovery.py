"""mDNS discovery for Apple Time Capsule devices on the local network."""

import sys
import time

from zeroconf import ServiceBrowser, ServiceInfo, Zeroconf

AIRPORT_SERVICE = "_airport._tcp.local."
TIME_CAPSULE_MODELS = {"TimeCapsule", "TimeCapsule6,116", "TimeCapsule6,126"}


class _DeviceCollector:
    """Collects discovered AirPort devices from mDNS."""

    def __init__(self):
        self.devices: list[dict] = []

    def add_service(self, zc: Zeroconf, service_type: str, name: str) -> None:
        info = zc.get_service_info(service_type, name)
        if info:
            self._record(info)

    def update_service(self, zc: Zeroconf, service_type: str, name: str) -> None:
        pass

    def remove_service(self, zc: Zeroconf, service_type: str, name: str) -> None:
        pass

    def _record(self, info: ServiceInfo) -> None:
        addresses = info.parsed_addresses()
        if not addresses:
            return

        txt = {}
        if info.properties:
            for k, v in info.properties.items():
                key = k.decode("utf-8", errors="replace") if isinstance(k, bytes) else k
                val = v.decode("utf-8", errors="replace") if isinstance(v, bytes) else str(v)
                txt[key] = val

        model = txt.get("model", txt.get("am", ""))
        self.devices.append({
            "name": info.server or info.name,
            "ip": addresses[0],
            "model": model,
            "txt": txt,
        })


def scan(timeout: float = 5.0) -> list[dict]:
    """Scan for Time Capsule devices via mDNS.

    Returns a list of dicts with keys: name, ip, model, txt.
    """
    zc = Zeroconf()
    collector = _DeviceCollector()
    browser = ServiceBrowser(zc, AIRPORT_SERVICE, collector)

    time.sleep(timeout)
    browser.cancel()
    zc.close()

    # Filter to Time Capsule models, but if no model info available keep all
    tc_devices = [
        d for d in collector.devices
        if any(m in d["model"] for m in TIME_CAPSULE_MODELS)
    ]
    return tc_devices if tc_devices else collector.devices


def select_device(devices: list[dict]) -> dict:
    """Present discovered devices for interactive selection.

    Returns the selected device dict, or exits if none available.
    """
    if not devices:
        print("No Time Capsule devices found on the network.")
        print("Make sure your Time Capsule is powered on and on the same network.")
        sys.exit(1)

    if len(devices) == 1:
        d = devices[0]
        print(f"Found Time Capsule: {d['name']} ({d['ip']})")
        return d

    print(f"Found {len(devices)} device(s):\n")
    for i, d in enumerate(devices, 1):
        model_str = f" [{d['model']}]" if d['model'] else ""
        print(f"  {i}. {d['name']} — {d['ip']}{model_str}")

    print()
    while True:
        try:
            choice = input(f"Select device [1-{len(devices)}]: ").strip()
            idx = int(choice) - 1
            if 0 <= idx < len(devices):
                return devices[idx]
        except (ValueError, EOFError):
            pass
        print(f"Please enter a number between 1 and {len(devices)}.")
