import Foundation

actor SSHService {
    private let sshOptions: [String] = [
        "-oHostKeyAlgorithms=+ssh-rsa",
        "-oKexAlgorithms=+diffie-hellman-group14-sha1",
        "-oPubkeyAuthentication=no",
        "-oStrictHostKeyChecking=accept-new",
        "-oConnectTimeout=10",
    ]

    func runCommand(host: String, command: String) async throws -> String {
        let password = KeychainService.getPassword(forHost: host)

        // Write askpass helper to temp file
        let askpassURL = try writeAskpass(password: password ?? "")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshOptions + ["root@\(host)", command]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SSH_ASKPASS": askpassURL.path,
            "SSH_ASKPASS_REQUIRE": "force",
        ]

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        // Clean up askpass
        try? FileManager.default.removeItem(at: askpassURL)

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw SSHError.commandFailed(process.terminationStatus, err)
        }

        return output
    }

    private func writeAskpass(password: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("tc-askpass-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        echo '\(password.replacingOccurrences(of: "'", with: "'\\''"))'
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path
        )
        return url
    }
}

enum SSHError: LocalizedError {
    case commandFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let code, let msg):
            return "SSH failed (exit \(code)): \(msg)"
        }
    }
}
