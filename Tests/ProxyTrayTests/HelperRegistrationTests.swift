import Foundation
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

    func testTransientPermissionFailureAfterUnregisterRetriesAndSavesOnce() throws {
        let fixture = RegistrationFixture(status: .enabled, storedVersion: "1.1-10")
        fixture.service.registerOutcomes = [
            (.notRegistered, NSError(domain: "SMAppServiceErrorDomain", code: 1)),
            (.enabled, nil)
        ]

        XCTAssertEqual(try fixture.registration.prepare(version: "1.1-11"), .enabled)

        XCTAssertEqual(fixture.operations, ["unregister", "register", "wait", "register", "save:1.1-11"])
        XCTAssertEqual(fixture.retryDelays, [0.1])
        XCTAssertEqual(fixture.storedVersion, "1.1-11")
    }

    func testPostUnregisterRetryExhaustionPreservesPreviousVersion() {
        let fixture = RegistrationFixture(status: .enabled, storedVersion: "1.1-10")
        fixture.service.statusAfterRegister = .notRegistered
        fixture.service.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1)

        XCTAssertThrowsError(try fixture.registration.prepare(version: "1.1-11")) {
            XCTAssertEqual(($0 as NSError).domain, "SMAppServiceErrorDomain")
            XCTAssertEqual(($0 as NSError).code, 1)
        }

        XCTAssertEqual(fixture.operations, [
            "unregister", "register", "wait", "register", "wait", "register", "wait",
            "register", "wait", "register", "wait", "register"
        ])
        XCTAssertEqual(fixture.retryDelays, [0.1, 0.25, 0.5, 1, 2])
        XCTAssertEqual(fixture.storedVersion, "1.1-10")
    }

    func testFreshPermissionFailureIsNotRetried() {
        for domain in ["SMAppServiceErrorDomain", NSPOSIXErrorDomain] {
            let fixture = RegistrationFixture(status: .notRegistered, storedVersion: nil)
            fixture.service.statusAfterRegister = .notRegistered
            fixture.service.registerError = NSError(domain: domain, code: 1)

            XCTAssertThrowsError(try fixture.registration.prepare(version: "1.1-11"))

            XCTAssertEqual(fixture.operations, ["register"])
            XCTAssertEqual(fixture.retryDelays, [])
            XCTAssertNil(fixture.storedVersion)
        }
    }

    func testPermanentPostUnregisterFailureIsNotRetried() {
        for error in [
            NSError(domain: "SMAppServiceErrorDomain", code: 5),
            NSError(domain: NSPOSIXErrorDomain, code: 1),
            NSError(domain: "OtherRegistrationError", code: 1)
        ] {
            let fixture = RegistrationFixture(status: .enabled, storedVersion: "1.1-10")
            fixture.service.statusAfterRegister = .notRegistered
            fixture.service.registerError = error

            XCTAssertThrowsError(try fixture.registration.prepare(version: "1.1-11")) {
                XCTAssertEqual(($0 as NSError).domain, error.domain)
                XCTAssertEqual(($0 as NSError).code, error.code)
            }

            XCTAssertEqual(fixture.operations, ["unregister", "register"])
            XCTAssertEqual(fixture.retryDelays, [])
            XCTAssertEqual(fixture.storedVersion, "1.1-10")
        }
    }

    func testPostUnregisterPendingApprovalIsReturnedWithoutRetry() throws {
        let fixture = RegistrationFixture(status: .enabled, storedVersion: "1.1-10")
        fixture.service.statusAfterRegister = .requiresApproval
        fixture.service.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1)

        XCTAssertEqual(try fixture.registration.prepare(version: "1.1-11"), .requiresApproval)

        XCTAssertEqual(fixture.operations, ["unregister", "register", "save:1.1-11"])
        XCTAssertEqual(fixture.retryDelays, [])
        XCTAssertEqual(fixture.storedVersion, "1.1-11")
    }

    func testPostUnregisterMissingHelperIsNotRetried() {
        let fixture = RegistrationFixture(status: .enabled, storedVersion: "1.1-10")
        fixture.service.statusAfterRegister = .notFound
        fixture.service.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1)

        XCTAssertThrowsError(try fixture.registration.prepare(version: "1.1-11"))

        XCTAssertEqual(fixture.operations, ["unregister", "register"])
        XCTAssertEqual(fixture.retryDelays, [])
        XCTAssertEqual(fixture.storedVersion, "1.1-10")
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
    var retryDelays: [TimeInterval] = []
    lazy var registration = HelperRegistration(
        service: service,
        loadVersion: { [unowned self] in storedVersion },
        saveVersion: { [unowned self] version in
            operations.append("save:\(version)")
            storedVersion = version
        },
        waitForRetry: { [unowned self] delay in
            operations.append("wait")
            retryDelays.append(delay)
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
    var registerOutcomes: [(status: HelperServiceStatus, error: Error?)] = []
    var registerError: Error?
    var unregisterError: Error?
    var recordOperation: (String) -> Void = { _ in }

    init(status: HelperServiceStatus) {
        self.status = status
    }

    func register() throws {
        recordOperation("register")
        if !registerOutcomes.isEmpty {
            let outcome = registerOutcomes.removeFirst()
            status = outcome.status
            if let error = outcome.error { throw error }
            return
        }
        status = statusAfterRegister
        if let registerError { throw registerError }
    }

    func unregister() throws {
        recordOperation("unregister")
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}
