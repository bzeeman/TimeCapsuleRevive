"""
ACP (AirPort Configuration Protocol) client for Apple Time Capsule.

Ported from airpyrt-tools (github.com/x56/airpyrt-tools) to Python 3.
Only includes the minimal subset needed: connect, authenticate via
password-in-header, get/set properties, and reboot.

Security caveat: The ACP protocol sends the admin password XOR'd with a
static keystream — effectively plaintext. Use only on trusted local networks.
"""

import socket
import struct
import zlib

ACP_PORT = 5009
ACP_MAGIC = b"acpp"
ACP_VERSION = 0x00030001

# Commands
CMD_GETPROP = 0x14
CMD_SETPROP = 0x15

# Static key for password XOR (from airpyrt-tools keystream.py)
_ACP_STATIC_KEY = bytes.fromhex("5b6faf5d9d5b0e1351f2da1de7e8d673")

# Header: magic(4s) version(i) hdr_checksum(i) body_checksum(i) body_size(i)
#          flags(i) unused(i) command(i) error(i) padding(12x) key(32s) padding(48x)
_HEADER_FORMAT = struct.Struct("!4s8I12x32s48x")
_HEADER_SIZE = 128

# Property element header: name(4s) flags(I) size(I)
_PROP_ELEM_FORMAT = struct.Struct("!4sII")
_PROP_ELEM_SIZE = 12

_NULL_ELEMENT = _PROP_ELEM_FORMAT.pack(b"\x00\x00\x00\x00", 0, 4) + b"\x00\x00\x00\x00"


def _generate_keystream(length: int) -> bytes:
    """Generate the ACP XOR keystream."""
    key = bytearray(length)
    for i in range(length):
        key[i] = ((i + 0x55) & 0xFF) ^ _ACP_STATIC_KEY[i % len(_ACP_STATIC_KEY)]
    return bytes(key)


def _encrypt_password(password: str) -> bytes:
    """XOR-encrypt password for the ACP header key field (32 bytes)."""
    pw_len = 32
    keystream = _generate_keystream(pw_len)
    pw_buf = password.encode("ascii")[:pw_len].ljust(pw_len, b"\x00")
    return bytes(keystream[i] ^ pw_buf[i] for i in range(pw_len))


def _pack_header(command: int, flags: int, password: str, body: bytes) -> bytes:
    """Pack an ACP header with Adler32 checksums."""
    key = _encrypt_password(password)
    body_checksum = zlib.adler32(body) if body else 1
    body_size = len(body) if body else 0

    # Pack with header checksum = 0, then compute and repack
    header = _HEADER_FORMAT.pack(
        ACP_MAGIC, ACP_VERSION, 0, body_checksum, body_size,
        flags, 0, command, 0, key,
    )
    hdr_checksum = zlib.adler32(header)
    header = _HEADER_FORMAT.pack(
        ACP_MAGIC, ACP_VERSION, hdr_checksum, body_checksum, body_size,
        flags, 0, command, 0, key,
    )
    return header


def _parse_header(data: bytes) -> dict:
    """Parse a 128-byte ACP response header."""
    (magic, version, hdr_checksum, body_checksum, body_size,
     flags, unused, command, error, key) = _HEADER_FORMAT.unpack(data)
    return {
        "magic": magic,
        "version": version,
        "body_size": body_size,
        "flags": flags,
        "command": command,
        "error": error,
    }


def _pack_property(name: bytes, value: bytes) -> bytes:
    """Pack a single property element (name + flags + size + value)."""
    return _PROP_ELEM_FORMAT.pack(name, 0, len(value)) + value


def _pack_null_property(name: bytes) -> bytes:
    """Pack a null property element for GET requests."""
    null_val = b"\x00\x00\x00\x00"
    return _PROP_ELEM_FORMAT.pack(name, 0, len(null_val)) + null_val


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    """Receive exactly n bytes from a socket."""
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("Connection closed while reading ACP response")
        data.extend(chunk)
    return bytes(data)


class ACPError(Exception):
    """ACP protocol error."""


class ACPClient:
    """Minimal ACP client for Time Capsule administration.

    Usage:
        with ACPClient("10.0.1.1", "admin_password") as acp:
            acp.set_property(b"dbug", 0x3000)
            acp.reboot()
    """

    def __init__(self, host: str, password: str, timeout: float = 10.0):
        self.host = host
        self.password = password
        self.timeout = timeout
        self._sock = None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *exc):
        self.close()

    def connect(self):
        """Open TCP connection to ACP port."""
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.settimeout(self.timeout)
        self._sock.connect((self.host, ACP_PORT))

    def close(self):
        """Close the connection."""
        if self._sock:
            self._sock.close()
            self._sock = None

    def _send_command(self, command: int, flags: int, body: bytes) -> dict:
        """Send an ACP command and return the parsed response header."""
        header = _pack_header(command, flags, self.password, body)
        self._sock.sendall(header + body)

        resp_hdr_data = _recv_exact(self._sock, _HEADER_SIZE)
        resp = _parse_header(resp_hdr_data)

        if resp["error"] != 0:
            raise ACPError(
                f"ACP error 0x{resp['error'] & 0xFFFFFFFF:08x} "
                f"for command 0x{command:02x}"
            )
        return resp

    def get_property(self, name: bytes) -> bytes:
        """Get a single property value by its 4-byte name."""
        body = _pack_null_property(name) + _NULL_ELEMENT
        self._send_command(CMD_GETPROP, 4, body)

        # Read response elements until null terminator
        while True:
            elem_hdr = _recv_exact(self._sock, _PROP_ELEM_SIZE)
            elem_name, elem_flags, elem_size = _PROP_ELEM_FORMAT.unpack(elem_hdr)
            elem_data = _recv_exact(self._sock, elem_size)

            if elem_name == b"\x00\x00\x00\x00":
                break
            if elem_flags & 1:
                raise ACPError(
                    f"Property {name!r} error: 0x{int.from_bytes(elem_data, 'big'):08x}"
                )
            if elem_name == name:
                return elem_data

        raise ACPError(f"Property {name!r} not found in response")

    def set_property(self, name: bytes, value: int) -> None:
        """Set a property to an integer value (packed as 4-byte big-endian)."""
        packed_value = struct.pack("!I", value)
        body = _pack_property(name, packed_value) + _NULL_ELEMENT
        self._send_command(CMD_SETPROP, 0, body)

        # Consume response elements
        while True:
            elem_hdr = _recv_exact(self._sock, _PROP_ELEM_SIZE)
            elem_name, _, elem_size = _PROP_ELEM_FORMAT.unpack(elem_hdr)
            _recv_exact(self._sock, elem_size)
            if elem_name == b"\x00\x00\x00\x00":
                break

    def enable_ssh(self) -> None:
        """Enable SSH by setting dbug=0x3000."""
        self.set_property(b"dbug", 0x3000)

    def reboot(self) -> None:
        """Reboot the device by setting acRB=0."""
        self.set_property(b"acRB", 0)
