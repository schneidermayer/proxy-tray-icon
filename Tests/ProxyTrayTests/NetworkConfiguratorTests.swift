import XCTest
@testable import ProxyTray

final class NetworkConfiguratorTests: XCTestCase {
    func testSuccessfulCleanupReturnsNoFailures() {
        var commands: [[String]] = []
        let network = NetworkConfigurator { arguments in
            commands.append(arguments)
            return arguments == ["-listallnetworkservices"]
                ? "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\nEthernet\n*Disabled\n"
                : ""
        }

        XCTAssertEqual(network.disableProxy(), [])
        XCTAssertEqual(commands, [
            ["-listallnetworkservices"],
            ["-getinfo", "Wi-Fi"],
            ["-getinfo", "Ethernet"],
            ["-setautoproxystate", "Wi-Fi", "off"],
            ["-setsocksfirewallproxystate", "Wi-Fi", "off"],
            ["-setautoproxystate", "Ethernet", "off"],
            ["-setsocksfirewallproxystate", "Ethernet", "off"]
        ])
    }

    func testEnumerationFailureIncludesUnderlyingError() {
        var commands: [[String]] = []
        let network = NetworkConfigurator { arguments in
            commands.append(arguments)
            throw Self.error("Network configuration is unavailable")
        }

        let failures = network.disableProxy()

        XCTAssertEqual(failures, ["Could not list network services: Network configuration is unavailable"])
        XCTAssertEqual(commands, [["-listallnetworkservices"]])
    }

    func testCleanupReportsFailuresAndContinuesRemainingCommandsAndServices() {
        var commands: [[String]] = []
        let network = NetworkConfigurator { arguments in
            commands.append(arguments)
            if arguments == ["-listallnetworkservices"] {
                return "Wi-Fi\nEthernet\n"
            }
            if arguments == ["-setautoproxystate", "Wi-Fi", "off"] {
                throw Self.error("Authorization denied")
            }
            if arguments == ["-setsocksfirewallproxystate", "Ethernet", "off"] {
                throw Self.error("Service disappeared")
            }
            return ""
        }

        let failures = network.disableProxy()

        XCTAssertEqual(failures, [
            "Could not disable PAC proxy for \"Wi-Fi\" (networksetup -setautoproxystate): Authorization denied",
            "Could not disable SOCKS proxy for \"Ethernet\" (networksetup -setsocksfirewallproxystate): Service disappeared"
        ])
        XCTAssertEqual(Array(commands.suffix(4)), [
            ["-setautoproxystate", "Wi-Fi", "off"],
            ["-setsocksfirewallproxystate", "Wi-Fi", "off"],
            ["-setautoproxystate", "Ethernet", "off"],
            ["-setsocksfirewallproxystate", "Ethernet", "off"]
        ])
    }

    func testServiceInspectionFailureIsReportedWhileOtherServicesAreCleanedUp() {
        var commands: [[String]] = []
        let network = NetworkConfigurator { arguments in
            commands.append(arguments)
            if arguments == ["-listallnetworkservices"] {
                return "Wi-Fi\nEthernet\n"
            }
            if arguments == ["-getinfo", "Wi-Fi"] {
                throw Self.error("Service disappeared")
            }
            return ""
        }

        let failures = network.disableProxy()

        XCTAssertEqual(failures, [
            "Could not inspect network service \"Wi-Fi\" (networksetup -getinfo): Service disappeared"
        ])
        XCTAssertEqual(Array(commands.suffix(2)), [
            ["-setautoproxystate", "Ethernet", "off"],
            ["-setsocksfirewallproxystate", "Ethernet", "off"]
        ])
    }

    private static func error(_ description: String) -> NSError {
        NSError(domain: "NetworkConfiguratorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
