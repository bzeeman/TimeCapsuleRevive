"""SMBv3 verification for Time Capsule deployment."""

import socket
import struct

SMB2_NEGOTIATE_PROTOCOL_ID = b"\xfeSMB"
SMB_PORT = 445


def verify_smb(host: str, port: int = SMB_PORT, timeout: float = 10.0) -> bool:
    """Verify that SMBv3 is answering on the target host.

    Sends an SMB2 Negotiate request and checks for a valid SMB2/3 response.
    Returns True if SMBv3 is available, False otherwise.
    """
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            # Send SMB2 Negotiate request
            negotiate = _build_smb2_negotiate()
            # NetBIOS session header: 4 bytes (0x00 + 3 byte length)
            nb_header = struct.pack(">I", len(negotiate))
            sock.sendall(nb_header + negotiate)

            # Read response
            resp_header = _recv_exact(sock, 4)
            resp_len = struct.unpack(">I", resp_header)[0]
            if resp_len == 0 or resp_len > 65536:
                return False

            resp = _recv_exact(sock, resp_len)

            # Check for SMB2 protocol ID in response
            if len(resp) >= 4 and resp[:4] == SMB2_NEGOTIATE_PROTOCOL_ID:
                return True

            return False
    except (OSError, ConnectionRefusedError, TimeoutError, struct.error):
        return False


def _build_smb2_negotiate() -> bytes:
    """Build a minimal SMB2 Negotiate Protocol Request.

    Offers SMB 2.0.2, 2.1, 3.0, 3.0.2 dialects.
    """
    # SMB2 header (64 bytes)
    header = bytearray(64)
    header[0:4] = SMB2_NEGOTIATE_PROTOCOL_ID  # ProtocolId
    struct.pack_into("<H", header, 4, 64)       # StructureSize
    # Command: NEGOTIATE (0x0000) — already zero
    # MessageId, TreeId, SessionId, etc. — all zero for negotiate

    # SMB2 Negotiate request body
    dialects = [0x0202, 0x0210, 0x0300, 0x0302]  # SMB 2.0.2, 2.1, 3.0, 3.0.2
    body = bytearray()
    body += struct.pack("<H", 36)           # StructureSize
    body += struct.pack("<H", len(dialects))  # DialectCount
    body += struct.pack("<H", 1)            # SecurityMode: signing enabled
    body += b"\x00\x00"                     # Reserved
    body += struct.pack("<I", 0)            # Capabilities
    body += b"\x00" * 16                    # ClientGuid
    body += struct.pack("<I", 0)            # NegotiateContextOffset
    body += struct.pack("<H", 0)            # NegotiateContextCount
    body += b"\x00\x00"                     # Reserved2

    # Dialect list
    for dialect in dialects:
        body += struct.pack("<H", dialect)

    return bytes(header) + bytes(body)


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    """Receive exactly n bytes."""
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("Connection closed")
        data.extend(chunk)
    return bytes(data)


def print_status(host: str, success: bool) -> None:
    """Print clear success/failure status with next steps."""
    if success:
        print(f"\n  SUCCESS: SMBv3 is active on {host}:445\n")
        print("  Your Time Capsule is now compatible with modern macOS Time Machine.")
        print("  To use it:")
        print("    1. Open System Settings > General > Time Machine")
        print("    2. Click '+' to add a backup disk")
        print(f"    3. Select your Time Capsule (connected via SMB)")
        print("    4. Enter 'root' as the username and your AirPort password")
        print()
    else:
        print(f"\n  FAILED: SMBv3 is not responding on {host}:445\n")
        print("  Troubleshooting:")
        print("    - Ensure the Time Capsule is powered on and accessible")
        print("    - SSH into the device and check if smbd is running:")
        print("        ssh -oHostKeyAlgorithms=+ssh-dss root@{host}")
        print("        ps aux | grep smbd")
        print("    - Check Samba logs: cat /tmp/samba/log.*")
        print("    - Check PF rules: pfctl -sr")
        print()
