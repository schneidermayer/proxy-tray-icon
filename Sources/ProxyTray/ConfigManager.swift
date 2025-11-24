import Foundation

struct CIDREntry {
    let network: String
    let mask: String
}

final class ConfigManager {
    private let baseDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".proxy-tray", isDirectory: true)

    var whitelistPath: String {
        baseDir.appendingPathComponent("whitelist.txt").path
    }

    var sshSettingsPath: String {
        baseDir.appendingPathComponent("ssh.json").path
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

    func writePAC(for entries: [CIDREntry]) throws -> String {
        let pacURL = baseDir.appendingPathComponent("proxy.pac")
        var rules: [String] = []
        for entry in entries {
            rules.append("  { net: \"\(entry.network)\", mask: \"\(entry.mask)\" }")
        }
        let body = pacTemplate(replacements: ["WHITELIST": rules.joined(separator: ",\n")])
        try body.write(to: pacURL, atomically: true, encoding: .utf8)
        return pacURL.path
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
        let data = try JSONEncoder().encode(sanitized)
        try data.write(to: URL(fileURLWithPath: sshSettingsPath))
    }

    private func sanitize(_ settings: SshSettings) -> SshSettings {
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return SshSettings(host: host, username: user, port: settings.port)
    }

    private func validate(settings: SshSettings) throws {
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "SSH host must not be empty"])
        }
        guard !user.isEmpty else {
            throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "SSH username must not be empty"])
        }
        guard (1...65535).contains(settings.port) else {
            throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "SSH port must be between 1 and 65535"])
        }
    }
}
