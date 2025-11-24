import Foundation

final class NetworkConfigurator {
    private let networksetup = "/usr/sbin/networksetup"

    enum ProxyState {
        case none
        case pac
        case socks
    }

    func enablePACProxy(pacURLString: String) throws {
        let services = try listServices()
        for service in services {
            try run(["-setsocksfirewallproxystate", service, "off"])
            try run(["-setautoproxyurl", service, pacURLString])
            try run(["-setautoproxystate", service, "on"])
        }
    }

    func enableRouteAllProxy() throws {
        let services = try listServices()
        for service in services {
            try run(["-setautoproxystate", service, "off"])
            try run(["-setsocksfirewallproxy", service, "127.0.0.1", "1080"])
            try run(["-setsocksfirewallproxystate", service, "on"])
        }
    }

    func disableProxy() {
        guard let services = try? listServices() else { return }
        for service in services {
            _ = try? run(["-setautoproxystate", service, "off"])
            _ = try? run(["-setsocksfirewallproxystate", service, "off"])
        }
    }

    func detectProxyState() -> ProxyState {
        guard let services = try? listServices() else { return .none }
        var hasPac = false
        var hasSocks = false

        for service in services {
            if let pac = try? runAndCapture(["-getautoproxyurl", service]) {
                if pac.lowercased().contains("enabled: yes") &&
                    (pac.contains(".proxy-tray/proxy.pac") || pac.contains("data:application/x-javascript-config;base64")) {
                    hasPac = true
                }
            }
            if let socks = try? runAndCapture(["-getsocksfirewallproxy", service]) {
                if socks.lowercased().contains("enabled: yes") &&
                    socks.contains("127.0.0.1") &&
                    socks.contains("1080") {
                    hasSocks = true
                }
            }
        }

        if hasSocks { return .socks }
        if hasPac { return .pac }
        return .none
    }

    private func listServices() throws -> [String] {
        let output = try runAndCapture(["-listallnetworkservices"])
        let lines = output.split(separator: "\n").map(String.init)
        var services: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("*") { continue }
            if trimmed.lowercased().contains("asterisk") { continue }
            if (try? runAndCapture(["-getinfo", trimmed])) != nil {
                services.append(trimmed)
            }
        }
        if services.isEmpty {
            throw NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: "No usable network services found"])
        }
        return services
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        try runAndCapture(arguments)
    }

    private func runAndCapture(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: networksetup)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(domain: "ProxyTray", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }
}
