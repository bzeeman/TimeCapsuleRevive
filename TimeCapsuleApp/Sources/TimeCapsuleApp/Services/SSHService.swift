import Foundation
import CSSH2

actor SSHService {
    func runCommand(host: String, command: String) async throws -> String {
        let password = KeychainService.getPassword(forHost: host)

        guard let password, !password.isEmpty else {
            throw SSHError.noPassword
        }

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do {
                    let result = try Self.sshExecute(
                        host: host, port: 22,
                        username: "root", password: password,
                        command: command
                    )
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func sshExecute(
        host: String, port: Int32,
        username: String, password: String,
        command: String
    ) throws -> String {
        guard libssh2_init(0) == 0 else {
            throw SSHError.initFailed
        }
        defer { libssh2_exit() }

        // TCP connect
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw SSHError.connectionFailed(host, "socket creation failed")
        }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian

        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            throw SSHError.connectionFailed(host, "invalid IP address")
        }

        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw SSHError.connectionFailed(host, String(cString: strerror(errno)))
        }

        // SSH session
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw SSHError.connectionFailed(host, "session init failed")
        }
        defer { libssh2_session_free(session) }

        libssh2_session_set_timeout(session, 15000)

        guard libssh2_session_handshake(session, sock) == 0 else {
            throw SSHError.connectionFailed(host, sessionError(session))
        }

        // Password auth
        guard libssh2_userauth_password_ex(
            session,
            username, UInt32(username.utf8.count),
            password, UInt32(password.utf8.count),
            nil
        ) == 0 else {
            throw SSHError.authFailed(sessionError(session))
        }

        // Open channel (the _ex variant of libssh2_channel_open_session)
        let channelType = "session"
        guard let channel = libssh2_channel_open_ex(
            session,
            channelType, UInt32(channelType.utf8.count),
            UInt32(2 * 1024 * 1024), UInt32(32768),
            nil, 0
        ) else {
            throw SSHError.commandFailed(-1, "open channel: \(sessionError(session))")
        }
        defer {
            libssh2_channel_close(channel)
            libssh2_channel_free(channel)
        }

        // Execute (the _ex variant of libssh2_channel_exec)
        let reqType = "exec"
        guard libssh2_channel_process_startup(
            channel,
            reqType, UInt32(reqType.utf8.count),
            command, UInt32(command.utf8.count)
        ) == 0 else {
            throw SSHError.commandFailed(-1, "exec: \(sessionError(session))")
        }

        // Read stdout (stream_id 0)
        var output = Data()
        var buf = [CChar](repeating: 0, count: 4096)
        while true {
            let rc = libssh2_channel_read_ex(channel, 0, &buf, buf.count)
            if rc > 0 {
                output.append(Data(bytes: buf, count: rc))
            } else {
                break
            }
        }

        // Read stderr (stream_id SSH_EXTENDED_DATA_STDERR = 1)
        var stderrData = Data()
        while true {
            let rc = libssh2_channel_read_ex(channel, 1, &buf, buf.count)
            if rc > 0 {
                stderrData.append(Data(bytes: buf, count: rc))
            } else {
                break
            }
        }

        libssh2_channel_send_eof(channel)
        libssh2_channel_wait_eof(channel)
        libssh2_channel_wait_closed(channel)

        let exitCode = libssh2_channel_get_exit_status(channel)
        let stdout = String(data: output, encoding: .utf8) ?? ""

        if exitCode != 0 {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw SSHError.commandFailed(exitCode, stderr.isEmpty ? stdout : stderr)
        }

        return stdout
    }

    private static func sessionError(_ session: OpaquePointer) -> String {
        var msgPtr: UnsafeMutablePointer<CChar>?
        var msgLen: Int32 = 0
        libssh2_session_last_error(session, &msgPtr, &msgLen, 0)
        if let msgPtr {
            return String(cString: msgPtr)
        }
        return "unknown error"
    }
}

enum SSHError: LocalizedError {
    case noPassword
    case initFailed
    case connectionFailed(String, String)
    case authFailed(String)
    case commandFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .noPassword:
            return "No password configured — open Settings and enter the AirPort admin password"
        case .initFailed:
            return "Failed to initialize SSH library"
        case .connectionFailed(let host, let detail):
            return "Could not connect to \(host): \(detail)"
        case .authFailed(let detail):
            return "Authentication failed: \(detail)"
        case .commandFailed(let code, let msg):
            return "Command failed (exit \(code)): \(msg)"
        }
    }
}
