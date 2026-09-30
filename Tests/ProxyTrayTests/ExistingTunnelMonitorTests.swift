import Foundation
import XCTest
@testable import ProxyTray

final class ExistingTunnelMonitorTests: XCTestCase {
    func testLostTunnelNotifiesOnceOnMainQueue() {
        let exit = expectation(description: "Lost tunnel callback")
        let settled = expectation(description: "Later polling intervals elapsed")
        var exitCount = 0
        let monitor = ExistingTunnelMonitor(isRunning: {
            XCTAssertFalse(Thread.isMainThread)
            return false
        }, interval: 0.005)
        defer { monitor.stop() }

        monitor.start {
            XCTAssertTrue(Thread.isMainThread)
            exitCount += 1
            exit.fulfill()
            if exitCount == 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    settled.fulfill()
                }
            }
        }

        wait(for: [exit, settled], timeout: 1)
        XCTAssertEqual(exitCount, 1)
    }

    func testStopSuppressesInFlightFailedProbe() {
        let probeStarted = expectation(description: "Probe started")
        let unexpectedExit = expectation(description: "Intentional stop stays silent")
        unexpectedExit.isInverted = true
        let releaseProbe = DispatchSemaphore(value: 0)
        let monitor = ExistingTunnelMonitor(isRunning: {
            probeStarted.fulfill()
            _ = releaseProbe.wait(timeout: .now() + 1)
            return false
        }, interval: 0.005)
        defer { monitor.stop() }

        monitor.start { unexpectedExit.fulfill() }
        wait(for: [probeStarted], timeout: 1)

        monitor.stop()
        releaseProbe.signal()

        wait(for: [unexpectedExit], timeout: 0.1)
    }

    func testRestartDiscardsEarlierProbeAndNotifiesForNewGeneration() {
        let firstProbeStarted = expectation(description: "First generation probe started")
        let replacementProbeStarted = expectation(description: "Replacement probe started")
        let oldExit = expectation(description: "Previous generation stays silent")
        oldExit.isInverted = true
        let replacementExit = expectation(description: "Replacement generation reports loss")
        let releaseFirstProbe = DispatchSemaphore(value: 0)
        // Probes are serialized on the monitor's queue.
        var probeCount = 0
        let monitor = ExistingTunnelMonitor(isRunning: {
            probeCount += 1
            if probeCount == 1 {
                firstProbeStarted.fulfill()
                _ = releaseFirstProbe.wait(timeout: .now() + 1)
            } else if probeCount == 2 {
                replacementProbeStarted.fulfill()
            }
            return false
        }, interval: 0.005)
        defer { monitor.stop() }

        monitor.start { oldExit.fulfill() }
        wait(for: [firstProbeStarted], timeout: 1)

        monitor.start { replacementExit.fulfill() }
        releaseFirstProbe.signal()

        wait(for: [replacementProbeStarted, replacementExit], timeout: 1)
        wait(for: [oldExit], timeout: 0.1)
    }
}
