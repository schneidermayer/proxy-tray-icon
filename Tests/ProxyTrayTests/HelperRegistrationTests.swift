import XCTest
@testable import ProxyTray

final class HelperRegistrationTests: XCTestCase {
    func testReopeningApprovedOrPendingBuildLeavesRegistrationUnchanged() throws {
        for status in [HelperServiceStatus.enabled, .requiresApproval] {
            let fixture = RegistrationFixture(status: status, storedVersion: "1.1-10")

            XCTAssertEqual(try fixture.registration.prepare(version: "1.1-10"), status)

            XCTAssertEqual(fixture.operations, [])
            XCTAssertEqual(fixture.storedVersion, "1.1-10")
        }
    }

    func testNewBuildUnregistersBeforeRegisteringAndSavingVersion() throws {
        for status in [HelperServiceStatus.enabled, .requiresApproval] {
            let fixture = RegistrationFixture(status: status, storedVersion: "1.1-10")
            fixture.service.statusAfterRegister = status

            XCTAssertEqual(try fixture.registration.prepare(version: "1.1-11"), status)

            XCTAssertEqual(fixture.operations, ["unregister", "register", "save:1.1-11"])
            XCTAssertEqual(fixture.storedVersion, "1.1-11")
            fixture.operations.removeAll()
            XCTAssertEqual(try fixture.registration.prepare(version: "1.1-11"), status)
            XCTAssertEqual(fixture.operations, [])
        }
    }

    func testUnregisterFailurePreventsReplacementAndVersionUpdate() {
        let fixture = RegistrationFixture(status: .enabled, storedVersion: "1.1-10")
        fixture.service.unregisterError = RegistrationFailure.unregister

        XCTAssertThrowsError(try fixture.registration.prepare(version: "1.1-11")) {
            XCTAssertEqual($0 as? RegistrationFailure, .unregister)
        }

        XCTAssertEqual(fixture.operations, ["unregister"])
        XCTAssertEqual(fixture.storedVersion, "1.1-10")
        XCTAssertEqual(fixture.service.status, .enabled)
    }

    func testRegistrationFailureIsPropagatedWithoutCachingVersion() throws {
        let fixture = RegistrationFixture(status: .notRegistered, storedVersion: "1.1-10")
        fixture.service.statusAfterRegister = .notRegistered
        fixture.service.registerError = RegistrationFailure.register

        XCTAssertThrowsError(try fixture.registration.prepare(version: "1.1-11")) {
            XCTAssertEqual($0 as? RegistrationFailure, .register)
        }

        XCTAssertEqual(fixture.operations, ["register"])
        XCTAssertEqual(fixture.storedVersion, "1.1-10")

        fixture.service.registerError = nil
        fixture.service.statusAfterRegister = .enabled
        XCTAssertEqual(try fixture.registration.prepare(version: "1.1-11"), .enabled)
        XCTAssertEqual(fixture.operations, ["register", "register", "save:1.1-11"])
        XCTAssertEqual(fixture.storedVersion, "1.1-11")
    }

    func testRegistrationErrorWhileApprovalIsPendingStillCachesRegisteredBuild() throws {
        let fixture = RegistrationFixture(status: .notRegistered, storedVersion: nil)
        fixture.service.statusAfterRegister = .requiresApproval
        fixture.service.registerError = RegistrationFailure.register

        XCTAssertEqual(try fixture.registration.prepare(version: "1.1-11"), .requiresApproval)

        XCTAssertEqual(fixture.operations, ["register", "save:1.1-11"])
        XCTAssertEqual(fixture.storedVersion, "1.1-11")
        fixture.operations.removeAll()
        XCTAssertEqual(try fixture.registration.prepare(version: "1.1-11"), .requiresApproval)
        XCTAssertEqual(fixture.operations, [])
    }

    func testFreshAndMissingServicesRegisterEvenWithMatchingCachedVersion() throws {
        for status in [HelperServiceStatus.notRegistered, .notFound] {
            for storedVersion in [nil, "1.1-11"] as [String?] {
                let fixture = RegistrationFixture(status: status, storedVersion: storedVersion)

                XCTAssertEqual(try fixture.registration.prepare(version: "1.1-11"), .enabled)

                XCTAssertEqual(fixture.operations, ["register", "save:1.1-11"])
                XCTAssertEqual(fixture.storedVersion, "1.1-11")
            }
        }
    }

    func testRevokedApprovalDoesNotTriggerAnotherRegistration() throws {
        let fixture = RegistrationFixture(status: .notRegistered, storedVersion: nil)
        XCTAssertEqual(try fixture.registration.prepare(version: "1.1-11"), .enabled)
        fixture.operations.removeAll()
        fixture.service.status = .requiresApproval

        XCTAssertEqual(try fixture.registration.prepare(version: "1.1-11"), .requiresApproval)

        XCTAssertEqual(fixture.operations, [])
        XCTAssertEqual(fixture.storedVersion, "1.1-11")
    }

    func testRegistrationThatLeavesServiceUnavailableDoesNotCacheSuccess() {
        for status in [HelperServiceStatus.notRegistered, .notFound] {
            let fixture = RegistrationFixture(status: .notRegistered, storedVersion: nil)
            fixture.service.statusAfterRegister = status

            XCTAssertThrowsError(try fixture.registration.prepare(version: "1.1-11"))

            XCTAssertEqual(fixture.operations, ["register"])
            XCTAssertNil(fixture.storedVersion)
        }
    }
}

private enum RegistrationFailure: Error {
    case register
    case unregister
}

private final class RegistrationFixture {
    let service: FakeHelperService
    var storedVersion: String?
    var operations: [String] = []
    lazy var registration = HelperRegistration(
        service: service,
        loadVersion: { [unowned self] in storedVersion },
        saveVersion: { [unowned self] version in
            operations.append("save:\(version)")
            storedVersion = version
        }
    )

    init(status: HelperServiceStatus, storedVersion: String?) {
        service = FakeHelperService(status: status)
        self.storedVersion = storedVersion
        service.recordOperation = { [unowned self] in operations.append($0) }
    }
}

private final class FakeHelperService: HelperServiceManaging {
    var status: HelperServiceStatus
    var statusAfterRegister: HelperServiceStatus = .enabled
    var registerError: Error?
    var unregisterError: Error?
    var recordOperation: (String) -> Void = { _ in }

    init(status: HelperServiceStatus) {
        self.status = status
    }

    func register() throws {
        recordOperation("register")
        status = statusAfterRegister
        if let registerError { throw registerError }
    }

    func unregister() throws {
        recordOperation("unregister")
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}
