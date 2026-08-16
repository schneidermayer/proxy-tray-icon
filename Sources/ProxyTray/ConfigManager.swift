import Foundation

struct CIDREntry {
    let network: String
    let mask: String
}

struct PacArtifact {
    let path: String
    let autoProxyURL: String
}

final class ConfigManager {
    private let baseDir: URL

    init(baseDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".proxy-tray", isDirectory: true)) {
        self.baseDir = baseDir
    }

    var whitelistPath: String {
        baseDir.appendingPathComponent("whitelist.txt").path
    }

    var sshSettingsPath: String {
        baseDir.appendingPathComponent("ssh.json").path
    }

    var importedPrivateKeyPath: String {
        baseDir
            .appendingPathComponent("keys", isDirectory: true)
            .appendingPathComponent("identity")
            .path
    }

    func ensureFilesExist() {
        if !FileManager.default.fileExists(atPath: baseDir.path) {
            try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: nil)
        }
        if !FileManager.default.fileExists(atPath: whitelistPath) {
            try? "# one IPv4 or CIDR per line\n# example:\n10.0.0.0/8\n192.168.0.0/16\n127.0.0.1/32\n".write(toFile: whitelistPath, atomically: true, encoding: .utf8)
        }
        if !FileManager.default.fileExists(atPath: sshSettingsPath) {
            try? saveSshSettings(SshSettings.defaultSettings)
        }
    }

    func loadWhitelist() throws -> [CIDREntry] {
        let raw = try String(contentsOfFile: whitelistPath)
        // Allow both Unix and Windows line endings by trimming newlines as well
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var entries: [CIDREntry] = []
        for line in lines {
            if line.hasPrefix("#") || line.isEmpty { continue }
            if let entry = parse(line: line) {
                entries.append(entry)
            }
        }
        if entries.isEmpty {
            throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "Whitelist is empty or invalid"])
        }
        return entries
    }

    func writePAC(for entries: [CIDREntry]) throws -> PacArtifact {
        let pacURL = baseDir.appendingPathComponent("proxy.pac")
        var rules: [String] = []
        for entry in entries {
            rules.append("  { net: \"\(entry.network)\", mask: \"\(entry.mask)\" }")
        }
        let body = pacTemplate(replacements: ["WHITELIST": rules.joined(separator: ",\n")])
        try body.write(to: pacURL, atomically: true, encoding: .utf8)
        guard let data = body.data(using: .utf8) else {
            throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not encode PAC data"])
        }
        let b64 = data.base64EncodedString()
        let dataURL = "data:application/x-javascript-config;base64,\(b64)"
        return PacArtifact(path: pacURL.path, autoProxyURL: dataURL)
    }

    private func parse(line: String) -> CIDREntry? {
        let parts = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .map(String.init)
        guard parts.count == 2, let bits = Int(parts[1]), bits >= 0, bits <= 32 else {
            if parts.count == 1 {
                if let mask = maskFrom(bits: 32), isValidIP(parts[0]) { return CIDREntry(network: parts[0], mask: mask) }
                return nil
            }
            return nil
        }
        guard isValidIP(parts[0]), let mask = maskFrom(bits: bits) else { return nil }
        return CIDREntry(network: parts[0], mask: mask)
    }

    private func maskFrom(bits: Int) -> String? {
        guard bits >= 0 && bits <= 32 else { return nil }
        let maskValue: UInt32 = bits == 0 ? 0 : ~((UInt32(1) << (32 - bits)) - 1)
        let octets = (0..<4).reversed().map { shift -> String in
            let octet = (maskValue >> (shift * 8)) & 0xff
            return String(octet)
        }
        return octets.joined(separator: ".")
    }

    private func isValidIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            if let num = Int(part), num >= 0 && num <= 255 { return true }
            return false
        }
    }

    private func pacTemplate(replacements: [String: String]) -> String {
        let template = """
        function FindProxyForURL(url, host) {
          var socks = "SOCKS 127.0.0.1:1080";
          var whitelist = [\nWHITELIST\n          ];
          var resolved = dnsResolve(host);
          if (!resolved) { return "DIRECT"; }
          for (var i = 0; i < whitelist.length; i++) {
            var item = whitelist[i];
            if (isInNet(resolved, item.net, item.mask)) {
              return socks;
            }
          }
          return "DIRECT";
        }
        """
        var output = template
        for (key, value) in replacements {
            output = output.replacingOccurrences(of: key, with: value)
        }
        return output
    }

    func loadSshSettings() throws -> SshSettings {
        let data = try Data(contentsOf: URL(fileURLWithPath: sshSettingsPath))
        let settings = sanitize(try JSONDecoder().decode(SshSettings.self, from: data))
        try validate(settings: settings)
        return settings
    }

    func saveSshSettings(_ settings: SshSettings) throws {
        let sanitized = sanitize(settings)
        try validate(settings: sanitized)
        try FileManager.default.createDirectory(
            at: baseDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let data = try JSONEncoder().encode(sanitized)
        try data.write(to: URL(fileURLWithPath: sshSettingsPath))
    }

    func validateSshEndpoint(host: String, username: String, port: Int) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "SSH host must not be empty"])
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "SSH username must not be empty"])
        }
        guard (1...65535).contains(port) else {
            throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "SSH port must be between 1 and 65535"])
        }
    }

    func privateKeyRequiresPassphrase(at sourceURL: URL) throws -> Bool {
        _ = try readPrivateKey(at: sourceURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-y", "-P", "", "-f", sourceURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus != 0
    }

    func importPrivateKey(from sourceURL: URL) throws -> String {
        let keyData = try readPrivateKey(at: sourceURL)
        let destinationURL = URL(fileURLWithPath: importedPrivateKeyPath)
        let keyDirectory = destinationURL.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: keyDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: keyDirectory.path
        )
        let temporaryURL = keyDirectory
            .appendingPathComponent(".identity-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: keyData,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not create the imported SSH private key"])
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL
            )
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
        return destinationURL.path
    }

    func removeImportedPrivateKey() throws {
        let path = importedPrivateKeyPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }

    private func sanitize(_ settings: SshSettings) -> SshSettings {
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawIdentityFile = settings.identityFile?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identityFile = rawIdentityFile.flatMap { path -> String? in
            guard !path.isEmpty else { return nil }
            return NSString(string: path).expandingTildeInPath
        }
        return SshSettings(
            host: host,
            username: user,
            port: settings.port,
            identityFile: identityFile
        )
    }

    private func validate(settings: SshSettings) throws {
        try validateSshEndpoint(
            host: settings.host,
            username: settings.username,
            port: settings.port
        )
        if let identityFile = settings.identityFile {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: identityFile, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: identityFile) else {
                throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "SSH private key is missing or unreadable"])
            }
        }
    }

    private func readPrivateKey(at sourceURL: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "Select an SSH private key file, not a directory"])
        }
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else {
            throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "SSH private key file is unexpectedly large"])
        }

        let data = try Data(contentsOf: sourceURL)
        let prefix = String(data: data.prefix(128), encoding: .utf8) ?? ""
        let supportedHeaders = [
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "-----BEGIN PRIVATE KEY-----",
            "-----BEGIN ENCRYPTED PRIVATE KEY-----",
            "-----BEGIN RSA PRIVATE KEY-----",
            "-----BEGIN EC PRIVATE KEY-----",
            "-----BEGIN DSA PRIVATE KEY-----"
        ]
        guard supportedHeaders.contains(where: prefix.contains) else {
            throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "The selected file is not a supported SSH private key"])
        }
        return data
    }
}
