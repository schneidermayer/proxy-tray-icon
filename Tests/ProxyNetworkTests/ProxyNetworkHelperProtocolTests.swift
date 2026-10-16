import Foundation
import XCTest
@testable import ProxyNetwork

final class ProxyNetworkHelperProtocolTests: XCTestCase {
    private let service = NetworkProxyService(id: "12345678-ABCD-1234-ABCD-123456789ABC", name: "Wi-Fi")

    func testValidRequestPassesServiceAndComparisonSnapshotsToStore() throws {
        let expected = try NetworkProxySettings(configuration: ["SOCKSEnable": 0])
        let desired = try expected.configured(pacURLString: nil)
        let store = RecordingStore()

        try NetworkProxyWriteRequest.perform(data: encode(expected: expected, desired: desired), store: store)

        XCTAssertEqual(store.writes.count, 1)
        XCTAssertEqual(store.writes.first?.service.id, service.id)
        XCTAssertEqual(store.writes.first?.service.name, service.name)
        XCTAssertEqual(store.writes.first?.expected, expected)
        XCTAssertEqual(store.writes.first?.desired, desired)
    }

    func testMalformedAndOversizedRequestsNeverReachStore() throws {
        let store = RecordingStore()
        for data in [Data(), Data("invalid json".utf8), Data(repeating: 0, count: NetworkProxyWriteRequest.maximumBytes + 1)] {
            XCTAssertThrowsError(try NetworkProxyWriteRequest.perform(data: data, store: store))
        }
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testUnknownEnvelopeAndNestedFieldsNeverReachStore() throws {
        let store = RecordingStore()
        var envelope = try requestObject()
        envelope["command"] = "anything"
        XCTAssertThrowsError(try perform(envelope, store: store))

        for field in ["service", "expected", "desired"] {
            envelope = try requestObject()
            var nested = try XCTUnwrap(envelope[field] as? [String: Any])
            nested["unexpected"] = "anything"
            envelope[field] = nested
            XCTAssertThrowsError(try perform(envelope, store: store))
        }
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testUnmanagedAndCredentialFieldsInEncodedSettingsNeverReachStore() throws {
        let store = RecordingStore()
        for key in ["HTTPProxy", "SOCKSUser", "SOCKSPassword"] {
            for snapshot in ["expected", "desired"] {
                var envelope = try requestObject()
                try replaceSettings(in: &envelope, field: snapshot, values: [key: "untrusted"])
                XCTAssertThrowsError(try perform(envelope, store: store), key)
            }
        }
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testInvalidSettingTypesAndPortRangesNeverReachStore() throws {
        let store = RecordingStore()
        let invalid: [[String: Any]] = [
            ["SOCKSEnable": "yes"], ["ProxyAutoConfigEnable": 2],
            ["SOCKSProxy": ["127.0.0.1"]], ["ProxyAutoConfigJavaScript": 1],
            ["SOCKSPort": -1], ["SOCKSPort": 65536], ["SOCKSPort": 1.5],
            ["SOCKSPort": Double.infinity]
        ]
        for values in invalid {
            var envelope = try requestObject()
            try replaceSettings(in: &envelope, field: "desired", values: values)
            XCTAssertThrowsError(try perform(envelope, store: store), "Accepted \(values)")
        }
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testInvalidServiceIdentifiersNeverReachStore() throws {
        let store = RecordingStore()
        for id in ["", "../service", "service\n", "service\0", String(repeating: "a", count: 256)] {
            var envelope = try requestObject()
            envelope["service"] = ["id": id, "name": "Wi-Fi"]
            XCTAssertThrowsError(try perform(envelope, store: store))
        }
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testStoreFailureIsPropagated() throws {
        let store = RecordingStore()
        store.error = NSError(domain: "TestStore", code: 7)

        XCTAssertThrowsError(try perform(requestObject(), store: store)) { error in
            XCTAssertEqual((error as NSError).domain, "TestStore")
            XCTAssertEqual((error as NSError).code, 7)
        }
    }

    func testMissingServiceErrorSurvivesXPCErrorEncoding() throws {
        let encoded = ProxyNetworkHelperError.encode(NetworkProxyStoreError.missingService("Wi-Fi"))
        let archived = try NSKeyedArchiver.archivedData(withRootObject: encoded, requiringSecureCoding: true)
        let restored = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: archived))

        guard case NetworkProxyStoreError.missingService(let name) = ProxyNetworkHelperError.decode(restored) else {
            return XCTFail("Missing service error lost its identity across serialization")
        }
        XCTAssertEqual(name, "Wi-Fi")
    }

    func testOtherErrorsRetainCodeAndDescription() {
        let original = NSError(domain: "TestStore", code: 17, userInfo: [NSLocalizedDescriptionKey: "Preferences locked"])
        let restored = ProxyNetworkHelperError.decode(ProxyNetworkHelperError.encode(original)) as NSError

        XCTAssertEqual(restored.domain, original.domain)
        XCTAssertEqual(restored.code, original.code)
        XCTAssertEqual(restored.localizedDescription, original.localizedDescription)
    }

    func testApplyingSettingsPreservesEveryUnmanagedFieldAndRemovesAbsentManagedFields() throws {
        let original: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "corporate", "HTTPPort": 3128,
            "ExceptionsList": ["localhost"], "SOCKSUser": "existing-user",
            "SOCKSPassword": "existing-secret", "SOCKSEnable": 0,
            "SOCKSProxy": "old-socks", "SOCKSPort": 8080,
            "ProxyAutoConfigURLString": "https://old.example/pac"
        ]
        let desired = try NetworkProxySettings(configuration: [
            "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 1080
        ])

        let updated = try desired.applying(to: original)

        let unmanaged = original.filter { !(NetworkProxySettings.pacKeys + NetworkProxySettings.socksKeys).contains($0.key) }
        let stillUnmanaged = updated.filter { unmanaged.keys.contains($0.key) }
        XCTAssertTrue(NSDictionary(dictionary: stillUnmanaged).isEqual(to: unmanaged))
        XCTAssertNil(updated["ProxyAutoConfigURLString"])
        XCTAssertEqual(updated["SOCKSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(updated["SOCKSPort"] as? Int, 1080)
    }

    private func encode(expected: NetworkProxySettings, desired: NetworkProxySettings) throws -> Data {
        try JSONEncoder().encode(NetworkProxyWriteRequest(service: service, expected: expected, desired: desired))
    }

    private func requestObject() throws -> [String: Any] {
        let expected = try NetworkProxySettings(configuration: [:])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encode(expected: expected, desired: expected.configured(pacURLString: nil))) as? [String: Any])
    }

    private func replaceSettings(in envelope: inout [String: Any], field: String, values: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        envelope[field] = ["values": data.base64EncodedString(), "authenticatedSOCKS": false]
    }

    private func perform(_ envelope: [String: Any], store: RecordingStore) throws {
        try NetworkProxyWriteRequest.perform(data: JSONSerialization.data(withJSONObject: envelope), store: store)
    }
}

private final class RecordingStore: NetworkProxyStore {
    var writes: [NetworkProxyWriteRequest] = []
    var error: Error?

    func services() throws -> [NetworkProxyService] { [] }
    func read(service: NetworkProxyService) throws -> NetworkProxySettings {
        XCTFail("Helper writes must not replace the store's atomic comparison with a separate read")
        return try NetworkProxySettings(configuration: [:])
    }
    func write(service: NetworkProxyService, expected: NetworkProxySettings, desired: NetworkProxySettings) throws {
        if let error { throw error }
        writes.append(NetworkProxyWriteRequest(service: service, expected: expected, desired: desired))
    }
}
