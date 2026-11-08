import Foundation
import IOKit
import IOKit.ps

struct BatteryInfo {
    var cycleCount: Int = 0
    var designCapacity: Int = 0
    var maxCapacity: Int = 0
    var currentCapacity: Int = 0
    var healthPercent: Double = 0
    var condition: String = "Unknown"
    var temperature: Double = 0
    var voltage: Double = 0
    var amperage: Int = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var timeToFull: Int = 0
    var timeToEmpty: Int = 0
    var chargePercent: Double = 0
}

/// Stateless battery reads, shared by the `Optimus` GUI (live gauges, polled every 5s)
/// and the `OptimusSampler` background helper (one durable sample every 60s).
enum BatteryProbe {
    /// Fast, IOKit-only read: charge %, charging state, voltage/amperage/temperature,
    /// time to full/empty, cycle count. Does NOT set `condition` or `healthPercent` —
    /// those come from `readHealth()`, because the raw IOKit values for those two
    /// specifically do not reliably match what System Settings shows.
    static func readLive() -> BatteryInfo {
        var result = BatteryInfo()

        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else {
            return result
        }
        defer { IOObjectRelease(service) }

        func intProp(_ key: String) -> Int {
            guard let val = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                             kCFAllocatorDefault, 0)?.takeRetainedValue()
            else { return 0 }
            if let n = val as? Int { return n }
            if CFGetTypeID(val) == CFNumberGetTypeID() {
                var n: Int = 0
                CFNumberGetValue((val as! CFNumber), .intType, &n)
                return n
            }
            return 0
        }

        func boolProp(_ key: String) -> Bool {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool) ?? false
        }

        result.cycleCount       = intProp("CycleCount")
        result.designCapacity   = intProp("DesignCapacity")
        result.maxCapacity      = intProp("AppleRawMaxCapacity")
        result.currentCapacity  = intProp("AppleRawCurrentCapacity")
        result.voltage          = Double(intProp("Voltage")) / 1000.0
        result.amperage         = intProp("Amperage")
        result.isCharging       = boolProp("IsCharging")
        result.isPluggedIn      = boolProp("ExternalConnected")
        result.timeToFull       = intProp("TimeToFull")
        result.timeToEmpty      = intProp("TimeToEmpty")
        result.temperature      = Double(intProp("Temperature")) / 100.0

        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
           let first = list.first,
           let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any],
           let pct = desc[kIOPSCurrentCapacityKey] as? Int {
            result.chargePercent = Double(pct)
        } else if result.maxCapacity > 0 {
            result.chargePercent = Double(result.currentCapacity) / Double(result.maxCapacity) * 100
        }

        return result
    }

    /// Accurate source of truth for Condition and Maximum Capacity: shells out to
    /// `system_profiler SPPowerDataType`, which is fed by the same powerd data System
    /// Settings reads. This is why it matches System Settings (e.g. "Normal" / 99%)
    /// while the raw IOKit/IOPowerSources keys can lag or use a different, more
    /// conservative capacity value (NominalChargeCapacity) than System Settings does.
    ///
    /// Slow (~0.3-1s) — callers should throttle how often they pay for this rather
    /// than calling it on every fast poll.
    static func readHealth() async -> (condition: String?, healthPercent: Double?) {
        guard let output = try? await Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType"]) else {
            return (nil, nil)
        }

        var condition: String?
        var maxCapacityPercent: Int?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Condition:") {
                condition = line
                    .replacingOccurrences(of: "Condition:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Maximum Capacity:") {
                let digits = line
                    .replacingOccurrences(of: "Maximum Capacity:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "%", with: "")
                maxCapacityPercent = Int(digits)
            }
        }

        return (condition, maxCapacityPercent.map(Double.init))
    }
}
