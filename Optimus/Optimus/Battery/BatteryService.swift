import Foundation
import Observation

@Observable
@MainActor
final class BatteryService {
    var info = BatteryInfo()

    /// True while an accurate (system_profiler-backed) health refresh is running.
    var isRefreshingHealth: Bool = false

    // Task sleep-loops rather than Timer: this class is @MainActor, so a Task
    // created inside one of its methods inherits that isolation directly —
    // no actor boundary for `self` to cross, unlike a Timer closure (which
    // the Swift 6 concurrency checker can't prove runs on the main actor).
    private var liveTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?

    func start() {
        refreshLive()
        Task { await refreshAccurateHealth() }

        // Fast IOKit polling for values system_profiler doesn't expose live.
        liveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                self.refreshLive()
            }
        }

        // system_profiler is slow (~0.3–1s) and its numbers don't move quickly,
        // so it's refreshed far less often than the live IOKit readings.
        healthTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await self.refreshAccurateHealth()
            }
        }
    }

    func stop() {
        liveTask?.cancel()
        liveTask = nil
        healthTask?.cancel()
        healthTask = nil
    }

    /// Fast, IOKit-only refresh: charge %, charging state, voltage/amperage/temperature,
    /// time to full/empty. Does NOT set `condition` or `healthPercent` — those come from
    /// `refreshAccurateHealth()` because the raw IOKit values for those two specifically
    /// do not reliably match what System Settings shows (see refreshAccurateHealth).
    func refreshLive() {
        var result = BatteryProbe.readLive()
        // preserve condition/healthPercent from the last accurate refresh
        result.condition = info.condition
        result.healthPercent = info.healthPercent
        info = result
    }

    /// Accurate source of truth for Condition and Maximum Capacity — see `BatteryProbe.readHealth()`.
    func refreshAccurateHealth() async {
        isRefreshingHealth = true
        defer { isRefreshingHealth = false }

        let (condition, healthPercent) = await BatteryProbe.readHealth()
        if let condition {
            info.condition = condition
        }
        if let healthPercent {
            info.healthPercent = healthPercent
        }
    }
}
