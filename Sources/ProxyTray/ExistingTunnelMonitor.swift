import Foundation

/// Monitors a tunnel inherited from an earlier app instance.
/// Call `start` and `stop` on the main thread. Probes run on a background queue;
/// a lost tunnel is reported once on the main queue.
final class ExistingTunnelMonitor {
    private let isRunning: () -> Bool
    private let interval: TimeInterval
    private let probeQueue = DispatchQueue(label: "net.hsch.proxytray.existing-tunnel-monitor")
    private var timer: DispatchSourceTimer?
    private var generation: UUID?

    init(isRunning: @escaping () -> Bool, interval: TimeInterval = 2) {
        precondition(interval > 0 && interval.isFinite)
        self.isRunning = isRunning
        self.interval = interval
    }

    func start(onExit: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        stop()

        let generation = UUID()
        self.generation = generation
        let isRunning = self.isRunning
        let timer = DispatchSource.makeTimerSource(queue: probeQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard !isRunning() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.stop()
                onExit()
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        precondition(Thread.isMainThread)
        generation = nil
        timer?.cancel()
        timer = nil
    }

    deinit {
        timer?.cancel()
    }
}
